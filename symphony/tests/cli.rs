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

#[test]
fn help_lists_every_supported_command() {
    symphony()
        .arg("--help")
        .assert()
        .success()
        .stdout(predicate::str::contains("init"))
        .stdout(predicate::str::contains("doctor"))
        .stdout(predicate::str::contains("run"))
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
