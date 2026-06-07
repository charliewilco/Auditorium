use std::collections::BTreeMap;
use std::env;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;
use thiserror::Error;
use tokio::fs;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::time::sleep;

const DEFAULT_WORKFLOW: &str = r#"---
tracker:
  kind: github
  active_states: ["open"]
  terminal_states: ["closed"]
polling:
  interval_ms: 30000
workspace:
  root: ".auditorium/symphony-workspaces"
validation:
  command: ""
agent:
  max_concurrent_agents: 3
  max_turns: 1
  max_retry_backoff_ms: 300000
codex:
  command: "codex exec --json --sandbox workspace-write -c approval_policy=\"never\""
branch_prefix: "auditorium"
run_tests: true
open_pull_request: true
---
You are working on GitHub issue {{ issue.identifier }} in {{ issue.repo }}.

Read the issue, inspect the repository, make the smallest correct change, run relevant tests, commit, and leave a concise summary.
"#;

#[derive(Debug, Error)]
pub enum SymphonyError {
    #[error("workflow file was not found at {0}")]
    MissingWorkflowFile(PathBuf),
    #[error("workflow front matter could not be parsed: {0}")]
    WorkflowParse(String),
    #[error("workflow front matter must be a YAML map")]
    WorkflowFrontMatterNotMap,
    #[error("workflow config is invalid: {0}")]
    InvalidConfig(String),
    #[error("command failed: {program} {args:?} exited with {status}: {stderr}")]
    CommandFailed {
        program: String,
        args: Vec<String>,
        status: i32,
        stderr: String,
    },
    #[error("io failure: {0}")]
    Io(#[from] std::io::Error),
    #[error("json failure: {0}")]
    Json(#[from] serde_json::Error),
}

impl SymphonyError {
    pub fn code(&self) -> &'static str {
        match self {
            SymphonyError::MissingWorkflowFile(_) => "missing_workflow_file",
            SymphonyError::WorkflowParse(_) => "workflow_parse_error",
            SymphonyError::WorkflowFrontMatterNotMap => "workflow_front_matter_not_a_map",
            SymphonyError::InvalidConfig(_) => "invalid_config",
            SymphonyError::CommandFailed { .. } => "command_failed",
            SymphonyError::Io(_) => "io_error",
            SymphonyError::Json(_) => "json_error",
        }
    }

    pub fn exit_code(&self) -> i32 {
        match self {
            SymphonyError::MissingWorkflowFile(_) => 20,
            SymphonyError::WorkflowParse(_) | SymphonyError::WorkflowFrontMatterNotMap => 21,
            SymphonyError::InvalidConfig(_) => 22,
            SymphonyError::CommandFailed { .. } => 30,
            SymphonyError::Io(_) => 40,
            SymphonyError::Json(_) => 41,
        }
    }
}

#[derive(Debug, Clone)]
pub struct DoctorOptions {
    pub json: bool,
    pub workflow: PathBuf,
}

#[derive(Debug, Clone)]
pub struct RunOptions {
    pub repo: String,
    pub issue: u64,
    pub workflow: PathBuf,
    pub workspace_root: Option<PathBuf>,
    pub json: bool,
    pub mock: bool,
    pub dry_run: bool,
    pub no_pr: bool,
}

#[derive(Debug, Clone)]
pub struct DaemonOptions {
    pub project: String,
    pub workflow: PathBuf,
    pub json: bool,
    pub watch: bool,
    pub max_ticks: Option<usize>,
    pub poll_interval_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowDefinition {
    pub config: serde_yaml::Mapping,
    pub prompt_template: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkflowConfig {
    pub tracker_kind: String,
    pub polling_interval_ms: u64,
    pub workspace_root: PathBuf,
    pub max_concurrent_agents: usize,
    pub max_turns: usize,
    pub max_retry_backoff_ms: u64,
    pub codex_command: String,
    pub branch_prefix: String,
    pub max_retries: usize,
    pub run_tests: bool,
    pub open_pull_request: bool,
    pub validation_command: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NormalizedIssue {
    pub id: String,
    pub identifier: String,
    pub repo: String,
    pub number: u64,
    pub title: String,
    pub description: Option<String>,
    pub state: String,
    pub url: Option<String>,
    pub labels: Vec<String>,
    pub assignees: Vec<String>,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunReport {
    pub run_id: String,
    pub repo: String,
    pub issue: NormalizedIssue,
    pub workspace_path: PathBuf,
    pub workspace_manifest_path: PathBuf,
    pub branch_name: String,
    pub status: String,
    pub pull_request_url: Option<String>,
    pub report_path: PathBuf,
    pub changed_files: Vec<String>,
    pub validation_output: Option<String>,
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkspaceManifest {
    pub run_id: String,
    pub repo: String,
    pub issue_identifier: String,
    pub issue_number: u64,
    pub workspace_path: PathBuf,
    pub repo_path: PathBuf,
    pub branch_name: String,
    pub workflow_path: PathBuf,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Event {
    level: String,
    category: String,
    message: String,
    timestamp: DateTime<Utc>,
    metadata: serde_json::Value,
}

pub async fn init_workflow(path: &Path, check: bool) -> Result<(), SymphonyError> {
    if check && path.exists() {
        return Err(SymphonyError::InvalidConfig(format!(
            "{} already exists",
            path.display()
        )));
    }
    if path.exists() {
        return Err(SymphonyError::InvalidConfig(format!(
            "{} already exists; remove it or choose another --workflow path",
            path.display()
        )));
    }
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent).await?;
    }
    fs::write(path, DEFAULT_WORKFLOW).await?;
    println!("created {}", path.display());
    Ok(())
}

pub async fn doctor(options: DoctorOptions) -> Result<(), SymphonyError> {
    let workflow_status = match load_workflow(&options.workflow).await {
        Ok(definition) => match resolve_config(&definition, &options.workflow) {
            Ok(config) => json!({
                "ok": true,
                "workspaceRoot": config.workspace_root,
                "trackerKind": config.tracker_kind,
                "maxConcurrentAgents": config.max_concurrent_agents
            }),
            Err(error) => {
                json!({ "ok": false, "code": error.code(), "message": error.to_string() })
            }
        },
        Err(error) => json!({ "ok": false, "code": error.code(), "message": error.to_string() }),
    };

    let checks = vec![
        check_command("git", &["--version"]).await,
        check_command("gh", &["--version"]).await,
        check_command("gh", &["auth", "status"]).await,
        check_command("codex", &["--version"]).await,
    ];
    let ok = checks
        .iter()
        .all(|check| check["ok"].as_bool() == Some(true))
        && workflow_status["ok"].as_bool() == Some(true);
    let output = json!({
        "ok": ok,
        "workflow": workflow_status,
        "checks": checks
    });
    if options.json {
        println!("{}", serde_json::to_string_pretty(&output)?);
    } else {
        println!("symphony doctor: {}", if ok { "ok" } else { "failed" });
        println!("{}", serde_json::to_string_pretty(&output)?);
    }
    if ok {
        Ok(())
    } else {
        Err(SymphonyError::InvalidConfig(
            "doctor checks failed".to_string(),
        ))
    }
}

pub async fn run_issue(options: RunOptions) -> Result<(), SymphonyError> {
    let started_at = Utc::now();
    let run_id = format!("{}-{}", started_at.format("%Y%m%d%H%M%S"), options.issue);
    let definition = load_workflow(&options.workflow).await?;
    let mut config = resolve_config(&definition, &options.workflow)?;
    if let Some(root) = options.workspace_root {
        config.workspace_root = absolute_path(&root, env::current_dir()?.as_path());
    }
    if options.no_pr {
        config.open_pull_request = false;
    }

    let issue = if options.mock {
        mock_issue(&options.repo, options.issue)
    } else {
        fetch_github_issue(&options.repo, options.issue).await?
    };
    let workspace = prepare_workspace(&config, &issue).await?;
    let repo_path = workspace.join("repo");
    let branch_name = branch_name(&config.branch_prefix, &issue);
    let workspace_manifest_path = write_workspace_manifest(
        &run_id,
        &issue,
        &workspace,
        &repo_path,
        &branch_name,
        &options.workflow,
        started_at,
    )
    .await?;
    emit(
        options.json,
        "info",
        "orchestration",
        "run_started",
        json!({ "runID": run_id, "issue": issue.identifier }),
    )?;

    if options.mock {
        fs::create_dir_all(&repo_path).await?;
        let report = write_report(
            &config,
            &run_id,
            &issue,
            &workspace,
            &workspace_manifest_path,
            &branch_name,
            "mock_completed",
            None,
            &[],
            None,
            started_at,
        )
        .await?;
        emit(
            options.json,
            "success",
            "report",
            "mock_report_written",
            json!({ "path": report.report_path }),
        )?;
        print_final_report(options.json, &report)?;
        return Ok(());
    }

    let default_branch = fetch_default_branch(&options.repo).await?;
    clone_or_update_repo(&options.repo, &repo_path).await?;
    git(&repo_path, &["checkout", default_branch.as_str()]).await?;
    git(&repo_path, &["pull", "--ff-only"]).await?;
    if remote_branch_exists(&repo_path, &branch_name).await {
        let remote_branch = format!("origin/{branch_name}");
        git(
            &repo_path,
            &[
                "checkout",
                "-B",
                branch_name.as_str(),
                remote_branch.as_str(),
            ],
        )
        .await?;
    } else {
        git(&repo_path, &["checkout", "-B", branch_name.as_str()]).await?;
    }
    emit(
        options.json,
        "info",
        "git",
        "branch_ready",
        json!({ "branch": branch_name }),
    )?;

    if !options.dry_run {
        let prompt = render_prompt(&definition.prompt_template, &issue, &config);
        run_codex(&config, &repo_path, &prompt, options.json).await?;
    }

    let changed = command_stdout("git", &["status", "--porcelain"], Some(&repo_path)).await?;
    let uncommitted_files = parse_changed_files(&changed);
    let committed_files = committed_changed_files(&repo_path, &default_branch).await?;
    let changed_files = merge_changed_files(&committed_files, &uncommitted_files);
    let branch_has_commits = branch_has_commits(&repo_path, &default_branch).await?;
    let mut validation_output = None;
    let mut pr_url = None;
    let status = if changed.trim().is_empty() && !branch_has_commits {
        emit(
            options.json,
            "warning",
            "git",
            "no_changes_detected",
            json!({}),
        )?;
        "completed_no_changes"
    } else if changed.trim().is_empty() && branch_has_commits {
        if config.run_tests {
            if let Some(command) = &config.validation_command {
                let validation = run_validation(command, &repo_path).await?;
                validation_output = Some(validation);
                emit(
                    options.json,
                    "success",
                    "validation",
                    "validation_passed",
                    json!({ "command": command }),
                )?;
            }
        }
        if config.open_pull_request {
            pr_url = existing_pull_request_url(&options.repo, &branch_name).await?;
            if pr_url.is_none() {
                git(&repo_path, &["push", "-u", "origin", branch_name.as_str()]).await?;
                pr_url = Some(
                    create_pull_request(&options.repo, &issue, &branch_name, &default_branch)
                        .await?,
                );
            }
            emit(
                options.json,
                "success",
                "pullRequest",
                "pull_request_reconciled",
                json!({ "url": pr_url }),
            )?;
        }
        "completed"
    } else if options.dry_run {
        emit(
            options.json,
            "info",
            "git",
            "dry_run_left_changes_uncommitted",
            json!({ "changedFiles": changed_files }),
        )?;
        "dry_run"
    } else {
        if config.run_tests {
            if let Some(command) = &config.validation_command {
                let validation = run_validation(command, &repo_path).await?;
                validation_output = Some(validation);
                emit(
                    options.json,
                    "success",
                    "validation",
                    "validation_passed",
                    json!({ "command": command }),
                )?;
            }
        }
        git(&repo_path, &["add", "-A"]).await?;
        let message = format!("{}: {}", issue.identifier, issue.title);
        git(&repo_path, &["commit", "-m", message.as_str()]).await?;
        git(&repo_path, &["push", "-u", "origin", branch_name.as_str()]).await?;
        emit(
            options.json,
            "success",
            "git",
            "branch_pushed",
            json!({ "branch": branch_name }),
        )?;
        if config.open_pull_request {
            pr_url = Some(
                create_pull_request(&options.repo, &issue, &branch_name, &default_branch).await?,
            );
            emit(
                options.json,
                "success",
                "pullRequest",
                "pull_request_opened",
                json!({ "url": pr_url }),
            )?;
        }
        "completed"
    };

    let report = write_report(
        &config,
        &run_id,
        &issue,
        &workspace,
        &workspace_manifest_path,
        &branch_name,
        status,
        pr_url,
        &changed_files,
        validation_output,
        started_at,
    )
    .await?;
    emit(
        options.json,
        "success",
        "report",
        "report_written",
        json!({ "path": report.report_path }),
    )?;
    print_final_report(options.json, &report)?;
    Ok(())
}

pub async fn daemon_once(
    project: String,
    workflow: PathBuf,
    json_output: bool,
) -> Result<(), SymphonyError> {
    daemon(DaemonOptions {
        project,
        workflow,
        json: json_output,
        watch: false,
        max_ticks: Some(1),
        poll_interval_ms: None,
    })
    .await
}

pub async fn daemon(options: DaemonOptions) -> Result<(), SymphonyError> {
    if options.max_ticks == Some(0) {
        return Err(SymphonyError::InvalidConfig(
            "daemon.max_ticks must be positive when provided".to_string(),
        ));
    }

    let mut loader = DaemonWorkflowLoader::default();
    let max_ticks = if options.watch {
        options.max_ticks
    } else {
        Some(1)
    };
    let mut tick = 0usize;

    loop {
        tick += 1;
        let loaded = loader.load(&options.workflow).await?;
        emit_daemon_tick(&options, tick, &loaded)?;

        if max_ticks.is_some_and(|limit| tick >= limit) || !options.watch {
            return Ok(());
        }

        let interval = options
            .poll_interval_ms
            .unwrap_or(loaded.config.polling_interval_ms);
        sleep(Duration::from_millis(interval)).await;
    }
}

#[derive(Debug)]
struct LoadedDaemonWorkflow {
    config: WorkflowConfig,
    revision: u64,
    reloaded: bool,
}

#[derive(Debug, Default)]
struct DaemonWorkflowLoader {
    last_modified: Option<SystemTime>,
    revision: u64,
}

impl DaemonWorkflowLoader {
    async fn load(&mut self, workflow: &Path) -> Result<LoadedDaemonWorkflow, SymphonyError> {
        let definition = load_workflow(workflow).await?;
        let config = resolve_config(&definition, workflow)?;
        let modified = fs::metadata(workflow)
            .await
            .map_err(|error| {
                if error.kind() == std::io::ErrorKind::NotFound {
                    SymphonyError::MissingWorkflowFile(workflow.to_path_buf())
                } else {
                    SymphonyError::Io(error)
                }
            })?
            .modified()
            .ok();
        let reloaded = self.last_modified != modified;
        if reloaded {
            self.revision += 1;
            self.last_modified = modified;
        }
        Ok(LoadedDaemonWorkflow {
            config,
            revision: self.revision,
            reloaded,
        })
    }
}

fn emit_daemon_tick(
    options: &DaemonOptions,
    tick: usize,
    loaded: &LoadedDaemonWorkflow,
) -> Result<(), SymphonyError> {
    emit(
        options.json,
        "info",
        "orchestration",
        "daemon_tick_completed",
        json!({
            "project": options.project,
            "workflow": options.workflow,
            "tick": tick,
            "workflowRevision": loaded.revision,
            "workflowReloaded": loaded.reloaded,
            "pollingIntervalMs": loaded.config.polling_interval_ms,
            "maxConcurrentAgents": loaded.config.max_concurrent_agents
        }),
    )
}

pub async fn print_report(
    run: String,
    workspace_root: Option<PathBuf>,
) -> Result<(), SymphonyError> {
    let path = if run.ends_with(".md") || run.contains('/') {
        PathBuf::from(run)
    } else {
        workspace_root
            .unwrap_or_else(|| PathBuf::from(".auditorium/symphony-workspaces"))
            .join("reports")
            .join(format!("{run}.md"))
    };
    let markdown = fs::read_to_string(&path).await?;
    print!("{markdown}");
    Ok(())
}

pub async fn load_workflow(path: &Path) -> Result<WorkflowDefinition, SymphonyError> {
    let content = fs::read_to_string(path).await.map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            SymphonyError::MissingWorkflowFile(path.to_path_buf())
        } else {
            SymphonyError::Io(error)
        }
    })?;
    parse_workflow(&content)
}

pub fn parse_workflow(content: &str) -> Result<WorkflowDefinition, SymphonyError> {
    let normalized = content.strip_prefix('\u{feff}').unwrap_or(content);
    if !normalized.starts_with("---") {
        return Ok(WorkflowDefinition {
            config: serde_yaml::Mapping::new(),
            prompt_template: normalized.trim().to_string(),
        });
    }
    let mut lines = normalized.lines();
    let _opening = lines.next();
    let mut front_matter = String::new();
    let mut found_close = false;
    for line in lines.by_ref() {
        if line.trim() == "---" {
            found_close = true;
            break;
        }
        front_matter.push_str(line);
        front_matter.push('\n');
    }
    if !found_close {
        return Err(SymphonyError::WorkflowParse(
            "missing closing ---".to_string(),
        ));
    }
    let value: serde_yaml::Value = serde_yaml::from_str(&front_matter)
        .map_err(|error| SymphonyError::WorkflowParse(error.to_string()))?;
    let config = value
        .as_mapping()
        .cloned()
        .ok_or(SymphonyError::WorkflowFrontMatterNotMap)?;
    let body = lines.collect::<Vec<_>>().join("\n").trim().to_string();
    Ok(WorkflowDefinition {
        config,
        prompt_template: body,
    })
}

pub fn resolve_config(
    definition: &WorkflowDefinition,
    workflow_path: &Path,
) -> Result<WorkflowConfig, SymphonyError> {
    let workflow_dir = workflow_path.parent().unwrap_or_else(|| Path::new("."));
    let tracker = mapping_value(&definition.config, "tracker").and_then(|value| value.as_mapping());
    let polling = mapping_value(&definition.config, "polling").and_then(|value| value.as_mapping());
    let workspace =
        mapping_value(&definition.config, "workspace").and_then(|value| value.as_mapping());
    let validation =
        mapping_value(&definition.config, "validation").and_then(|value| value.as_mapping());
    let agent = mapping_value(&definition.config, "agent").and_then(|value| value.as_mapping());
    let codex = mapping_value(&definition.config, "codex").and_then(|value| value.as_mapping());

    let tracker_kind = string_from_map(tracker, "kind").unwrap_or_else(|| "github".to_string());
    if tracker_kind != "github" {
        return Err(SymphonyError::InvalidConfig(format!(
            "tracker.kind must be github for Auditorium v0, got {tracker_kind}"
        )));
    }
    let workspace_root = string_from_map(workspace, "root")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(".auditorium/symphony-workspaces"));

