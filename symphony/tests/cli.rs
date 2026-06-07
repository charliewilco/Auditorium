use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use assert_cmd::prelude::*;
use predicates::prelude::*;
use serde_json::Value;
use std::process::Command;

fn symphony() -> Command {
    Command::cargo_bin("symphony").expect("symphony binary should build for integration tests")
}

fn write_executable(path: &Path, body: &str) {
    fs::write(path, body).unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

fn write_fake_toolchain(bin_dir: &Path) {
    fs::create_dir_all(bin_dir).unwrap();
    write_executable(
        &bin_dir.join("git"),
        r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "git version 2.50.0"
  exit 0
fi
exit 0
"#,
    );
    write_executable(
        &bin_dir.join("gh"),
        r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "gh version 2.75.0"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "Logged in to github.com"
  exit 0
fi
echo "unexpected gh invocation: $@" >&2
exit 1
"#,
    );
    write_executable(
        &bin_dir.join("codex"),
        r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "codex 0.1.0"
  exit 0
fi
echo "{}"
exit 0
"#,
    );
}

fn write_fake_daemon_toolchain(bin_dir: &Path) {
    fs::create_dir_all(bin_dir).unwrap();
    write_executable(
        &bin_dir.join("gh"),
        r#"#!/bin/sh
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  cat <<'JSON'
[
  {"id":"I_1","number":1,"title":"First issue","body":null,"url":"https://github.com/acme/app/issues/1","labels":[],"assignees":[],"state":"OPEN","createdAt":null,"updatedAt":null},
  {"id":"I_2","number":2,"title":"Running issue","body":null,"url":"https://github.com/acme/app/issues/2","labels":[],"assignees":[],"state":"OPEN","createdAt":null,"updatedAt":null},
  {"id":"I_3","number":3,"title":"Retry issue","body":null,"url":"https://github.com/acme/app/issues/3","labels":[],"assignees":[],"state":"OPEN","createdAt":null,"updatedAt":null},
  {"id":"I_4","number":4,"title":"Blocked issue","body":null,"url":"https://github.com/acme/app/issues/4","labels":[],"assignees":[],"state":"OPEN","createdAt":null,"updatedAt":null},
  {"id":"I_5","number":5,"title":"Closed issue","body":null,"url":"https://github.com/acme/app/issues/5","labels":[],"assignees":[],"state":"CLOSED","createdAt":null,"updatedAt":null}
]
JSON
  exit 0
fi
echo "unexpected gh invocation: $@" >&2
exit 1
"#,
    );
}

fn write_fake_real_run_toolchain(bin_dir: &Path) {
    fs::create_dir_all(bin_dir).unwrap();
    write_executable(
        &bin_dir.join("gh"),
        r#"#!/bin/sh
set -eu
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  cat <<'JSON'
{
  "id":"I_real_24",
  "number":24,
  "title":"Real GitHub flow",
  "body":"Exercise the non-mock run path.",
  "url":"https://github.com/acme/app/issues/24",
  "labels":[{"name":"Ready"}],
  "assignees":[{"login":"charlie"}],
  "state":"OPEN",
  "createdAt":"2026-06-01T00:00:00Z",
  "updatedAt":"2026-06-02T00:00:00Z"
}
JSON
  exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf '{"defaultBranchRef":{"name":"main"}}\n'
  exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "clone" ]; then
  git clone "$SYMPHONY_TEST_REMOTE_REPO" "$4" >/dev/null 2>&1
  git -C "$4" config user.name "Auditorium Bot"
  git -C "$4" config user.email "auditorium@example.invalid"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  printf '[]\n'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  printf 'https://github.com/acme/app/pull/99\n'
  exit 0
fi
echo "unexpected gh invocation: $@" >&2
exit 1
"#,
    );
    write_executable(
        &bin_dir.join("codex"),
        r#"#!/bin/sh
set -eu
printf '%s\n' "$@" > codex-prompt.txt
printf 'implemented by fake codex\n' > codex-output.txt
printf 'codex wrote codex-output.txt\n'
exit 0
"#,
    );
}

