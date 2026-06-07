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
    pub active_states: Vec<String>,
    pub terminal_states: Vec<String>,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DaemonProjectState {
    pub project: String,
    pub repository: Option<String>,
    #[serde(default)]
    pub issue_query: Option<String>,
    #[serde(default)]
    pub execute_dispatches: bool,
    #[serde(default)]
    pub mock: bool,
    #[serde(default)]
    pub dry_run: bool,
    #[serde(default)]
    pub no_pr: bool,
    #[serde(default)]
    pub runs: Vec<DaemonRunState>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DaemonRunState {
    pub issue_identifier: String,
    pub run_state: SchedulerRunState,
    #[serde(default)]
    pub retry_count: usize,
    #[serde(default)]
    pub not_before_tick: u64,
    #[serde(default)]
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SchedulerPlan {
    pub project: String,
    pub tick: u64,
    pub polled_issue_count: usize,
    pub running_count: usize,
    pub capacity: usize,
    pub eligible_count: usize,
    pub dispatches: Vec<SchedulerDispatch>,
    pub skipped_terminal_count: usize,
    pub skipped_running_count: usize,
    pub skipped_blocked_count: usize,
    pub skipped_canceled_count: usize,
    pub retry_ready_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SchedulerDispatch {
    pub issue_identifier: String,
    pub issue_number: u64,
    pub repo: String,
    pub retry_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SchedulerReconciliation {
    pub issue_identifier: String,
    pub retry_count: usize,
    pub not_before_tick: u64,
    pub reason: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SchedulerDispatchOutcome {
    Succeeded,
    Failed,
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

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SchedulerRunState {
    Pending,
    Running,
    Completed,
    Failed,
    Blocked,
    Canceled,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SchedulerItem {
    pub issue_identifier: String,
    pub issue_state: String,
    pub run_state: SchedulerRunState,
    pub retry_count: usize,
    pub not_before_tick: u64,
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
        let plan = daemon_scheduler_plan(&options, tick as u64, &loaded.config).await?;
        emit_daemon_tick(&options, tick, &loaded, plan.as_ref())?;

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
    plan: Option<&SchedulerPlan>,
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
            "maxConcurrentAgents": loaded.config.max_concurrent_agents,
            "scheduler": plan
        }),
    )
}

async fn daemon_scheduler_plan(
    options: &DaemonOptions,
    tick: u64,
    config: &WorkflowConfig,
) -> Result<Option<SchedulerPlan>, SymphonyError> {
    let Some(mut project_state) = load_daemon_project_state(config, &options.project).await? else {
        return Ok(None);
    };
    let reconciliations = reconcile_stale_running_runs(&mut project_state, config, tick);
    if !reconciliations.is_empty() {
        for reconciliation in &reconciliations {
            emit(
                options.json,
                "warning",
                "orchestration",
                "daemon_run_reconciled",
                json!({
                    "project": &project_state.project,
                    "issue": &reconciliation.issue_identifier,
                    "retryCount": reconciliation.retry_count,
                    "notBeforeTick": reconciliation.not_before_tick,
                    "reason": &reconciliation.reason
                }),
            )?;
        }
        write_daemon_project_state(config, &options.project, &project_state).await?;
    }

    let Some(repository) = project_state.repository.clone() else {
        return Ok(None);
    };
    let issue_query = project_state.issue_query.clone();

    let issues = fetch_github_issues(&repository, issue_query.as_deref()).await?;
    let plan = plan_scheduler_tick(
        &project_state.project,
        tick,
        &issues,
        &project_state.runs,
        config,
    );
    write_scheduler_plan(config, &options.project, &plan).await?;
    execute_scheduler_dispatches(options, config, &mut project_state, &plan).await?;
    Ok(Some(plan))
}

async fn execute_scheduler_dispatches(
    options: &DaemonOptions,
    config: &WorkflowConfig,
    project_state: &mut DaemonProjectState,
    plan: &SchedulerPlan,
) -> Result<(), SymphonyError> {
    if !project_state.execute_dispatches {
        return Ok(());
    }

    for dispatch in &plan.dispatches {
        emit(
            options.json,
            "info",
            "orchestration",
            "daemon_dispatch_started",
            json!({
                "project": &project_state.project,
                "issue": &dispatch.issue_identifier,
                "repo": &dispatch.repo,
                "retryCount": dispatch.retry_count
            }),
        )?;
        record_dispatch_started(project_state, dispatch, config, plan.tick);
        write_daemon_project_state(config, &options.project, project_state).await?;

        let result = run_issue(RunOptions {
            repo: dispatch.repo.clone(),
            issue: dispatch.issue_number,
            workflow: options.workflow.clone(),
            workspace_root: Some(config.workspace_root.clone()),
            json: options.json,
            mock: project_state.mock,
            dry_run: project_state.dry_run,
            no_pr: project_state.no_pr,
        })
        .await;

        match result {
            Ok(()) => {
                record_dispatch_result(
                    project_state,
                    dispatch,
                    SchedulerDispatchOutcome::Succeeded,
                    config,
                    plan.tick,
                    None,
                );
                emit(
                    options.json,
                    "success",
                    "orchestration",
                    "daemon_dispatch_completed",
                    json!({
                        "project": &project_state.project,
                        "issue": &dispatch.issue_identifier,
                        "repo": &dispatch.repo
                    }),
                )?;
            }
            Err(error) => {
                let code = error.code();
                let message = error.to_string();
                record_dispatch_result(
                    project_state,
                    dispatch,
                    SchedulerDispatchOutcome::Failed,
                    config,
                    plan.tick,
                    Some(message.clone()),
                );
                emit(
                    options.json,
                    "warning",
                    "orchestration",
                    "daemon_dispatch_failed",
                    json!({
                        "project": &project_state.project,
                        "issue": &dispatch.issue_identifier,
                        "repo": &dispatch.repo,
                        "code": code,
                        "error": message
                    }),
                )?;
            }
        }
        write_daemon_project_state(config, &options.project, project_state).await?;
    }

    Ok(())
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

pub fn daemon_project_dir(config: &WorkflowConfig, project: &str) -> PathBuf {
    config
        .workspace_root
        .join("projects")
        .join(workspace_key(project))
}

pub fn daemon_project_state_path(config: &WorkflowConfig, project: &str) -> PathBuf {
    daemon_project_dir(config, project).join("project-state.json")
}

pub fn daemon_scheduler_plan_path(config: &WorkflowConfig, project: &str) -> PathBuf {
    daemon_project_dir(config, project).join("last-scheduler-plan.json")
}

async fn load_daemon_project_state(
    config: &WorkflowConfig,
    project: &str,
) -> Result<Option<DaemonProjectState>, SymphonyError> {
    let path = daemon_project_state_path(config, project);
    let data = match fs::read_to_string(&path).await {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(SymphonyError::Io(error)),
    };
    let state: DaemonProjectState = serde_json::from_str(&data)?;
    if state.project != project {
        return Err(SymphonyError::InvalidConfig(format!(
            "daemon project state at {} is for project {}, expected {project}",
            path.display(),
            state.project
        )));
    }
    Ok(Some(state))
}

async fn write_daemon_project_state(
    config: &WorkflowConfig,
    project: &str,
    state: &DaemonProjectState,
) -> Result<PathBuf, SymphonyError> {
    let path = daemon_project_state_path(config, project);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).await?;
    }
    fs::write(&path, serde_json::to_vec_pretty(state)?).await?;
    Ok(path)
}

async fn write_scheduler_plan(
    config: &WorkflowConfig,
    project: &str,
    plan: &SchedulerPlan,
) -> Result<PathBuf, SymphonyError> {
    let path = daemon_scheduler_plan_path(config, project);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).await?;
    }
    fs::write(&path, serde_json::to_vec_pretty(plan)?).await?;
    Ok(path)
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

    let tracker_kind =
        string_from_map(tracker, "tracker", "kind")?.unwrap_or_else(|| "github".to_string());
    if tracker_kind != "github" {
        return Err(SymphonyError::InvalidConfig(format!(
            "tracker.kind must be github for Auditorium v0, got {tracker_kind}"
        )));
    }
    let workspace_root = string_from_map(workspace, "workspace", "root")?
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(".auditorium/symphony-workspaces"));
    let branch_prefix = string_from_root(&definition.config, "branch_prefix")?
        .unwrap_or_else(|| "auditorium".to_string());
    let branch_prefix = branch_prefix.trim().trim_matches('/').to_string();

    let config = WorkflowConfig {
        tracker_kind,
        active_states: string_array_from_map(tracker, "tracker", "active_states")?
            .unwrap_or_else(|| vec!["open".to_string()]),
        terminal_states: string_array_from_map(tracker, "tracker", "terminal_states")?
            .unwrap_or_else(|| vec!["closed".to_string()]),
        polling_interval_ms: int_from_map(polling, "polling", "interval_ms")?.unwrap_or(30_000),
        workspace_root: absolute_path(&workspace_root, workflow_dir),
        max_concurrent_agents: int_from_map(agent, "agent", "max_concurrent_agents")?.unwrap_or(3)
            as usize,
        max_turns: int_from_map(agent, "agent", "max_turns")?.unwrap_or(1) as usize,
        max_retry_backoff_ms: int_from_map(agent, "agent", "max_retry_backoff_ms")?
            .unwrap_or(300_000),
        codex_command: string_from_map(codex, "codex", "command")?.unwrap_or_else(|| {
            "codex exec --json --sandbox workspace-write -c approval_policy=\"never\"".to_string()
        }),
        branch_prefix,
        max_retries: int_from_root(&definition.config, "max_retries")?.unwrap_or(2) as usize,
        run_tests: bool_from_root(&definition.config, "run_tests")?.unwrap_or(true),
        open_pull_request: bool_from_root(&definition.config, "open_pull_request")?.unwrap_or(true),
        validation_command: string_from_map(validation, "validation", "command")?
            .filter(|command| !command.trim().is_empty()),
    };
    if config.active_states.is_empty() {
        return Err(SymphonyError::InvalidConfig(
            "tracker.active_states must include at least one state".to_string(),
        ));
    }
    if config.terminal_states.is_empty() {
        return Err(SymphonyError::InvalidConfig(
            "tracker.terminal_states must include at least one state".to_string(),
        ));
    }
    if config.polling_interval_ms == 0 {
        return Err(SymphonyError::InvalidConfig(
            "polling.interval_ms must be positive".to_string(),
        ));
    }
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
    if config.branch_prefix.is_empty() {
        return Err(SymphonyError::InvalidConfig(
            "branch_prefix must not be empty".to_string(),
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

fn string_from_root(
    mapping: &serde_yaml::Mapping,
    key: &str,
) -> Result<Option<String>, SymphonyError> {
    let Some(value) = mapping_value(mapping, key) else {
        return Ok(None);
    };
    value
        .as_str()
        .map(resolve_env_value)
        .map(Some)
        .ok_or_else(|| SymphonyError::InvalidConfig(format!("{key} must be a string")))
}

fn bool_from_root(mapping: &serde_yaml::Mapping, key: &str) -> Result<Option<bool>, SymphonyError> {
    let Some(value) = mapping_value(mapping, key) else {
        return Ok(None);
    };
    value
        .as_bool()
        .map(Some)
        .ok_or_else(|| SymphonyError::InvalidConfig(format!("{key} must be a boolean")))
}

fn int_from_root(mapping: &serde_yaml::Mapping, key: &str) -> Result<Option<u64>, SymphonyError> {
    let Some(value) = mapping_value(mapping, key) else {
        return Ok(None);
    };
    yaml_u64(value).map(Some).ok_or_else(|| {
        SymphonyError::InvalidConfig(format!("{key} must be a non-negative integer"))
    })
}

fn string_from_map(
    mapping: Option<&serde_yaml::Mapping>,
    section: &str,
    key: &str,
) -> Result<Option<String>, SymphonyError> {
    let Some(value) = mapping.and_then(|mapping| mapping_value(mapping, key)) else {
        return Ok(None);
    };
    value
        .as_str()
        .map(resolve_env_value)
        .map(Some)
        .ok_or_else(|| SymphonyError::InvalidConfig(format!("{section}.{key} must be a string")))
}

fn int_from_map(
    mapping: Option<&serde_yaml::Mapping>,
    section: &str,
    key: &str,
) -> Result<Option<u64>, SymphonyError> {
    let Some(value) = mapping.and_then(|mapping| mapping_value(mapping, key)) else {
        return Ok(None);
    };
    yaml_u64(value).map(Some).ok_or_else(|| {
        SymphonyError::InvalidConfig(format!("{section}.{key} must be a non-negative integer"))
    })
}

fn string_array_from_map(
    mapping: Option<&serde_yaml::Mapping>,
    section: &str,
    key: &str,
) -> Result<Option<Vec<String>>, SymphonyError> {
    let Some(value) = mapping.and_then(|mapping| mapping_value(mapping, key)) else {
        return Ok(None);
    };
    let values = value.as_sequence().ok_or_else(|| {
        SymphonyError::InvalidConfig(format!("{section}.{key} must be a string array"))
    })?;
    let mut strings = Vec::new();
    for (index, value) in values.iter().enumerate() {
        let string = value.as_str().ok_or_else(|| {
            SymphonyError::InvalidConfig(format!("{section}.{key}[{index}] must be a string"))
        })?;
        let normalized = string.trim().to_lowercase();
        if normalized.is_empty() {
            return Err(SymphonyError::InvalidConfig(format!(
                "{section}.{key}[{index}] must not be empty"
            )));
        }
        strings.push(normalized);
    }
    Ok(Some(strings))
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

async fn fetch_github_issues(
    repo: &str,
    issue_query: Option<&str>,
) -> Result<Vec<NormalizedIssue>, SymphonyError> {
    let mut args = vec![
        "issue".to_string(),
        "list".to_string(),
        "--repo".to_string(),
        repo.to_string(),
        "--state".to_string(),
        "all".to_string(),
        "--limit".to_string(),
        "100".to_string(),
        "--json".to_string(),
        "id,number,title,body,url,labels,assignees,state,createdAt,updatedAt".to_string(),
    ];
    if let Some(query) = issue_query.filter(|query| !query.trim().is_empty()) {
        args.push("--search".to_string());
        args.push(query.to_string());
    }
    let arg_refs = args.iter().map(String::as_str).collect::<Vec<_>>();
    let output = command_stdout("gh", &arg_refs, None).await?;
    normalize_github_issues_payload(repo, &output)
}

fn normalize_github_issues_payload(
    repo: &str,
    output: &str,
) -> Result<Vec<NormalizedIssue>, SymphonyError> {
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
        #[serde(default)]
        labels: Vec<GhLabel>,
        #[serde(default)]
        assignees: Vec<GhAssignee>,
        state: String,
        created_at: Option<String>,
        updated_at: Option<String>,
    }

    let issues: Vec<GhIssue> = serde_json::from_str(output)?;
    Ok(issues
        .into_iter()
        .map(|issue| NormalizedIssue {
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
        .collect())
}

fn split_command_line(command: &str) -> Result<Vec<String>, SymphonyError> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    let mut saw_token = false;

    for character in command.chars() {
        if escaped {
            current.push(character);
            saw_token = true;
            escaped = false;
            continue;
        }

        match (quote, character) {
            (None, '\\') | (Some('"'), '\\') => {
                escaped = true;
                saw_token = true;
            }
            (None, '\'' | '"') => {
                quote = Some(character);
                saw_token = true;
            }
            (Some(active_quote), character) if character == active_quote => {
                quote = None;
                saw_token = true;
            }
            (None, character) if character.is_whitespace() => {
                if saw_token {
                    parts.push(std::mem::take(&mut current));
                    saw_token = false;
                }
            }
            (_, character) => {
                current.push(character);
                saw_token = true;
            }
        }
    }

    if escaped {
        return Err(SymphonyError::InvalidConfig(
            "command must not end with an unfinished escape".to_string(),
        ));
    }
    if let Some(active_quote) = quote {
        return Err(SymphonyError::InvalidConfig(format!(
            "command contains an unmatched {active_quote} quote"
        )));
    }
    if saw_token {
        parts.push(current);
    }
    if parts.is_empty() {
        return Err(SymphonyError::InvalidConfig(
            "command must include a program".to_string(),
        ));
    }
    Ok(parts)
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
    let parts = split_command_line(&config.codex_command)?;
    let (program, args) = parts.split_first().ok_or_else(|| {
        SymphonyError::InvalidConfig("codex.command must not be empty".to_string())
    })?;
    let args = args.to_vec();
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
            program: program.clone(),
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

pub fn retry_backoff_ms(config: &WorkflowConfig, retry_count: usize) -> u64 {
    if retry_count == 0 {
        return 0;
    }
    let multiplier = 1u64
        .checked_shl((retry_count - 1).min(20) as u32)
        .unwrap_or(1);
    config
        .polling_interval_ms
        .saturating_mul(multiplier)
        .min(config.max_retry_backoff_ms)
}

pub fn dispatch_batch(
    items: &[SchedulerItem],
    config: &WorkflowConfig,
    running_count: usize,
    tick: u64,
) -> Vec<SchedulerItem> {
    let capacity = config.max_concurrent_agents.saturating_sub(running_count);
    items
        .iter()
        .filter(|item| is_dispatch_eligible(item, config, tick))
        .take(capacity)
        .cloned()
        .collect()
}

pub fn plan_scheduler_tick(
    project: &str,
    tick: u64,
    issues: &[NormalizedIssue],
    run_states: &[DaemonRunState],
    config: &WorkflowConfig,
) -> SchedulerPlan {
    let states_by_issue = run_states
        .iter()
        .map(|run| (run.issue_identifier.as_str(), run))
        .collect::<BTreeMap<_, _>>();
    let items = issues
        .iter()
        .map(|issue| {
            let run = states_by_issue.get(issue.identifier.as_str());
            SchedulerItem {
                issue_identifier: issue.identifier.clone(),
                issue_state: issue.state.clone(),
                run_state: run
                    .map(|run| run.run_state)
                    .unwrap_or(SchedulerRunState::Pending),
                retry_count: run.map(|run| run.retry_count).unwrap_or(0),
                not_before_tick: run.map(|run| run.not_before_tick).unwrap_or(0),
            }
        })
        .collect::<Vec<_>>();
    let running_count = items
        .iter()
        .filter(|item| item.run_state == SchedulerRunState::Running)
        .count();
    let capacity = config.max_concurrent_agents.saturating_sub(running_count);
    let dispatch_items = dispatch_batch(&items, config, running_count, tick);
    let dispatches = dispatch_items
        .iter()
        .filter_map(|item| {
            let issue = issues
                .iter()
                .find(|issue| issue.identifier == item.issue_identifier)?;
            Some(SchedulerDispatch {
                issue_identifier: issue.identifier.clone(),
                issue_number: issue.number,
                repo: issue.repo.clone(),
                retry_count: item.retry_count,
            })
        })
        .collect::<Vec<_>>();

    SchedulerPlan {
        project: project.to_string(),
        tick,
        polled_issue_count: issues.len(),
        running_count,
        capacity,
        eligible_count: items
            .iter()
            .filter(|item| is_dispatch_eligible(item, config, tick))
            .count(),
        dispatches,
        skipped_terminal_count: items
            .iter()
            .filter(|item| {
                config
                    .terminal_states
                    .contains(&item.issue_state.to_lowercase())
            })
            .count(),
        skipped_running_count: items
            .iter()
            .filter(|item| item.run_state == SchedulerRunState::Running)
            .count(),
        skipped_blocked_count: items
            .iter()
            .filter(|item| item.run_state == SchedulerRunState::Blocked)
            .count(),
        skipped_canceled_count: items
            .iter()
            .filter(|item| item.run_state == SchedulerRunState::Canceled)
            .count(),
        retry_ready_count: items
            .iter()
            .filter(|item| {
                item.run_state == SchedulerRunState::Failed
                    && is_dispatch_eligible(item, config, tick)
            })
            .count(),
    }
}

pub fn record_dispatch_started(
    state: &mut DaemonProjectState,
    dispatch: &SchedulerDispatch,
    config: &WorkflowConfig,
    tick: u64,
) {
    let run = daemon_run_state_mut(state, &dispatch.issue_identifier);
    run.run_state = SchedulerRunState::Running;
    run.not_before_tick = tick.saturating_add(config.max_turns as u64);
    run.last_error = None;
}

pub fn record_dispatch_result(
    state: &mut DaemonProjectState,
    dispatch: &SchedulerDispatch,
    outcome: SchedulerDispatchOutcome,
    config: &WorkflowConfig,
    tick: u64,
    error: Option<String>,
) {
    let run = daemon_run_state_mut(state, &dispatch.issue_identifier);
    match outcome {
        SchedulerDispatchOutcome::Succeeded => {
            run.run_state = SchedulerRunState::Completed;
            run.not_before_tick = 0;
            run.last_error = None;
        }
        SchedulerDispatchOutcome::Failed => {
            run.run_state = SchedulerRunState::Failed;
            run.retry_count = run.retry_count.saturating_add(1);
            run.not_before_tick = tick.saturating_add(retry_backoff_ticks(config, run.retry_count));
            run.last_error = error;
        }
    }
}

pub fn retry_backoff_ticks(config: &WorkflowConfig, retry_count: usize) -> u64 {
    if config.polling_interval_ms == 0 {
        return 0;
    }
    let backoff_ms = retry_backoff_ms(config, retry_count);
    backoff_ms.div_ceil(config.polling_interval_ms)
}

pub fn reconcile_stale_running_runs(
    state: &mut DaemonProjectState,
    config: &WorkflowConfig,
    tick: u64,
) -> Vec<SchedulerReconciliation> {
    let mut reconciliations = Vec::new();
    for run in &mut state.runs {
        if run.run_state != SchedulerRunState::Running {
            continue;
        }
        if run.not_before_tick == 0 || tick < run.not_before_tick {
            continue;
        }
        let reason = format!("running run exceeded daemon deadline at tick {tick}");
        run.run_state = SchedulerRunState::Failed;
        run.retry_count = run.retry_count.saturating_add(1);
        run.not_before_tick = tick.saturating_add(retry_backoff_ticks(config, run.retry_count));
        run.last_error = Some(reason.clone());
        reconciliations.push(SchedulerReconciliation {
            issue_identifier: run.issue_identifier.clone(),
            retry_count: run.retry_count,
            not_before_tick: run.not_before_tick,
            reason,
        });
    }
    reconciliations
}

fn daemon_run_state_mut<'a>(
    state: &'a mut DaemonProjectState,
    issue_identifier: &str,
) -> &'a mut DaemonRunState {
    let index = state
        .runs
        .iter()
        .position(|run| run.issue_identifier == issue_identifier);
    let index = match index {
        Some(index) => index,
        None => {
            state.runs.push(DaemonRunState {
                issue_identifier: issue_identifier.to_string(),
                run_state: SchedulerRunState::Pending,
                retry_count: 0,
                not_before_tick: 0,
                last_error: None,
            });
            state.runs.len() - 1
        }
    };
    &mut state.runs[index]
}

pub fn is_dispatch_eligible(item: &SchedulerItem, config: &WorkflowConfig, tick: u64) -> bool {
    if tick < item.not_before_tick {
        return false;
    }
    let issue_state = item.issue_state.to_lowercase();
    if !config.active_states.contains(&issue_state) || config.terminal_states.contains(&issue_state)
    {
        return false;
    }
    match item.run_state {
        SchedulerRunState::Pending => true,
        SchedulerRunState::Failed => item.retry_count < config.max_retries,
        SchedulerRunState::Running
        | SchedulerRunState::Completed
        | SchedulerRunState::Blocked
        | SchedulerRunState::Canceled => false,
    }
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
    use std::os::unix::fs::PermissionsExt;

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
        assert_eq!(config.active_states, vec!["open"]);
        assert_eq!(config.terminal_states, vec!["closed"]);
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
    fn parses_body_only_workflow_with_bom() {
        let workflow = parse_workflow("\u{feff}Handle {{ issue.identifier }}").unwrap();

        assert!(workflow.config.is_empty());
        assert_eq!(workflow.prompt_template, "Handle {{ issue.identifier }}");
    }

    #[test]
    fn resolves_explicit_policy_values_and_trims_branch_prefix() {
        let workflow = parse_workflow(
            r#"---
tracker:
  kind: github
  active_states: [" OPEN ", "Ready"]
  terminal_states: [" CLOSED "]
polling:
  interval_ms: 125
workspace:
  root: ".auditorium/custom"
agent:
  max_concurrent_agents: 5
  max_turns: 3
  max_retry_backoff_ms: 9000
codex:
  command: "/usr/local/bin/codex exec"
branch_prefix: "/tickets/"
max_retries: 4
run_tests: false
open_pull_request: false
validation:
  command: "swift test"
---
Body
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/project/WORKFLOW.md")).unwrap();

        assert_eq!(config.active_states, vec!["open", "ready"]);
        assert_eq!(config.terminal_states, vec!["closed"]);
        assert_eq!(config.polling_interval_ms, 125);
        assert_eq!(
            config.workspace_root,
            PathBuf::from("/tmp/project/.auditorium/custom")
        );
        assert_eq!(config.max_concurrent_agents, 5);
        assert_eq!(config.max_turns, 3);
        assert_eq!(config.max_retry_backoff_ms, 9000);
        assert_eq!(config.codex_command, "/usr/local/bin/codex exec");
        assert_eq!(config.branch_prefix, "tickets");
        assert_eq!(config.max_retries, 4);
        assert!(!config.run_tests);
        assert!(!config.open_pull_request);
        assert_eq!(config.validation_command.as_deref(), Some("swift test"));
    }

    #[test]
    fn rejects_invalid_policy_value_types() {
        let workflow = parse_workflow(
            r#"---
tracker:
  active_states: "open"
polling:
  interval_ms: -1
run_tests: "yes"
---
Body
"#,
        )
        .unwrap();
        let error = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap_err();

        assert_eq!(error.code(), "invalid_config");
        assert!(error
            .to_string()
            .contains("tracker.active_states must be a string array"));
    }

    #[test]
    fn rejects_negative_numeric_policy_values() {
        let workflow = parse_workflow(
            r#"---
polling:
  interval_ms: -1
---
Body
"#,
        )
        .unwrap();
        let error = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap_err();

        assert_eq!(error.code(), "invalid_config");
        assert!(error
            .to_string()
            .contains("polling.interval_ms must be a non-negative integer"));
    }

    #[test]
    fn rejects_empty_policy_values_that_would_break_dispatch() {
        let workflow = parse_workflow(
            r#"---
tracker:
  active_states: []
branch_prefix: "/"
---
Body
"#,
        )
        .unwrap();
        let error = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap_err();

        assert_eq!(error.code(), "invalid_config");
        assert!(error
            .to_string()
            .contains("tracker.active_states must include at least one state"));
    }

    #[test]
    fn rejects_empty_branch_prefix_after_trimming_slashes() {
        let workflow = parse_workflow(
            r#"---
branch_prefix: "/"
---
Body
"#,
        )
        .unwrap();
        let error = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap_err();

        assert_eq!(error.code(), "invalid_config");
        assert!(error
            .to_string()
            .contains("branch_prefix must not be empty"));
    }

    #[test]
    fn command_line_preserves_quoted_arguments() {
        let parts = split_command_line(
            r#"codex exec --json --sandbox "workspace write" -c approval_policy=\"never\""#,
        )
        .unwrap();

        assert_eq!(
            parts,
            vec![
                "codex",
                "exec",
                "--json",
                "--sandbox",
                "workspace write",
                "-c",
                r#"approval_policy="never""#
            ]
        );
    }

    #[test]
    fn command_line_supports_single_quotes_and_escaped_spaces() {
        let parts = split_command_line(
            r#"/Applications/Codex\ CLI.app/Contents/MacOS/codex exec --prompt 'fix login flow'"#,
        )
        .unwrap();

        assert_eq!(
            parts,
            vec![
                "/Applications/Codex CLI.app/Contents/MacOS/codex",
                "exec",
                "--prompt",
                "fix login flow"
            ]
        );
    }

    #[test]
    fn command_line_rejects_unmatched_quotes_and_dangling_escape() {
        let quote_error = split_command_line(r#"codex exec "unterminated"#).unwrap_err();
        let escape_error = split_command_line(r#"codex exec \"#).unwrap_err();

        assert_eq!(quote_error.code(), "invalid_config");
        assert!(quote_error.to_string().contains("unmatched"));
        assert_eq!(escape_error.code(), "invalid_config");
        assert!(escape_error.to_string().contains("unfinished escape"));
    }

    #[tokio::test]
    async fn codex_runner_passes_quoted_command_arguments_verbatim() {
        let tempdir = tempfile::tempdir().unwrap();
        let script = tempdir.path().join("fake-codex");
        let args_path = tempdir.path().join("codex-args.txt");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n",
                args_path.display()
            ),
        )
        .unwrap();
        let mut permissions = std::fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&script, permissions).unwrap();
        let workflow = parse_workflow("Body").unwrap();
        let mut config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();
        config.codex_command = format!(
            "{} --mode \"two words\" -c approval_policy=\\\"never\\\"",
            script.display()
        );

        run_codex(&config, tempdir.path(), "Prompt body", true)
            .await
            .unwrap();

        let args = std::fs::read_to_string(args_path).unwrap();
        assert_eq!(
            args.lines().collect::<Vec<_>>(),
            vec![
                "--mode",
                "two words",
                "-c",
                r#"approval_policy="never""#,
                "Prompt body"
            ]
        );
    }

    #[test]
    fn parses_tracker_state_filters_for_dispatch() {
        let workflow = parse_workflow(
            r#"---
tracker:
  kind: github
  active_states: ["open", "ready"]
  terminal_states: ["closed", "merged"]
---
Body
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();

        assert_eq!(config.active_states, vec!["open", "ready"]);
        assert_eq!(config.terminal_states, vec!["closed", "merged"]);
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
    fn dispatch_batch_enforces_bounded_concurrency_and_queue_order() {
        let workflow = parse_workflow(
            r#"---
agent:
  max_concurrent_agents: 3
---
Body
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();
        let items = vec![
            scheduler_item("#1", "open", SchedulerRunState::Pending, 0, 0),
            scheduler_item("#2", "open", SchedulerRunState::Pending, 0, 0),
            scheduler_item("#3", "open", SchedulerRunState::Pending, 0, 0),
            scheduler_item("#4", "open", SchedulerRunState::Pending, 0, 0),
        ];

        let selected = dispatch_batch(&items, &config, 1, 10);

        assert_eq!(
            selected
                .iter()
                .map(|item| item.issue_identifier.as_str())
                .collect::<Vec<_>>(),
            vec!["#1", "#2"]
        );
    }

    #[test]
    fn dispatch_batch_returns_empty_when_capacity_is_saturated() {
        let workflow = parse_workflow(
            r#"---
agent:
  max_concurrent_agents: 2
---
Body
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();
        let items = vec![
            scheduler_item("#1", "open", SchedulerRunState::Pending, 0, 0),
            scheduler_item("#2", "open", SchedulerRunState::Pending, 0, 0),
        ];

        let selected = dispatch_batch(&items, &config, 2, 1);

        assert!(selected.is_empty());
    }

    #[test]
    fn dispatch_eligibility_skips_terminal_blocked_canceled_and_running_items() {
        let workflow = parse_workflow(
            r#"---
tracker:
  kind: github
  active_states: ["open", "ready"]
  terminal_states: ["closed"]
agent:
  max_concurrent_agents: 10
---
Body
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();
        let items = vec![
            scheduler_item("#1", "open", SchedulerRunState::Pending, 0, 0),
            scheduler_item("#2", "closed", SchedulerRunState::Pending, 0, 0),
            scheduler_item("#3", "ready", SchedulerRunState::Running, 0, 0),
            scheduler_item("#4", "open", SchedulerRunState::Blocked, 0, 0),
            scheduler_item("#5", "open", SchedulerRunState::Canceled, 0, 0),
            scheduler_item("#6", "ready", SchedulerRunState::Completed, 0, 0),
        ];

        let selected = dispatch_batch(&items, &config, 0, 1);

        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].issue_identifier, "#1");
    }

    #[test]
    fn failed_items_retry_only_within_policy_after_backoff_tick() {
        let workflow = parse_workflow(
            r#"---
polling:
  interval_ms: 1000
agent:
  max_concurrent_agents: 10
  max_retry_backoff_ms: 5000
max_retries: 2
---
Body
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();
        let items = vec![
            scheduler_item("#1", "open", SchedulerRunState::Failed, 1, 5),
            scheduler_item("#2", "open", SchedulerRunState::Failed, 2, 0),
            scheduler_item("#3", "open", SchedulerRunState::Failed, 1, 10),
        ];

        let selected = dispatch_batch(&items, &config, 0, 5);

        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].issue_identifier, "#1");
    }

    #[test]
    fn retry_backoff_uses_exponential_delay_capped_by_workflow() {
        let workflow = parse_workflow(
            r#"---
polling:
  interval_ms: 1000
agent:
  max_retry_backoff_ms: 2500
---
Body
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();

        assert_eq!(retry_backoff_ms(&config, 0), 0);
        assert_eq!(retry_backoff_ms(&config, 1), 1000);
        assert_eq!(retry_backoff_ms(&config, 2), 2000);
        assert_eq!(retry_backoff_ms(&config, 3), 2500);
        assert_eq!(retry_backoff_ms(&config, 10), 2500);
    }

    #[test]
    fn scheduler_plan_counts_dispatches_and_skip_reasons() {
        let workflow = parse_workflow(
            r#"---
tracker:
  kind: github
  active_states: ["open"]
  terminal_states: ["closed"]
agent:
  max_concurrent_agents: 3
max_retries: 2
---
Body
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();
        let issues = vec![
            normalized_issue(1, "open"),
            normalized_issue(2, "open"),
            normalized_issue(3, "open"),
            normalized_issue(4, "open"),
            normalized_issue(5, "closed"),
        ];
        let run_states = vec![
            DaemonRunState {
                issue_identifier: "#2".to_string(),
                run_state: SchedulerRunState::Running,
                retry_count: 0,
                not_before_tick: 0,
                last_error: None,
            },
            DaemonRunState {
                issue_identifier: "#3".to_string(),
                run_state: SchedulerRunState::Failed,
                retry_count: 1,
                not_before_tick: 4,
                last_error: Some("transient failure".to_string()),
            },
            DaemonRunState {
                issue_identifier: "#4".to_string(),
                run_state: SchedulerRunState::Blocked,
                retry_count: 0,
                not_before_tick: 0,
                last_error: None,
            },
        ];

        let plan = plan_scheduler_tick("project-1", 4, &issues, &run_states, &config);

        assert_eq!(plan.project, "project-1");
        assert_eq!(plan.polled_issue_count, 5);
        assert_eq!(plan.running_count, 1);
        assert_eq!(plan.capacity, 2);
        assert_eq!(plan.eligible_count, 2);
        assert_eq!(plan.retry_ready_count, 1);
        assert_eq!(plan.skipped_terminal_count, 1);
        assert_eq!(plan.skipped_running_count, 1);
        assert_eq!(plan.skipped_blocked_count, 1);
        assert_eq!(
            plan.dispatches
                .iter()
                .map(|dispatch| (dispatch.issue_identifier.as_str(), dispatch.retry_count))
                .collect::<Vec<_>>(),
            vec![("#1", 0), ("#3", 1)]
        );
    }

    #[test]
    fn dispatch_reconciliation_records_success_failure_and_retry_backoff() {
        let workflow = parse_workflow(
            r#"---
polling:
  interval_ms: 1000
agent:
  max_retry_backoff_ms: 5000
max_retries: 2
---
Body
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();
        let mut state = DaemonProjectState {
            project: "project-1".to_string(),
            repository: Some("acme/app".to_string()),
            issue_query: None,
            execute_dispatches: true,
            mock: true,
            dry_run: false,
            no_pr: false,
            runs: Vec::new(),
        };
        let succeeded = SchedulerDispatch {
            issue_identifier: "#1".to_string(),
            issue_number: 1,
            repo: "acme/app".to_string(),
            retry_count: 0,
        };
        let failed = SchedulerDispatch {
            issue_identifier: "#2".to_string(),
            issue_number: 2,
            repo: "acme/app".to_string(),
            retry_count: 0,
        };

        record_dispatch_started(&mut state, &succeeded, &config, 7);
        record_dispatch_result(
            &mut state,
            &succeeded,
            SchedulerDispatchOutcome::Succeeded,
            &config,
            7,
            None,
        );
        record_dispatch_started(&mut state, &failed, &config, 7);
        record_dispatch_result(
            &mut state,
            &failed,
            SchedulerDispatchOutcome::Failed,
            &config,
            7,
            Some("codex exited 1".to_string()),
        );

        let succeeded_run = state
            .runs
            .iter()
            .find(|run| run.issue_identifier == "#1")
            .unwrap();
        let failed_run = state
            .runs
            .iter()
            .find(|run| run.issue_identifier == "#2")
            .unwrap();

        assert_eq!(succeeded_run.run_state, SchedulerRunState::Completed);
        assert_eq!(succeeded_run.retry_count, 0);
        assert_eq!(succeeded_run.not_before_tick, 0);
        assert_eq!(succeeded_run.last_error, None);
        assert_eq!(failed_run.run_state, SchedulerRunState::Failed);
        assert_eq!(failed_run.retry_count, 1);
        assert_eq!(failed_run.not_before_tick, 8);
        assert_eq!(failed_run.last_error.as_deref(), Some("codex exited 1"));
    }

    #[test]
    fn stale_running_reconciliation_fails_expired_runs_only() {
        let workflow = parse_workflow(
            r#"---
polling:
  interval_ms: 1000
agent:
  max_retry_backoff_ms: 5000
max_retries: 2
---
Body
"#,
        )
        .unwrap();
        let config = resolve_config(&workflow, Path::new("/tmp/WORKFLOW.md")).unwrap();
        let mut state = DaemonProjectState {
            project: "project-1".to_string(),
            repository: Some("acme/app".to_string()),
            issue_query: None,
            execute_dispatches: true,
            mock: true,
            dry_run: false,
            no_pr: false,
            runs: vec![
                DaemonRunState {
                    issue_identifier: "#1".to_string(),
                    run_state: SchedulerRunState::Running,
                    retry_count: 0,
                    not_before_tick: 10,
                    last_error: None,
                },
                DaemonRunState {
                    issue_identifier: "#2".to_string(),
                    run_state: SchedulerRunState::Running,
                    retry_count: 1,
                    not_before_tick: 12,
                    last_error: None,
                },
                DaemonRunState {
                    issue_identifier: "#3".to_string(),
                    run_state: SchedulerRunState::Running,
                    retry_count: 0,
                    not_before_tick: 0,
                    last_error: None,
                },
            ],
        };

        let first = reconcile_stale_running_runs(&mut state, &config, 11);

        assert_eq!(first.len(), 1);
        assert_eq!(first[0].issue_identifier, "#1");
        assert_eq!(first[0].retry_count, 1);
        assert_eq!(first[0].not_before_tick, 12);
        assert!(first[0].reason.contains("deadline"));
        assert_eq!(state.runs[0].run_state, SchedulerRunState::Failed);
        assert_eq!(state.runs[0].retry_count, 1);
        assert_eq!(state.runs[0].not_before_tick, 12);
        assert_eq!(state.runs[1].run_state, SchedulerRunState::Running);
        assert_eq!(state.runs[2].run_state, SchedulerRunState::Running);

        let second = reconcile_stale_running_runs(&mut state, &config, 12);

        assert_eq!(second.len(), 1);
        assert_eq!(second[0].issue_identifier, "#2");
        assert_eq!(second[0].retry_count, 2);
        assert_eq!(second[0].not_before_tick, 14);
        assert_eq!(state.runs[1].run_state, SchedulerRunState::Failed);
        assert_eq!(state.runs[2].run_state, SchedulerRunState::Running);
    }

    #[test]
    fn normalizes_github_issue_list_payload() {
        let issues = normalize_github_issues_payload(
            "acme/app",
            r#"[
  {
    "id": "I_1",
    "number": 42,
    "title": "Ship it",
    "body": "Issue body",
    "url": "https://github.com/acme/app/issues/42",
    "labels": [{"name": "Ready"}],
    "assignees": [{"login": "octocat"}],
    "state": "OPEN",
    "createdAt": "2026-06-01T00:00:00Z",
    "updatedAt": "2026-06-02T00:00:00Z"
  }
]"#,
        )
        .unwrap();

        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].identifier, "#42");
        assert_eq!(issues[0].repo, "acme/app");
        assert_eq!(issues[0].state, "open");
        assert_eq!(issues[0].labels, vec!["ready"]);
        assert_eq!(issues[0].assignees, vec!["octocat"]);
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

    #[test]
    fn render_report_markdown_lists_review_artifacts() {
        let issue = NormalizedIssue {
            description: Some("Ship the reviewable report path.".to_string()),
            ..mock_issue("acme/app", 34)
        };
        let started_at = DateTime::parse_from_rfc3339("2026-06-07T01:02:03Z")
            .unwrap()
            .with_timezone(&Utc);
        let ended_at = DateTime::parse_from_rfc3339("2026-06-07T01:04:05Z")
            .unwrap()
            .with_timezone(&Utc);

        let markdown = render_report_markdown(
            "run-34",
            &issue,
            Path::new("/tmp/workspaces/_34"),
            Path::new("/tmp/workspaces/_34/workspace-manifest.json"),
            "auditorium/issue-34-reviewable-report",
            "completed",
            Some("https://github.com/acme/app/pull/34"),
            &["README.md".to_string(), "src/lib.rs".to_string()],
            Some("\nchecks passed\n"),
            started_at,
            ended_at,
        );

        assert!(markdown.contains("Pull Request: https://github.com/acme/app/pull/34"));
        assert!(markdown.contains("- `README.md`\n- `src/lib.rs`"));
        assert!(markdown.contains("```text\nchecks passed\n```"));
        assert!(!markdown.contains("\n\nchecks passed\n\n"));
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

    fn scheduler_item(
        issue_identifier: &str,
        issue_state: &str,
        run_state: SchedulerRunState,
        retry_count: usize,
        not_before_tick: u64,
    ) -> SchedulerItem {
        SchedulerItem {
            issue_identifier: issue_identifier.to_string(),
            issue_state: issue_state.to_string(),
            run_state,
            retry_count,
            not_before_tick,
        }
    }

    fn normalized_issue(number: u64, state: &str) -> NormalizedIssue {
        NormalizedIssue {
            id: format!("I_{number}"),
            identifier: format!("#{number}"),
            repo: "acme/app".to_string(),
            number,
            title: format!("Issue {number}"),
            description: None,
            state: state.to_string(),
            url: Some(format!("https://github.com/acme/app/issues/{number}")),
            labels: Vec::new(),
            assignees: Vec::new(),
            created_at: None,
            updated_at: None,
        }
    }
}