    let config = WorkflowConfig {
        tracker_kind,
        polling_interval_ms: int_from_map(polling, "interval_ms").unwrap_or(30_000),
        workspace_root: absolute_path(&workspace_root, workflow_dir),
        max_concurrent_agents: int_from_map(agent, "max_concurrent_agents").unwrap_or(3) as usize,
        max_turns: int_from_map(agent, "max_turns").unwrap_or(1) as usize,
        max_retry_backoff_ms: int_from_map(agent, "max_retry_backoff_ms").unwrap_or(300_000),
        codex_command: string_from_map(codex, "command").unwrap_or_else(|| {
            "codex exec --json --sandbox workspace-write -c approval_policy=\"never\"".to_string()
        }),
        branch_prefix: string_from_root(&definition.config, "branch_prefix")
            .unwrap_or_else(|| "auditorium".to_string()),
        max_retries: int_from_root(&definition.config, "max_retries").unwrap_or(2) as usize,
        run_tests: bool_from_root(&definition.config, "run_tests").unwrap_or(true),
        open_pull_request: bool_from_root(&definition.config, "open_pull_request").unwrap_or(true),
        validation_command: string_from_map(validation, "command")
            .filter(|command| !command.trim().is_empty()),
    };
    if config.max_concurrent_agents == 0 {
        return Err(SymphonyError::InvalidConfig(
            "agent.max_concurrent_agents must be positive".to_string(),
        ));
    }
    if config.max_turns == 0 {
        return Err(SymphonyError::InvalidConfig(
            "agent.max_turns must be positive".to_string(),
        ));
    }
    if config.codex_command.trim().is_empty() {
        return Err(SymphonyError::InvalidConfig(
            "codex.command must not be empty".to_string(),
        ));
    }
    if config.run_tests && config.validation_command.as_deref().is_none() {
        tracing::warn!("run_tests is true but validation.command is empty");
    }
    Ok(config)
}

pub fn workspace_key(identifier: &str) -> String {
    identifier
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
                character.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect()
}

fn mapping_value<'a>(mapping: &'a serde_yaml::Mapping, key: &str) -> Option<&'a serde_yaml::Value> {
    mapping.get(serde_yaml::Value::String(key.to_string()))
}