fn write_fake_queue_toolchain(bin_dir: &Path) {
    fs::create_dir_all(bin_dir).unwrap();
    write_executable(
        &bin_dir.join("gh"),
        r#"#!/bin/sh
set -eu
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "id":"I_queue_${issue}",
  "number":${issue},
  "title":"Queue issue ${issue}",
  "body":"Exercise queue bounded concurrency for #${issue}.",
  "url":"https://github.com/acme/app/issues/${issue}",
  "labels":[{"name":"runtime"}],
  "assignees":[],
  "state":"OPEN",
  "createdAt":"2026-06-01T00:00:00Z",
  "updatedAt":"2026-06-02T00:00:00Z"
}
JSON
  exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf '{"defaultBranchRef":{"name":"main"}}\n'
  exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "clone" ]; then
  git clone "$SYMPHONY_TEST_REMOTE_REPO" "$4" >/dev/null 2>&1
  git -C "$4" config user.name "Auditorium Bot"
  git -C "$4" config user.email "auditorium@example.invalid"
  exit 0
fi
echo "unexpected gh invocation: $@" >&2
exit 1
"#,
    );
    write_executable(
        &bin_dir.join("codex-queue"),
        r#"#!/bin/sh
set -eu
lock="$SYMPHONY_TEST_ACTIVE_LOCK"
violation="$SYMPHONY_TEST_OVERLAP_FILE"
if ! mkdir "$lock" 2>/dev/null; then
  printf 'overlap detected\n' >> "$violation"
  exit 77
fi
trap 'rmdir "$lock"' EXIT
printf 'start %s\n' "$(pwd)" >> "$SYMPHONY_TEST_INVOCATIONS"
sleep 0.2
printf 'queue change\n' >> queue-output.txt
printf 'done %s\n' "$(pwd)" >> "$SYMPHONY_TEST_INVOCATIONS"
exit 0
"#,
    );
}

fn path_with_fake_tools(bin_dir: &Path) -> String {
    let existing = std::env::var("PATH").unwrap_or_default();
    format!("{}:{existing}", bin_dir.display())
}

fn workflow_path(tempdir: &tempfile::TempDir) -> PathBuf {
    tempdir.path().join("WORKFLOW.md")
}

fn read_ndjson(stdout: &[u8]) -> Vec<Value> {
    String::from_utf8_lossy(stdout)
        .lines()
        .filter(|line| line.trim_start().starts_with('{'))
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn git(args: &[&str], cwd: &Path) {
    let output = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {:?} failed\nstdout:\n{}\nstderr:\n{}",
        args,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn prepare_bare_remote(tempdir: &tempfile::TempDir) -> PathBuf {
    let seed = tempdir.path().join("seed");
    let remote = tempdir.path().join("remote.git");
    fs::create_dir_all(&seed).unwrap();
    git(&["init", "--initial-branch", "main"], &seed);
    git(&["config", "user.name", "Auditorium Seed"], &seed);
    git(&["config", "user.email", "seed@example.invalid"], &seed);
    fs::write(seed.join("README.md"), "# Fixture\n").unwrap();
    git(&["add", "README.md"], &seed);
    git(&["commit", "-m", "Initial commit"], &seed);
    git(
        &[
            "clone",
            "--bare",
            seed.to_str().unwrap(),
            remote.to_str().unwrap(),
        ],
        tempdir.path(),
    );
    remote
}

#[test]
fn help_lists_every_supported_command() {
    symphony()
        .arg("--help")
        .assert()
        .success()
        .stdout(predicate::str::contains("init"))
        .stdout(predicate::str::contains("doctor"))
        .stdout(predicate::str::contains("run"))
        .stdout(predicate::str::contains("run-queue"))
        .stdout(predicate::str::contains("daemon"))
        .stdout(predicate::str::contains("report"));
}

#[test]
fn init_creates_workflow_and_refuses_to_overwrite() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);

    symphony()
        .args(["init", "--workflow"])
        .arg(&workflow)
        .assert()
        .success()
        .stdout(predicate::str::contains("created"));

    let content = fs::read_to_string(&workflow).unwrap();
    assert!(content.contains("tracker:"));
    assert!(content.contains("{{ issue.identifier }}"));

    symphony()
        .args(["init", "--workflow"])
        .arg(&workflow)
        .assert()
        .code(22)
        .stderr(predicate::str::contains("invalid_config"));
}

