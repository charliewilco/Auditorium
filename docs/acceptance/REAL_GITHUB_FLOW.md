# Real GitHub Flow Evidence

Captured on June 7, 2026.

## Run

- Issue: [#3 Acceptance: add real GitHub flow marker](https://github.com/charliewilco/Auditorium/issues/3)
- Pull request: [#4 #3: Acceptance: add real GitHub flow marker](https://github.com/charliewilco/Auditorium/pull/4)
- Branch: `auditorium-acceptance/issue-3-acceptance--add-real-github-flow-marker`
- Run ID: `20260607103553-3`
- Workspace: `/tmp/auditorium-real-flow-20260607063147/workspaces/_3`
- Workspace manifest: `/tmp/auditorium-real-flow-20260607063147/workspaces/_3/workspace-manifest.json`
- Report: `/tmp/auditorium-real-flow-20260607063147/workspaces/reports/20260607103553-3.md`

## Verified Output

The `symphony` run emitted structured NDJSON events for:

- `run_started`
- `branch_ready`
- `codex_started`
- `codex_completed`
- `validation_passed`
- `pull_request_reconciled`
- `report_written`

The final run summary reported:

```json
{
	"run_id": "20260607103553-3",
	"repo": "charliewilco/Auditorium",
	"workspace_path": "/tmp/auditorium-real-flow-20260607063147/workspaces/_3",
	"workspace_manifest_path": "/tmp/auditorium-real-flow-20260607063147/workspaces/_3/workspace-manifest.json",
	"branch_name": "auditorium-acceptance/issue-3-acceptance--add-real-github-flow-marker",
	"status": "completed",
	"pull_request_url": "https://github.com/charliewilco/Auditorium/pull/4",
	"changed_files": ["docs/acceptance/REAL_GITHUB_FLOW_MARKER.md"],
	"validation_output": "Command passed with no output: test -f docs/acceptance/REAL_GITHUB_FLOW_MARKER.md"
}
```

The workspace repository was on the expected branch and clean after the run:

```text
## auditorium-acceptance/issue-3-acceptance--add-real-github-flow-marker...origin/auditorium-acceptance/issue-3-acceptance--add-real-github-flow-marker
```

The branch diff against `origin/main` contained only the requested marker file:

```text
docs/acceptance/REAL_GITHUB_FLOW_MARKER.md | 1 +
1 file changed, 1 insertion(+)
```

## Still Not Proven By This Evidence

This run proves the headless `symphony` real GitHub issue-to-PR path and deterministic workspace. It does not prove the macOS app UI can complete the full flow, update the inspector live, or verify report copy/export/reveal actions; those remain tracked in `CHECKLIST.md`.