fn string_from_root(mapping: &serde_yaml::Mapping, key: &str) -> Option<String> {
    mapping_value(mapping, key)
        .and_then(|value| value.as_str())
        .map(resolve_env_value)
}

fn bool_from_root(mapping: &serde_yaml::Mapping, key: &str) -> Option<bool> {
    mapping_value(mapping, key).and_then(|value| value.as_bool())
}

fn int_from_root(mapping: &serde_yaml::Mapping, key: &str) -> Option<u64> {
    mapping_value(mapping, key).and_then(yaml_u64)
}

fn string_from_map(mapping: Option<&serde_yaml::Mapping>, key: &str) -> Option<String> {
    mapping
        .and_then(|mapping| mapping_value(mapping, key))
        .and_then(|value| value.as_str())
        .map(resolve_env_value)
}

fn int_from_map(mapping: Option<&serde_yaml::Mapping>, key: &str) -> Option<u64> {
    mapping
        .and_then(|mapping| mapping_value(mapping, key))
        .and_then(yaml_u64)
}

fn yaml_u64(value: &serde_yaml::Value) -> Option<u64> {
    value.as_i64().and_then(|value| u64::try_from(value).ok())
}

fn resolve_env_value(value: &str) -> String {
    if let Some(name) = value.strip_prefix('$') {
        env::var(name).unwrap_or_default()
    } else {
        value.to_string()
    }
}