#[test]
fn doctor_json_succeeds_with_valid_workflow_and_fake_toolchain() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);
    let bin_dir = tempdir.path().join("bin");
    write_fake_toolchain(&bin_dir);

    symphony()
        .args(["init", "--workflow"])
        .arg(&workflow)
        .assert()
        .success();

    let output = symphony()
        .args(["doctor", "--json", "--workflow"])
        .arg(&workflow)
        .env("PATH", path_with_fake_tools(&bin_dir))
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();

    let payload: Value = serde_json::from_slice(&output).unwrap();
    assert_eq!(payload["ok"], true);
    assert_eq!(payload["workflow"]["ok"], true);
    assert_eq!(payload["workflow"]["trackerKind"], "github");
    assert_eq!(payload["workflow"]["maxConcurrentAgents"], 3);
    assert_eq!(payload["checks"].as_array().unwrap().len(), 4);
}

#[test]
fn doctor_missing_workflow_uses_documented_nonzero_exit() {
    let tempdir = tempfile::tempdir().unwrap();
    let missing_workflow = tempdir.path().join("missing.md");

    symphony()
        .args(["doctor", "--json", "--workflow"])
        .arg(&missing_workflow)
        .assert()
        .code(22)
        .stderr(predicate::str::contains("invalid_config"))
        .stderr(predicate::str::contains("doctor checks failed"));
}