fn absolute_path(path: &Path, base: &Path) -> PathBuf {
    let expanded = expand_home(path);
    if expanded.is_absolute() {
        expanded
    } else {
        base.join(expanded)
    }
}

fn expand_home(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    if text == "~" {
        env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| path.to_path_buf())
    } else if let Some(rest) = text.strip_prefix("~/") {
        env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join(rest))
            .unwrap_or_else(|| path.to_path_buf())
    } else {
        path.to_path_buf()
    }
}

async fn prepare_workspace(
    config: &WorkflowConfig,
    issue: &NormalizedIssue,
) -> Result<PathBuf, SymphonyError> {
    let workspace = config.workspace_root.join(workspace_key(&issue.identifier));
    fs::create_dir_all(&workspace).await?;
    fs::create_dir_all(config.workspace_root.join("reports")).await?;
    Ok(workspace)
}

async fn write_workspace_manifest(
    run_id: &str,
    issue: &NormalizedIssue,
    workspace: &Path,
    repo_path: &Path,
    branch_name: &str,
    workflow_path: &Path,
    created_at: DateTime<Utc>,
) -> Result<PathBuf, SymphonyError> {
    let manifest = WorkspaceManifest {
        run_id: run_id.to_string(),
        repo: issue.repo.clone(),
        issue_identifier: issue.identifier.clone(),
        issue_number: issue.number,
        workspace_path: workspace.to_path_buf(),
        repo_path: repo_path.to_path_buf(),
        branch_name: branch_name.to_string(),
        workflow_path: workflow_path.to_path_buf(),
        created_at,
    };
    let manifest_path = workspace.join("workspace-manifest.json");
    let data = serde_json::to_vec_pretty(&manifest)?;
    fs::write(&manifest_path, data).await?;
    Ok(manifest_path)
}

async fn fetch_github_issue(repo: &str, issue: u64) -> Result<NormalizedIssue, SymphonyError> {
    let issue_number = issue.to_string();
    let output = command_stdout(
        "gh",
        &[
            "issue",
            "view",
            issue_number.as_str(),
            "--repo",
            repo,
            "--json",
            "id,number,title,body,url,labels,assignees,state,createdAt,updatedAt",
        ],
        None,
    )
    .await?;
    normalize_github_issue_payload(repo, &output)
}