#[test]
fn run_mock_json_writes_workspace_report_and_final_payload() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);
    let workspace_root = tempdir.path().join("workspaces");

    symphony()
        .args(["init", "--workflow"])
        .arg(&workflow)
        .assert()
        .success();

    let output = symphony()
        .args(["run", "--repo", "acme/app", "--issue", "77", "--workflow"])
        .arg(&workflow)
        .args(["--workspace-root"])
        .arg(&workspace_root)
        .args(["--mock", "--json"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();

    let values = read_ndjson(&output);
    assert!(values.iter().any(|value| value["message"] == "run_started"));
    assert!(values
        .iter()
        .any(|value| value["message"] == "mock_report_written"));
    let report = values
        .last()
        .expect("final report payload should be printed");
    assert_eq!(report["repo"], "acme/app");
    assert_eq!(report["status"], "mock_completed");
    assert_eq!(
        report["branch_name"],
        "auditorium/issue-77-mock-auditorium-issue"
    );
    assert!(PathBuf::from(report["report_path"].as_str().unwrap()).exists());
    assert!(PathBuf::from(report["workspace_manifest_path"].as_str().unwrap()).exists());
    assert!(workspace_root.join("_77").is_dir());
}

#[test]
fn run_queue_mock_json_emits_coordination_and_writes_journal() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);
    let workspace_root = tempdir.path().join("workspaces");
    fs::write(
        &workflow,
        format!(
            r#"---
workspace:
  root: "{}"
agent:
  max_concurrent_agents: 1
---
Fix {{{{ issue.identifier }}}}.
"#,
            workspace_root.display()
        ),
    )
    .unwrap();

    let output = symphony()
        .args([
            "run-queue",
            "--repo",
            "acme/app",
            "--issues",
            "1,4",
            "--workflow",
        ])
        .arg(&workflow)
        .args(["--mock", "--json"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let values = read_ndjson(&output);

    assert!(values
        .iter()
        .any(|value| value["message"] == "queue_started"));
    assert!(values.iter().any(|value| value["type"] == "coordination"
        && value["kind"] == "finding"
        && value["sourceIssue"] == 1));
    assert!(values
        .iter()
        .any(|value| value["message"] == "prompt_enriched"
            && value["metadata"]["issue"] == 4
            && value["metadata"]["relatedMessageCount"] == 2));
    assert!(values.iter().any(|value| value["run_id"]
        .as_str()
        .is_some_and(|run_id| run_id.contains("queue-1-4"))
        && value["issue"]["number"] == 1));
    assert!(values.iter().any(|value| value["run_id"]
        .as_str()
        .is_some_and(|run_id| run_id.contains("queue-1-4"))
        && value["issue"]["number"] == 4));

    let journal_path = fs::read_dir(workspace_root.join("coordination"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let journal = fs::read_to_string(journal_path).unwrap();
    assert!(journal.contains("\"type\":\"coordination\""));
    assert!(journal.contains("\"sourceIssue\":1"));

    let prompt = fs::read_to_string(workspace_root.join("_4").join("prompt.md")).unwrap();
    assert!(prompt.contains("## Related work already observed"));
    assert!(prompt.contains("finding from #1"));
    assert!(prompt.contains("changed_files from #1"));
}

#[test]
fn run_queue_real_path_honors_configured_bounded_concurrency() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);
    let workspace_root = tempdir.path().join("workspaces");
    let bin_dir = tempdir.path().join("bin");
    let remote = prepare_bare_remote(&tempdir);
    let active_lock = tempdir.path().join("active-agent");
    let overlap_file = tempdir.path().join("overlap.txt");
    let invocations = tempdir.path().join("invocations.txt");
    write_fake_queue_toolchain(&bin_dir);

    fs::write(
        &workflow,
        format!(
            r#"---
workspace:
  root: "{}"
agent:
  max_concurrent_agents: 1
validation:
  command: ""
codex:
  command: "{}"
branch_prefix: "auditorium"
run_tests: false
open_pull_request: false
---
Fix {{{{ issue.identifier }}}} in {{{{ issue.repo }}}}.
"#,
            workspace_root.display(),
            bin_dir.join("codex-queue").display()
        ),
    )
    .unwrap();

    let output = symphony()
        .args([
            "run-queue",
            "--repo",
            "acme/app",
            "--issues",
            "1,2",
            "--workflow",
        ])
        .arg(&workflow)
        .arg("--json")
        .env("PATH", path_with_fake_tools(&bin_dir))
        .env("SYMPHONY_TEST_REMOTE_REPO", &remote)
        .env("SYMPHONY_TEST_ACTIVE_LOCK", &active_lock)
        .env("SYMPHONY_TEST_OVERLAP_FILE", &overlap_file)
        .env("SYMPHONY_TEST_INVOCATIONS", &invocations)
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let values = read_ndjson(&output);

    assert!(
        !overlap_file.exists(),
        "fake codex detected overlapping agent executions: {}",
        fs::read_to_string(&overlap_file).unwrap_or_default()
    );
    let invocation_log = fs::read_to_string(&invocations).unwrap();
    assert_eq!(invocation_log.matches("start ").count(), 2);
    assert_eq!(invocation_log.matches("done ").count(), 2);
    assert!(values
        .iter()
        .any(|value| value["message"] == "queue_started"
            && value["metadata"]["maxConcurrentAgents"] == 1));
    assert_eq!(
        values
            .iter()
            .filter(|value| value["run_id"]
                .as_str()
                .is_some_and(|run_id| run_id.contains("queue-1-2")))
            .count(),
        2
    );
    assert!(workspace_root
        .join("_1")
        .join("repo")
        .join("queue-output.txt")
        .exists());
    assert!(workspace_root
        .join("_2")
        .join("repo")
        .join("queue-output.txt")
        .exists());
}

#[test]
fn run_non_mock_flow_clones_runs_codex_pushes_pr_and_writes_report() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);
    let workspace_root = tempdir.path().join("workspaces");
    let bin_dir = tempdir.path().join("bin");
    let remote = prepare_bare_remote(&tempdir);
    write_fake_real_run_toolchain(&bin_dir);

    fs::write(
        &workflow,
        format!(
            r#"---
workspace:
  root: "{}"
validation:
  command: "test -f codex-output.txt"
codex:
  command: "{} --json"
branch_prefix: "auditorium"
run_tests: true
open_pull_request: true
---
Fix {{{{ issue.identifier }}}} in {{{{ issue.repo }}}}.

{{{{ issue.title }}}}
{{{{ issue.description }}}}
{{{{ issue.url }}}}
"#,
            workspace_root.display(),
            bin_dir.join("codex").display()
        ),
    )
    .unwrap();

    let output = symphony()
        .args(["run", "--repo", "acme/app", "--issue", "24", "--workflow"])
        .arg(&workflow)
        .arg("--json")
        .env("PATH", path_with_fake_tools(&bin_dir))
        .env("SYMPHONY_TEST_REMOTE_REPO", &remote)
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let values = read_ndjson(&output);
    let final_report = values
        .last()
        .expect("final report payload should be printed");

    assert!(values
        .iter()
        .any(|value| value["message"] == "branch_ready"));
    assert!(values.iter().any(|value| value["message"] == "codex_stdout"
        && value["metadata"]["line"] == "codex wrote codex-output.txt"));
    assert!(values
        .iter()
        .any(|value| value["message"] == "validation_passed"));
    assert!(values
        .iter()
        .any(|value| value["message"] == "branch_pushed"));
    assert!(values
        .iter()
        .any(|value| value["message"] == "pull_request_opened"
            && value["metadata"]["url"] == "https://github.com/acme/app/pull/99"));
    assert_eq!(final_report["status"], "completed");
    assert_eq!(
        final_report["pull_request_url"],
        "https://github.com/acme/app/pull/99"
    );
    assert_eq!(
        final_report["branch_name"],
        "auditorium/issue-24-real-github-flow"
    );
    assert!(final_report["changed_files"]
        .as_array()
        .unwrap()
        .iter()
        .any(|file| file == "codex-output.txt"));

    let branch_ref = "refs/heads/auditorium/issue-24-real-github-flow";
    git(&["rev-parse", "--verify", branch_ref], &remote);

    let workspace = workspace_root.join("_24");
    let repo_path = workspace.join("repo");
    let prompt = fs::read_to_string(repo_path.join("codex-prompt.txt")).unwrap();
    assert!(prompt.contains("Fix #24 in acme/app."));
    assert!(prompt.contains("Real GitHub flow"));
    assert!(prompt.contains("Exercise the non-mock run path."));

    let report_path = PathBuf::from(final_report["report_path"].as_str().unwrap());
    let markdown = fs::read_to_string(report_path).unwrap();
    assert!(markdown.contains("Pull Request: https://github.com/acme/app/pull/99"));
    assert!(markdown.contains("- `codex-output.txt`"));
    assert!(PathBuf::from(final_report["workspace_manifest_path"].as_str().unwrap()).exists());
}