fn normalize_github_issue_payload(
    repo: &str,
    output: &str,
) -> Result<NormalizedIssue, SymphonyError> {
    #[derive(Deserialize)]
    struct GhLabel {
        name: String,
    }
    #[derive(Deserialize)]
    struct GhAssignee {
        login: String,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct GhIssue {
        id: String,
        number: u64,
        title: String,
        body: Option<String>,
        url: Option<String>,
        labels: Vec<GhLabel>,
        assignees: Vec<GhAssignee>,
        state: String,
        created_at: Option<String>,
        updated_at: Option<String>,
    }
    let issue: GhIssue = serde_json::from_str(output)?;
    Ok(NormalizedIssue {
        identifier: format!("#{}", issue.number),
        repo: repo.to_string(),
        number: issue.number,
        id: issue.id,
        title: issue.title,
        description: issue.body,
        state: issue.state.to_lowercase(),
        url: issue.url,
        labels: issue
            .labels
            .into_iter()
            .map(|label| label.name.to_lowercase())
            .collect(),
        assignees: issue
            .assignees
            .into_iter()
            .map(|assignee| assignee.login)
            .collect(),
        created_at: issue.created_at,
        updated_at: issue.updated_at,
    })
}

async fn fetch_default_branch(repo: &str) -> Result<String, SymphonyError> {
    let output = command_stdout(
        "gh",
        &["repo", "view", repo, "--json", "defaultBranchRef"],
        None,
    )
    .await?;
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct BranchResponse {
        default_branch_ref: BranchRef,
    }
    #[derive(Deserialize)]
    struct BranchRef {
        name: String,
    }
    let response: BranchResponse = serde_json::from_str(&output)?;
    Ok(response.default_branch_ref.name)
}

fn mock_issue(repo: &str, issue: u64) -> NormalizedIssue {
    NormalizedIssue {
        id: format!("mock-{issue}"),
        identifier: format!("#{issue}"),
        repo: repo.to_string(),
        number: issue,
        title: "Mock Auditorium issue".to_string(),
        description: Some("Offline mock issue for runner validation.".to_string()),
        state: "open".to_string(),
        url: Some(format!("https://github.com/{repo}/issues/{issue}")),
        labels: vec!["mock".to_string()],
        assignees: Vec::new(),
        created_at: None,
        updated_at: None,
    }
}

async fn clone_or_update_repo(repo: &str, repo_path: &Path) -> Result<(), SymphonyError> {
    if repo_path.join(".git").exists() {
        git(repo_path, &["fetch", "--all", "--prune"]).await
    } else {
        let parent = repo_path.parent().unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(parent).await?;
        let repo_path_text = repo_path.to_string_lossy().to_string();
        command_stdout(
            "gh",
            &["repo", "clone", repo, repo_path_text.as_str()],
            None,
        )
        .await
        .map(|_| ())
    }
}

async fn run_codex(
    config: &WorkflowConfig,
    repo_path: &Path,
    prompt: &str,
    json_output: bool,
) -> Result<(), SymphonyError> {
    emit(
        json_output,
        "info",
        "agent",
        "codex_started",
        json!({ "command": config.codex_command }),
    )?;
    let mut parts = config.codex_command.split_whitespace();
    let program = parts.next().ok_or_else(|| {
        SymphonyError::InvalidConfig("codex.command must not be empty".to_string())
    })?;
    let args: Vec<String> = parts.map(ToString::to_string).collect();
    let mut command = Command::new(program);
    command
        .args(&args)
        .arg(prompt)
        .current_dir(repo_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn()?;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let stdout_task = tokio::spawn(async move {
        let mut collected = Vec::new();
        if let Some(stdout) = stdout {
            let mut lines = BufReader::new(stdout).lines();
            while let Some(line) = lines.next_line().await? {
                collected.push(line);
            }
        }
        Ok::<Vec<String>, std::io::Error>(collected)
    });
    let stderr_task = tokio::spawn(async move {
        let mut collected = Vec::new();
        if let Some(stderr) = stderr {
            let mut lines = BufReader::new(stderr).lines();
            while let Some(line) = lines.next_line().await? {
                collected.push(line);
            }
        }
        Ok::<Vec<String>, std::io::Error>(collected)
    });
    let status = child.wait().await?;
    let stdout_lines = stdout_task.await.map_err(|error| {
        SymphonyError::InvalidConfig(format!("codex stdout task failed: {error}"))
    })??;
    let stderr_lines = stderr_task.await.map_err(|error| {
        SymphonyError::InvalidConfig(format!("codex stderr task failed: {error}"))
    })??;
    for line in stdout_lines {
        emit(
            json_output,
            "info",
            "agent",
            "codex_stdout",
            json!({ "line": line }),
        )?;
    }
    for line in &stderr_lines {
        emit(
            json_output,
            "warning",
            "agent",
            "codex_stderr",
            json!({ "line": line }),
        )?;
    }
    if !status.success() {
        return Err(SymphonyError::CommandFailed {
            program: program.to_string(),
            args,
            status: status.code().unwrap_or(1),
            stderr: stderr_lines.join("\n"),
        });
    }
    emit(
        json_output,
        "success",
        "agent",
        "codex_completed",
        json!({}),
    )?;
    Ok(())
}

fn render_prompt(template: &str, issue: &NormalizedIssue, config: &WorkflowConfig) -> String {
    let body = if template.trim().is_empty() {
        "You are working on a GitHub issue.".to_string()
    } else {
        template.to_string()
    };
    body.replace("{{ issue.identifier }}", &issue.identifier)
        .replace("{{ issue.repo }}", &issue.repo)
        .replace("{{ issue.title }}", &issue.title)
        .replace(
            "{{ issue.description }}",
            issue.description.as_deref().unwrap_or(""),
        )
        .replace("{{ issue.url }}", issue.url.as_deref().unwrap_or(""))
        + &format!(
            "\n\nIssue number: {}\nRepository: {}\nBranch prefix: {}\nRun tests: {}\n",
            issue.number, issue.repo, config.branch_prefix, config.run_tests
        )
}

fn branch_name(prefix: &str, issue: &NormalizedIssue) -> String {
    let title_key = workspace_key(&issue.title).replace('_', "-");
    let short_title = title_key.chars().take(42).collect::<String>();
    format!(
        "{}/issue-{}-{}",
        prefix.trim_matches('/'),
        issue.number,
        short_title.trim_matches('-')
    )
}

fn parse_changed_files(status_porcelain: &str) -> Vec<String> {
    status_porcelain
        .lines()
        .filter_map(|line| {
            let path = line.get(3..)?.trim();
            if path.is_empty() {
                None
            } else if let Some((_, renamed_to)) = path.split_once(" -> ") {
                Some(renamed_to.to_string())
            } else {
                Some(path.to_string())
            }
        })
        .collect()
}

fn merge_changed_files(committed: &[String], uncommitted: &[String]) -> Vec<String> {
    let mut files = committed.to_vec();
    for file in uncommitted {
        if !files.contains(file) {
            files.push(file.clone());
        }
    }
    files
}

async fn remote_branch_exists(repo_path: &Path, branch_name: &str) -> bool {
    let remote_branch = format!("origin/{branch_name}");
    command_stdout(
        "git",
        &["rev-parse", "--verify", remote_branch.as_str()],
        Some(repo_path),
    )
    .await
    .is_ok()
}

async fn branch_has_commits(repo_path: &Path, base_branch: &str) -> Result<bool, SymphonyError> {
    let base = format!("origin/{base_branch}..HEAD");
    let output = command_stdout(
        "git",
        &["rev-list", "--count", base.as_str()],
        Some(repo_path),
    )
    .await?;
    Ok(output.trim().parse::<usize>().unwrap_or(0) > 0)
}

async fn committed_changed_files(
    repo_path: &Path,
    base_branch: &str,
) -> Result<Vec<String>, SymphonyError> {
    let base = format!("origin/{base_branch}...HEAD");
    let output = command_stdout(
        "git",
        &["diff", "--name-only", base.as_str()],
        Some(repo_path),
    )
    .await?;
    Ok(output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(ToString::to_string)
        .collect())
}

async fn existing_pull_request_url(
    repo: &str,
    branch_name: &str,
) -> Result<Option<String>, SymphonyError> {
    let output = command_stdout(
        "gh",
        &[
            "pr",
            "list",
            "--repo",
            repo,
            "--head",
            branch_name,
            "--state",
            "open",
            "--json",
            "url",
        ],
        None,
    )
    .await?;
    #[derive(Deserialize)]
    struct PullRequestListItem {
        url: String,
    }
    let pull_requests: Vec<PullRequestListItem> = serde_json::from_str(&output)?;
    Ok(pull_requests.into_iter().next().map(|pr| pr.url))
}

async fn create_pull_request(
    repo: &str,
    issue: &NormalizedIssue,
    branch_name: &str,
    default_branch: &str,
) -> Result<String, SymphonyError> {
    let title = format!("{}: {}", issue.identifier, issue.title);
    let body = format!(
        "Automated Auditorium run for {}.\n\nIssue: {}\n",
        issue.identifier,
        issue.url.clone().unwrap_or_default()
    );
    let url = command_stdout(
        "gh",
        &[
            "pr",
            "create",
            "--repo",
            repo,
            "--title",
            title.as_str(),
            "--body",
            body.as_str(),
            "--base",
            default_branch,
            "--head",
            branch_name,
        ],
        None,
    )
    .await?;
    Ok(url.trim().to_string())
}

async fn run_validation(command: &str, repo_path: &Path) -> Result<String, SymphonyError> {
    let output = Command::new("/bin/sh")
        .arg("-lc")
        .arg(command)
        .current_dir(repo_path)
        .output()
        .await?;
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let combined = match (stdout.is_empty(), stderr.is_empty()) {
        (true, true) => String::new(),
        (false, true) => stdout,
        (true, false) => stderr,
        (false, false) => format!("{stdout}\n{stderr}"),
    };
    if output.status.success() {
        Ok(combined)
    } else {
        Err(SymphonyError::CommandFailed {
            program: "/bin/sh".to_string(),
            args: vec!["-lc".to_string(), command.to_string()],
            status: output.status.code().unwrap_or(1),
            stderr: combined,
        })
    }
}

async fn write_report(
    config: &WorkflowConfig,
    run_id: &str,
    issue: &NormalizedIssue,
    workspace: &Path,
    workspace_manifest_path: &Path,
    branch_name: &str,
    status: &str,
    pull_request_url: Option<String>,
    changed_files: &[String],
    validation_output: Option<String>,
    started_at: DateTime<Utc>,
) -> Result<RunReport, SymphonyError> {
    let ended_at = Utc::now();
    let report_path = config
        .workspace_root
        .join("reports")
        .join(format!("{run_id}.md"));
    let markdown = render_report_markdown(
        run_id,
        issue,
        workspace,
        workspace_manifest_path,
        branch_name,
        status,
        pull_request_url.as_deref(),
        changed_files,
        validation_output.as_deref(),
        started_at,
        ended_at,
    );
    fs::write(&report_path, markdown).await?;
    Ok(RunReport {
        run_id: run_id.to_string(),
        repo: issue.repo.clone(),
        issue: issue.clone(),
        workspace_path: workspace.to_path_buf(),
        workspace_manifest_path: workspace_manifest_path.to_path_buf(),
        branch_name: branch_name.to_string(),
        status: status.to_string(),
        pull_request_url,
        report_path,
        changed_files: changed_files.to_vec(),
        validation_output,
        started_at,
        ended_at,
    })
}

fn render_report_markdown(
    run_id: &str,
    issue: &NormalizedIssue,
    workspace: &Path,
    workspace_manifest_path: &Path,
    branch_name: &str,
    status: &str,
    pull_request_url: Option<&str>,
    changed_files: &[String],
    validation_output: Option<&str>,
    started_at: DateTime<Utc>,
    ended_at: DateTime<Utc>,
) -> String {
    let changed_files_markdown = if changed_files.is_empty() {
        "No changed files detected.".to_string()
    } else {
        changed_files
            .iter()
            .map(|file| format!("- `{file}`"))
            .collect::<Vec<_>>()
            .join("\n")
    };
    let validation_markdown = validation_output
        .filter(|output| !output.trim().is_empty())
        .map(|output| format!("```text\n{}\n```", output.trim()))
        .unwrap_or_else(|| "No validation command was run.".to_string());
    format!(
        "# Auditorium Symphony Run\n\nRun ID: {run_id}\nRepository: {}\nIssue: {} {}\nStatus: {status}\nBranch: {branch_name}\nWorkspace: {}\nWorkspace Manifest: {}\nPull Request: {}\nStarted: {}\nEnded: {}\n\n## Issue\n{}\n\n## Changed Files\n{}\n\n## Validation\n{}\n",
        issue.repo,
        issue.identifier,
        issue.title,
        workspace.display(),
        workspace_manifest_path.display(),
        pull_request_url.unwrap_or("None"),
        started_at.to_rfc3339(),
        ended_at.to_rfc3339(),
        issue.description.clone().unwrap_or_default(),
        changed_files_markdown,
        validation_markdown
    )
}

fn emit(
    json_output: bool,
    level: &str,
    category: &str,
    message: &str,
    metadata: serde_json::Value,
) -> Result<(), SymphonyError> {
    let event = Event {
        level: level.to_string(),
        category: category.to_string(),
        message: message.to_string(),
        timestamp: Utc::now(),
        metadata,
    };
    if json_output {
        println!("{}", serde_json::to_string(&event)?);
    } else {
        eprintln!("[{}] {}: {}", event.level, event.category, event.message);
    }
    Ok(())
}

fn print_final_report(json_output: bool, report: &RunReport) -> Result<(), SymphonyError> {
    if json_output {
        println!("{}", serde_json::to_string(report)?);
    } else {
        println!("report: {}", report.report_path.display());
        if let Some(url) = &report.pull_request_url {
            println!("pull request: {url}");
        }
    }
    Ok(())
}

async fn check_command(program: &str, args: &[&str]) -> serde_json::Value {
    match command_stdout(program, args, None).await {
        Ok(output) => json!({
            "name": format!("{} {}", program, args.join(" ")),
            "ok": true,
            "detail": output.lines().next().unwrap_or_default()
        }),
        Err(error) => json!({
            "name": format!("{} {}", program, args.join(" ")),
            "ok": false,
            "code": error.code(),
            "detail": error.to_string()
        }),
    }
}

async fn git(repo_path: &Path, args: &[&str]) -> Result<(), SymphonyError> {
    command_stdout("git", args, Some(repo_path))
        .await
        .map(|_| ())
}

async fn command_stdout(
    program: &str,
    args: &[&str],
    cwd: Option<&Path>,
) -> Result<String, SymphonyError> {
    let mut command = Command::new(program);
    command.args(args);
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    let output = command.output().await?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        Err(SymphonyError::CommandFailed {
            program: program.to_string(),
            args: args.iter().map(|arg| arg.to_string()).collect(),
            status: output.status.code().unwrap_or(1),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
        })
    }
}

#[allow(dead_code)]
fn env_map() -> BTreeMap<String, String> {
    env::vars().collect()
}

#[allow(dead_code)]
fn os_str(value: &str) -> &OsStr {
    OsStr::new(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_front_matter_and_prompt() {
        let workflow = parse_workflow(
            r#"---
tracker:
  kind: github
agent:
  max_concurrent_agents: 2
---
Hello {{ issue.title }}
"#,
        )
        .unwrap();

        assert_eq!(workflow.prompt_template, "Hello {{ issue.title }}");
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();
        assert_eq!(config.tracker_kind, "github");
        assert_eq!(config.max_concurrent_agents, 2);
    }

    #[test]
    fn rejects_non_map_front_matter() {
        let error = parse_workflow("---\n- nope\n---\nBody").unwrap_err();
        assert!(matches!(error, SymphonyError::WorkflowFrontMatterNotMap));
    }

    #[test]
    fn workspace_keys_are_stable() {
        assert_eq!(workspace_key("BUR-101 Fix OAuth"), "bur-101_fix_oauth");
    }

    #[test]
    fn workspace_keys_prevent_path_traversal() {
        assert_eq!(
            workspace_key("../Issue 42/../../secrets"),
            ".._issue_42_.._.._secrets"
        );
        assert_eq!(workspace_key("Fix Café 🔐"), "fix_caf___");
    }

    #[test]
    fn branch_names_are_deterministic() {
        let issue = mock_issue("charlie/auditorium", 42);
        assert!(branch_name("auditorium", &issue).starts_with("auditorium/issue-42-"));
    }

    #[test]
    fn parses_validation_command() {
        let workflow = parse_workflow(
            r#"---
validation:
  command: "cargo test --all-targets"
---
Body
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();

        assert_eq!(
            config.validation_command.as_deref(),
            Some("cargo test --all-targets")
        );
    }

    #[test]
    fn resolves_config_defaults() {
        let workflow = parse_workflow("Body").unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/project/WORKFLOW.md")).unwrap();

        assert_eq!(config.tracker_kind, "github");
        assert_eq!(config.polling_interval_ms, 30_000);
        assert_eq!(
            config.workspace_root,
            PathBuf::from("/tmp/project/.auditorium/symphony-workspaces")
        );
        assert_eq!(config.max_concurrent_agents, 3);
        assert_eq!(config.max_turns, 1);
        assert_eq!(config.max_retry_backoff_ms, 300_000);
        assert_eq!(config.branch_prefix, "auditorium");
        assert_eq!(config.max_retries, 2);
        assert!(config.run_tests);
        assert!(config.open_pull_request);
        assert_eq!(
            config.codex_command,
            "codex exec --json --sandbox workspace-write -c approval_policy=\"never\""
        );
    }

    #[test]
    fn parses_changed_files_from_porcelain_status() {
        let files = parse_changed_files(" M README.md\n?? src/main.rs\nR  old.rs -> new.rs\n");

        assert_eq!(files, vec!["README.md", "src/main.rs", "new.rs"]);
    }

    #[test]
    fn merges_committed_and_uncommitted_changed_files() {
        let files = merge_changed_files(
            &["README.md".to_string(), "symphony/src/lib.rs".to_string()],
            &["README.md".to_string(), "WORKFLOW.md".to_string()],
        );

        assert_eq!(
            files,
            vec!["README.md", "symphony/src/lib.rs", "WORKFLOW.md"]
        );
    }

    #[test]
    fn rejects_non_github_tracker_for_v0() {
        let workflow = parse_workflow(
            r#"---
tracker:
  kind: linear
---
Body
"#,
        )
        .unwrap();
        let error = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap_err();

        assert!(matches!(error, SymphonyError::InvalidConfig(_)));
        assert!(error.to_string().contains("tracker.kind must be github"));
    }

    #[test]
    fn rejects_zero_concurrency() {
        let workflow = parse_workflow(
            r#"---
agent:
  max_concurrent_agents: 0
---
Body
"#,
        )
        .unwrap();
        let error = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap_err();

        assert!(error
            .to_string()
            .contains("agent.max_concurrent_agents must be positive"));
    }

    #[test]
    fn rejects_empty_codex_command() {
        let workflow = parse_workflow(
            r#"---
codex:
  command: ""
---
Body
"#,
        )
        .unwrap();
        let error = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap_err();

        assert!(error
            .to_string()
            .contains("codex.command must not be empty"));
    }

    #[test]
    fn rejects_zero_max_turns() {
        let workflow = parse_workflow(
            r#"---
agent:
  max_turns: 0
---
Body
"#,
        )
        .unwrap();
        let error = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap_err();

        assert!(error
            .to_string()
            .contains("agent.max_turns must be positive"));
    }

    #[test]
    fn normalizes_github_issue_payload() {
        let issue = normalize_github_issue_payload(
            "acme/app",
            r#"{
  "id": "I_kwDOExample",
  "number": 42,
  "title": "Fix OAuth",
  "body": "Use device flow.",
  "url": "https://github.com/acme/app/issues/42",
  "labels": [{ "name": "Bug" }, { "name": "Needs Review" }],
  "assignees": [{ "login": "charlie" }],
  "state": "OPEN",
  "createdAt": "2026-06-01T12:00:00Z",
  "updatedAt": "2026-06-02T12:00:00Z"
}"#,
        )
        .unwrap();

        assert_eq!(issue.id, "I_kwDOExample");
        assert_eq!(issue.identifier, "#42");
        assert_eq!(issue.repo, "acme/app");
        assert_eq!(issue.number, 42);
        assert_eq!(issue.title, "Fix OAuth");
        assert_eq!(issue.description.as_deref(), Some("Use device flow."));
        assert_eq!(
            issue.url.as_deref(),
            Some("https://github.com/acme/app/issues/42")
        );
        assert_eq!(issue.labels, vec!["bug", "needs review"]);
        assert_eq!(issue.assignees, vec!["charlie"]);
        assert_eq!(issue.state, "open");
        assert_eq!(issue.created_at.as_deref(), Some("2026-06-01T12:00:00Z"));
        assert_eq!(issue.updated_at.as_deref(), Some("2026-06-02T12:00:00Z"));
    }

    #[test]
    fn render_prompt_substitutes_issue_fields_and_policy() {
        let issue = NormalizedIssue {
            title: "Fix onboarding".to_string(),
            description: Some("OAuth button is unclear.".to_string()),
            url: Some("https://github.com/acme/app/issues/7".to_string()),
            ..mock_issue("acme/app", 7)
        };
        let workflow = parse_workflow(
            r#"---
branch_prefix: "tickets"
run_tests: false
---
Handle {{ issue.identifier }} in {{ issue.repo }}: {{ issue.title }}
{{ issue.description }}
{{ issue.url }}
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();

        let prompt = render_prompt(&workflow.prompt_template, &issue, &config);

        assert!(prompt.contains("Handle #7 in acme/app: Fix onboarding"));
        assert!(prompt.contains("OAuth button is unclear."));
        assert!(prompt.contains("https://github.com/acme/app/issues/7"));
        assert!(prompt.contains("Branch prefix: tickets"));
        assert!(prompt.contains("Run tests: false"));
    }

    #[tokio::test]
    async fn prepare_workspace_creates_ticket_and_reports_directories() {
        let tempdir = tempfile::tempdir().unwrap();
        let workflow = parse_workflow(&format!(
            r#"---
workspace:
  root: "{}"
---
Body
"#,
            tempdir.path().join("workspaces").display()
        ))
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();
        let issue = mock_issue("acme/app", 11);

        let workspace = prepare_workspace(&config, &issue).await.unwrap();

        assert!(workspace.ends_with("_11"));
        assert!(workspace.is_dir());
        assert!(config.workspace_root.join("reports").is_dir());
    }

    #[tokio::test]
    async fn write_report_persists_reviewable_markdown() {
        let tempdir = tempfile::tempdir().unwrap();
        let workflow = parse_workflow(&format!(
            r#"---
workspace:
  root: "{}"
---
Body
"#,
            tempdir.path().join("workspaces").display()
        ))
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();
        fs::create_dir_all(config.workspace_root.join("reports"))
            .await
            .unwrap();
        let issue = mock_issue("acme/app", 12);
        let workspace = config.workspace_root.join("#12");
        let manifest_path = workspace.join("workspace-manifest.json");

        let report = write_report(
            &config,
            "run-12",
            &issue,
            &workspace,
            &manifest_path,
            "auditorium/issue-12-mock-auditorium-issue",
            "completed",
            Some("https://github.com/acme/app/pull/34".to_string()),
            &["README.md".to_string(), "src/lib.rs".to_string()],
            Some("tests passed".to_string()),
            Utc::now(),
        )
        .await
        .unwrap();
        let markdown = fs::read_to_string(&report.report_path).await.unwrap();

        assert_eq!(report.status, "completed");
        assert_eq!(report.workspace_manifest_path, manifest_path);
        assert!(markdown.contains("# Auditorium Symphony Run"));
        assert!(markdown.contains("Workspace Manifest:"));
        assert!(markdown.contains("Pull Request: https://github.com/acme/app/pull/34"));
        assert!(markdown.contains("- `README.md`"));
        assert!(markdown.contains("tests passed"));
    }

    #[test]
    fn render_report_markdown_matches_golden_output() {
        let issue = NormalizedIssue {
            description: Some("The setup flow needs a clearer credential state.".to_string()),
            ..mock_issue("acme/app", 12)
        };
        let started_at = DateTime::parse_from_rfc3339("2026-06-07T01:02:03Z")
            .unwrap()
            .with_timezone(&Utc);
        let ended_at = DateTime::parse_from_rfc3339("2026-06-07T01:04:05Z")
            .unwrap()
            .with_timezone(&Utc);

        let markdown = render_report_markdown(
            "run-12",
            &issue,
            Path::new("/tmp/workspaces/_12"),
            Path::new("/tmp/workspaces/_12/workspace-manifest.json"),
            "auditorium/issue-12-mock-auditorium-issue",
            "completed",
            None,
            &[],
            None,
            started_at,
            ended_at,
        );

        assert_eq!(
            markdown,
            "# Auditorium Symphony Run\n\nRun ID: run-12\nRepository: acme/app\nIssue: #12 Mock Auditorium issue\nStatus: completed\nBranch: auditorium/issue-12-mock-auditorium-issue\nWorkspace: /tmp/workspaces/_12\nWorkspace Manifest: /tmp/workspaces/_12/workspace-manifest.json\nPull Request: None\nStarted: 2026-06-07T01:02:03+00:00\nEnded: 2026-06-07T01:04:05+00:00\n\n## Issue\nThe setup flow needs a clearer credential state.\n\n## Changed Files\nNo changed files detected.\n\n## Validation\nNo validation command was run.\n"
        );
    }

    #[tokio::test]
    async fn write_workspace_manifest_persists_inspectable_json() {
        let tempdir = tempfile::tempdir().unwrap();
        let workspace = tempdir.path().join("_44");
        fs::create_dir_all(&workspace).await.unwrap();
        let repo_path = workspace.join("repo");
        let workflow_path = tempdir.path().join("WORKFLOW.md");
        let issue = mock_issue("acme/app", 44);
        let created_at = DateTime::parse_from_rfc3339("2026-06-07T01:02:03Z")
            .unwrap()
            .with_timezone(&Utc);

        let manifest_path = write_workspace_manifest(
            "run-44",
            &issue,
            &workspace,
            &repo_path,
            "auditorium/issue-44-mock-auditorium-issue",
            &workflow_path,
            created_at,
        )
        .await
        .unwrap();
        let manifest: WorkspaceManifest =
            serde_json::from_str(&fs::read_to_string(&manifest_path).await.unwrap()).unwrap();

        assert_eq!(manifest.run_id, "run-44");
        assert_eq!(manifest.repo, "acme/app");
        assert_eq!(manifest.issue_identifier, "#44");
        assert_eq!(manifest.issue_number, 44);
        assert_eq!(manifest.workspace_path, workspace);
        assert_eq!(manifest.repo_path, repo_path);
        assert_eq!(
            manifest.branch_name,
            "auditorium/issue-44-mock-auditorium-issue"
        );
        assert_eq!(manifest.workflow_path, workflow_path);
        assert_eq!(manifest.created_at, created_at);
    }

    #[tokio::test]
    async fn run_validation_returns_combined_output() {
        let tempdir = tempfile::tempdir().unwrap();

        let output = run_validation(
            "printf 'stdout-line'; printf 'stderr-line' >&2",
            tempdir.path(),
        )
        .await
        .unwrap();

        assert_eq!(output, "stdout-line\nstderr-line");
    }

    #[tokio::test]
    async fn run_validation_failure_uses_stable_error_code() {
        let tempdir = tempfile::tempdir().unwrap();

        let error = run_validation("printf 'nope' >&2; exit 13", tempdir.path())
            .await
            .unwrap_err();

        assert_eq!(error.code(), "command_failed");
        assert_eq!(error.exit_code(), 30);
        assert!(error.to_string().contains("nope"));
    }

    #[tokio::test]
    async fn daemon_workflow_loader_detects_reloaded_workflow() {
        let tempdir = tempfile::tempdir().unwrap();
        let workflow = tempdir.path().join("WORKFLOW.md");
        fs::write(
            &workflow,
            r#"---
agent:
  max_concurrent_agents: 1
polling:
  interval_ms: 25
---
Prompt
"#,
        )
        .await
        .unwrap();
        let mut loader = DaemonWorkflowLoader::default();

        let first = loader.load(&workflow).await.unwrap();
        sleep(Duration::from_millis(20)).await;
        fs::write(
            &workflow,
            r#"---
agent:
  max_concurrent_agents: 4
polling:
  interval_ms: 50
---
Prompt
"#,
        )
        .await
        .unwrap();
        let second = loader.load(&workflow).await.unwrap();
        let third = loader.load(&workflow).await.unwrap();

        assert!(first.reloaded);
        assert_eq!(first.revision, 1);
        assert_eq!(first.config.max_concurrent_agents, 1);
        assert!(second.reloaded);
        assert_eq!(second.revision, 2);
        assert_eq!(second.config.max_concurrent_agents, 4);
        assert_eq!(second.config.polling_interval_ms, 50);
        assert!(!third.reloaded);
        assert_eq!(third.revision, 2);
    }

    #[tokio::test]
    async fn daemon_rejects_zero_tick_limit() {
        let tempdir = tempfile::tempdir().unwrap();
        let error = daemon(DaemonOptions {
            project: "project-1".to_string(),
            workflow: tempdir.path().join("WORKFLOW.md"),
            json: true,
            watch: true,
            max_ticks: Some(0),
            poll_interval_ms: Some(1),
        })
        .await
        .unwrap_err();

        assert_eq!(error.code(), "invalid_config");
        assert!(error.to_string().contains("max_ticks"));
    }
}