#[test]
fn report_prints_saved_markdown_by_path_and_run_id() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);
    let workspace_root = tempdir.path().join("workspaces");

    symphony()
        .args(["init", "--workflow"])
        .arg(&workflow)
        .assert()
        .success();
    let output = symphony()
        .args(["run", "--repo", "acme/app", "--issue", "78", "--workflow"])
        .arg(&workflow)
        .args(["--workspace-root"])
        .arg(&workspace_root)
        .args(["--mock", "--json"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let values = read_ndjson(&output);
    let report = values.last().unwrap();
    let report_path = report["report_path"].as_str().unwrap();
    let run_id = report["run_id"].as_str().unwrap();

    symphony()
        .args(["report", "--run", report_path])
        .assert()
        .success()
        .stdout(predicate::str::contains("# Auditorium Symphony Run"))
        .stdout(predicate::str::contains("Issue: #78"));

    symphony()
        .args(["report", "--run", run_id, "--workspace-root"])
        .arg(&workspace_root)
        .assert()
        .success()
        .stdout(predicate::str::contains("Status: mock_completed"));
}

#[test]
fn daemon_json_emits_one_scheduling_tick() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);

    symphony()
        .args(["init", "--workflow"])
        .arg(&workflow)
        .assert()
        .success();

    let output = symphony()
        .args(["daemon", "--project", "project-123", "--workflow"])
        .arg(&workflow)
        .arg("--json")
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let values = read_ndjson(&output);

    assert_eq!(values.len(), 1);
    assert_eq!(values[0]["message"], "daemon_tick_completed");
    assert_eq!(values[0]["metadata"]["project"], "project-123");
    assert_eq!(values[0]["metadata"]["tick"], 1);
    assert_eq!(values[0]["metadata"]["workflowRevision"], 1);
}

#[test]
fn daemon_watch_mode_can_run_bounded_ticks() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);

    symphony()
        .args(["init", "--workflow"])
        .arg(&workflow)
        .assert()
        .success();

    let output = symphony()
        .args(["daemon", "--project", "project-123", "--workflow"])
        .arg(&workflow)
        .args([
            "--json",
            "--watch",
            "--max-ticks",
            "2",
            "--poll-interval-ms",
            "1",
        ])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let values = read_ndjson(&output);

    assert_eq!(values.len(), 2);
    assert_eq!(values[0]["message"], "daemon_tick_completed");
    assert_eq!(values[1]["message"], "daemon_tick_completed");
    assert_eq!(values[0]["metadata"]["tick"], 1);
    assert_eq!(values[1]["metadata"]["tick"], 2);
    assert_eq!(values[0]["metadata"]["workflowReloaded"], true);
    assert_eq!(values[1]["metadata"]["workflowReloaded"], false);
}

#[test]
fn daemon_polls_project_state_and_persists_scheduler_plan() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);
    let bin_dir = tempdir.path().join("bin");
    write_fake_daemon_toolchain(&bin_dir);

    symphony()
        .args(["init", "--workflow"])
        .arg(&workflow)
        .assert()
        .success();

    let project_dir = tempdir
        .path()
        .join(".auditorium")
        .join("symphony-workspaces")
        .join("projects")
        .join("project-123");
    fs::create_dir_all(&project_dir).unwrap();
    fs::write(
        project_dir.join("project-state.json"),
        r##"{
  "project": "project-123",
  "repository": "acme/app",
  "issue_query": "label:ready",
  "runs": [
    {"issue_identifier":"#2","run_state":"running","retry_count":0,"not_before_tick":0},
    {"issue_identifier":"#3","run_state":"failed","retry_count":1,"not_before_tick":1},
    {"issue_identifier":"#4","run_state":"blocked","retry_count":0,"not_before_tick":0}
  ]
}"##,
    )
    .unwrap();

    let output = symphony()
        .args(["daemon", "--project", "project-123", "--workflow"])
        .arg(&workflow)
        .arg("--json")
        .env("PATH", path_with_fake_tools(&bin_dir))
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let values = read_ndjson(&output);
    let scheduler = &values[0]["metadata"]["scheduler"];

    assert_eq!(scheduler["polled_issue_count"], 5);
    assert_eq!(scheduler["running_count"], 1);
    assert_eq!(scheduler["capacity"], 2);
    assert_eq!(scheduler["eligible_count"], 2);
    assert_eq!(scheduler["retry_ready_count"], 1);
    assert_eq!(scheduler["skipped_terminal_count"], 1);
    assert_eq!(scheduler["skipped_running_count"], 1);
    assert_eq!(scheduler["skipped_blocked_count"], 1);
    assert_eq!(scheduler["dispatches"][0]["issue_identifier"], "#1");
    assert_eq!(scheduler["dispatches"][1]["issue_identifier"], "#3");
    assert_eq!(scheduler["dispatches"][1]["retry_count"], 1);

    let plan_path = project_dir.join("last-scheduler-plan.json");
    let persisted: Value = serde_json::from_str(&fs::read_to_string(plan_path).unwrap()).unwrap();
    assert_eq!(persisted["project"], "project-123");
    assert_eq!(persisted["dispatches"][0]["issue_number"], 1);
    assert_eq!(persisted["dispatches"][1]["issue_number"], 3);
}

#[test]
fn daemon_execution_mode_runs_mock_dispatches_and_updates_project_state() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);
    let bin_dir = tempdir.path().join("bin");
    write_fake_daemon_toolchain(&bin_dir);

    symphony()
        .args(["init", "--workflow"])
        .arg(&workflow)
        .assert()
        .success();

    let project_dir = tempdir
        .path()
        .join(".auditorium")
        .join("symphony-workspaces")
        .join("projects")
        .join("project-123");
    fs::create_dir_all(&project_dir).unwrap();
    fs::write(
        project_dir.join("project-state.json"),
        r##"{
  "project": "project-123",
  "repository": "acme/app",
  "issue_query": "label:ready",
  "execute_dispatches": true,
  "mock": true,
  "no_pr": true,
  "runs": [
    {"issue_identifier":"#2","run_state":"running","retry_count":0,"not_before_tick":0},
    {"issue_identifier":"#3","run_state":"failed","retry_count":1,"not_before_tick":1},
    {"issue_identifier":"#4","run_state":"blocked","retry_count":0,"not_before_tick":0}
  ]
}"##,
    )
    .unwrap();

    let output = symphony()
        .args(["daemon", "--project", "project-123", "--workflow"])
        .arg(&workflow)
        .arg("--json")
        .env("PATH", path_with_fake_tools(&bin_dir))
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let values = read_ndjson(&output);

    assert!(values
        .iter()
        .any(|value| value["message"] == "daemon_dispatch_started"
            && value["metadata"]["issue"] == "#1"));
    assert!(values
        .iter()
        .any(|value| value["message"] == "daemon_dispatch_completed"
            && value["metadata"]["issue"] == "#3"));

    let state: Value =
        serde_json::from_str(&fs::read_to_string(project_dir.join("project-state.json")).unwrap())
            .unwrap();
    let runs = state["runs"].as_array().unwrap();
    let issue_1 = runs
        .iter()
        .find(|run| run["issue_identifier"] == "#1")
        .unwrap();
    let issue_3 = runs
        .iter()
        .find(|run| run["issue_identifier"] == "#3")
        .unwrap();

    assert_eq!(issue_1["run_state"], "completed");
    assert_eq!(issue_1["retry_count"], 0);
    assert_eq!(issue_3["run_state"], "completed");
    assert_eq!(issue_3["retry_count"], 1);
    assert!(tempdir
        .path()
        .join(".auditorium")
        .join("symphony-workspaces")
        .join("reports")
        .is_dir());
}

#[test]
fn daemon_reconciles_stale_running_state_before_scheduling() {
    let tempdir = tempfile::tempdir().unwrap();
    let workflow = workflow_path(&tempdir);
    let bin_dir = tempdir.path().join("bin");
    write_fake_daemon_toolchain(&bin_dir);

    symphony()
        .args(["init", "--workflow"])
        .arg(&workflow)
        .assert()
        .success();

    let project_dir = tempdir
        .path()
        .join(".auditorium")
        .join("symphony-workspaces")
        .join("projects")
        .join("project-123");
    fs::create_dir_all(&project_dir).unwrap();
    fs::write(
        project_dir.join("project-state.json"),
        r##"{
  "project": "project-123",
  "repository": "acme/app",
  "issue_query": "label:ready",
  "runs": [
    {"issue_identifier":"#2","run_state":"running","retry_count":0,"not_before_tick":1}
  ]
}"##,
    )
    .unwrap();

    let output = symphony()
        .args(["daemon", "--project", "project-123", "--workflow"])
        .arg(&workflow)
        .arg("--json")
        .env("PATH", path_with_fake_tools(&bin_dir))
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let values = read_ndjson(&output);

    assert!(values
        .iter()
        .any(|value| value["message"] == "daemon_run_reconciled"
            && value["metadata"]["issue"] == "#2"
            && value["metadata"]["retryCount"] == 1));

    let state: Value =
        serde_json::from_str(&fs::read_to_string(project_dir.join("project-state.json")).unwrap())
            .unwrap();
    let issue_2 = state["runs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|run| run["issue_identifier"] == "#2")
        .unwrap();

    assert_eq!(issue_2["run_state"], "failed");
    assert_eq!(issue_2["retry_count"], 1);
    assert_eq!(issue_2["not_before_tick"], 2);
    assert!(issue_2["last_error"].as_str().unwrap().contains("deadline"));
}
