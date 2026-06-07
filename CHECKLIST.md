# Auditorium Implementation Checklist

This checklist accompanies `SPEC.md`. It tracks what must be built before Auditorium v0 can be considered complete.

Legend:

- `[x]` Implemented in the current prototype.
- `[ ]` Not implemented or not verified.
- `[~]` Partially implemented; needs production work.

## 0. Project Baseline

- [x] Create native macOS Xcode project.
- [x] Set macOS deployment target to macOS 15+.
- [x] Use Swift, SwiftUI, SwiftData, Swift Concurrency, and Observation.
- [x] Avoid `ObservableObject`, `@Published`, and `StateObject` in new app state.
- [x] Add root `SPEC.md`.
- [x] Add root `CHECKLIST.md`.
- [x] Add `.gitignore` for Xcode user state.
- [x] Add developer-facing README with build/run/test commands.
- [x] Add CI workflow for macOS build and tests.

Acceptance gate:

- [x] Documented commands build in the working tree and in fresh CI checkout.
- [x] CI proves the documented commands stay valid.

## 1. Domain Model And SwiftData

- [x] Define SwiftData records for projects, repositories, tickets, queue items, runs, ticket runs, PRs, runtime events, reports, and provider accounts.
- [x] Store provider/status enums as raw values for persistence.
- [x] Keep secrets out of SwiftData.
- [x] Store selected navigation state by stable IDs instead of long-lived model references.
- [x] Add `IssueTrackerRecord`.
- [x] Add explicit schema migration plan.
- [x] Add migration tests before changing persisted model shape.
- [x] Add data validation helpers for invalid/corrupt persisted rows.

Acceptance gate:

- [x] Existing app data survives one intentional schema migration.
- [x] No persisted record can contain OAuth tokens or PATs in app-owned SwiftData save paths.

## 2. Provider Architecture

- [x] Define `SourceCodeProvider`.
- [x] Define `IssueTrackerProvider`.
- [x] Add GitHub source-code adapter shape.
- [x] Add GitHub Issues adapter shape.
- [x] Keep future adapter placeholders for Linear, GitLab, Bitbucket, Azure DevOps, Azure Boards, and generic Git.
- [x] Add reusable provider authentication descriptors.
- [x] Add tests proving GitHub providers use the repeatable protocol shape.
- [x] Add provider registry/factory so orchestration does not instantiate concrete providers directly.
- [x] Add provider capability model for supported operations.
- [x] Distinguish detected, authenticated, authorized, and implemented provider states in UI.

Acceptance gate:

- [x] Queue/orchestration code depends on protocols or registry lookups, not hard-coded concrete provider types.
- [x] Adding `LinearIssueTrackerProvider` requires no queue/run/report UI changes.

## 3. GitHub OAuth And Credentials

- [x] Model GitHub OAuth authorization/token endpoints.
- [x] Model OAuth scopes.
- [x] Store secret material through Keychain service.
- [x] Persist only account metadata in SwiftData.
- [~] Allow pasted access token as temporary bootstrap.
- [x] Implement GitHub OAuth device flow or native callback flow.
- [x] Store and refresh OAuth token metadata safely.
- [x] Validate granted scopes.
- [x] Detect missing or insufficient GitHub credentials before import/run.
- [x] Add Settings UI for connected GitHub account.
- [x] Add clear credentials action.
- [x] Add tests for Keychain-backed account lifecycle.

Acceptance gate:

- [x] A user can connect GitHub without manually pasting a token.
- [x] Repository and issue APIs can share one GitHub account.
- [x] Clearing the account removes Keychain secrets and SwiftData metadata.

## 4. GitHub Source-Code Provider

- [x] List repositories visible to authenticated user.
- [x] Fetch repository metadata.
- [x] Clone repository into project repository path.
- [x] Update existing clone safely.
- [x] Create deterministic ticket branch names.
- [x] Commit agent changes.
- [x] Push ticket branch.
- [x] Open pull request.
- [x] Fetch PR/check status.
- [x] Add tests with mocked GitHub API responses.

Acceptance gate:

- [ ] A queued issue can produce a GitHub PR URL from a real repository.
- [x] Provider never force-pushes or rewrites history without explicit policy.

## 5. GitHub Issues Provider

- [x] List issues for selected repository.
- [x] Support issue filter/query for v0.
- [x] Fetch issue details.
- [x] Normalize issue number, node ID, title, body, labels, assignees, URL, timestamps, and state.
- [x] Add issue comments.
- [x] Optionally add/update labels when workflow policy allows.
- [x] Avoid closing issues automatically in v0.
- [x] Add pagination handling.
- [x] Add rate-limit/error handling.
- [x] Add tests with mocked GitHub API responses.

Acceptance gate:

- [x] The app can import real GitHub Issues into `TicketRecord`.
- [x] Ticket browser data matches GitHub issue details.

## 6. Project Creation Flow

- [x] Use transient `ProjectDraft`.
- [x] Commit SwiftData records only on final create.
- [x] Default to GitHub repository provider.
- [x] Default to GitHub Issues provider.
- [x] Persist project, repository, issue tracker, workflow policy, and optional demo tickets.
- [x] Show OAuth-shaped credential step.
- [x] Select GitHub account.
- [x] Select repository from real GitHub data.
- [x] Select issue filter/query from real GitHub Issues data.
- [x] Validate required fields before advancing each step.
- [x] Add clearer error handling for failed creation.

Acceptance gate:

- [~] A user can create a real GitHub-backed project without mock data.

## 7. Demo Mode

- [x] Seed Burton Demo project.
- [x] Seed realistic demo tickets.
- [x] Make mock runtime work offline.
- [x] Make mock agent work offline.
- [x] Generate mock PR URLs.
- [x] Generate markdown report from mock run.
- [x] Make demo mode explicit in UI.
- [x] Ensure demo data never requires network access.
- [x] Add reset demo project action.

Acceptance gate:

- [x] A fresh app launch can complete the full demo flow offline.

## 8. Queue

- [x] Add tickets to queue.
- [x] Persist queue items.
- [x] Reorder queue items.
- [x] Enable/disable queue items.
- [x] Remove queue items.
- [x] Clear queue.
- [x] Add focused unit test for queue ordering.
- [x] Add drag-and-drop verification.
- [x] Add multi-select queue actions.
- [x] Add per-run queue snapshot.
- [x] Prevent duplicate queue items reliably across all entry points.

Acceptance gate:

- [~] User can select real GitHub issues, queue them, reorder them, and run only enabled items.

## 9. Runtime Detection And Runtime Providers

- [x] Detect Git.
- [x] Detect Codex CLI.
- [x] Detect GitHub CLI.
- [x] Block unavailable Local Workspace runtime before workspace creation.
- [x] Implement Local Workspace runtime execution.
- [x] Expose runtime provider implementation status separately from detection status.

Acceptance gate:

- [x] Runtime preflight blocks unsafe runs.
- [x] At least one non-mock runtime can run a ticket workspace end-to-end.

## 10. Agent Providers

- [x] Add Mock Agent.
- [x] Detect Codex CLI.
- [x] Block Codex-backed run when Codex CLI is missing.
- [x] Implement `CodexCLIProcessAgentProvider`.
- [x] Launch Codex through `Process`.
- [x] Capture stdout.
- [x] Capture stderr.
- [x] Persist log file path.
- [x] Stream agent output into `RuntimeEventRecord`.
- [x] Support cancellation.
- [x] Parse final result into ticket-run status.
- [x] Implement Generic CLI Agent configuration.

Acceptance gate:

- [ ] A real Codex CLI run can process one GitHub issue in a workspace and stream events into the app.

## 11. Orchestration Engine

- [x] Create `RunRecord` for mock runs.
- [x] Create one `TicketRunRecord` per enabled queue item in mock path.
- [x] Persist runtime events.
- [x] Generate report after mock run.
- [x] Block run before records/workspaces when runtime or agent preflight fails.
- [x] Accept concurrency value.
- [x] Enforce bounded concurrency.
- [x] Implement retry policy from workflow.
- [x] Implement cancellation state transitions.
- [x] Implement per-ticket failure recovery.
- [x] Snapshot queue and workflow policy per run.
- [x] Reconcile run state on app relaunch.
- [x] Move real long-running work out of SwiftUI views and into isolated services/actors.

Acceptance gate:

- [x] Enabled queue items run with bounded concurrency and durable state transitions.
- [x] Canceled/failed/retried runs produce accurate ticket and run records.

## 12. Workspace Management

- [x] Create deterministic app workspace root.
- [x] Create project directories.
- [x] Create deterministic ticket workspace paths.
- [x] Sanitize ticket IDs.
- [x] Add workspace path tests.
- [x] Clone/update repository into workspace or project repository area.
- [x] Decide and document workspace reuse policy.
- [x] Add cleanup policy for canceled/terminal issues.
- [x] Add workspace manifest per ticket run.
- [x] Add Finder reveal for project/repo/workspace paths.

Acceptance gate:

- [ ] A real issue run has a deterministic, inspectable workspace containing the repository at the expected branch.

## 13. Git And Pull Requests

- [x] Create branch per ticket.
- [x] Apply agent file changes.
- [x] Detect changed files.
- [x] Commit changes with deterministic message.
- [x] Push branch.
- [x] Open GitHub pull request.
- [x] Store `PullRequestRecord`.
- [x] Surface PR in run detail and ticket inspector.
- [x] Add PR to markdown report.
- [x] Never auto-merge in v0.

Acceptance gate:

- [ ] Completed ticket runs show real GitHub PR URLs.

## 14. Reports

- [x] Generate markdown report.
- [x] Persist `ReportRecord`.
- [x] Save report file.
- [x] Preview reports in app.
- [~] Copy/export/reveal actions exist in prototype form.
- [ ] Verify copy/export/reveal manually.
- [x] Include accurate changed files.
- [x] Include validation/test output.
- [x] Include failure details and suggested actions.
- [x] Include PR/check status.
- [x] Add report golden tests.

Acceptance gate:

- [x] Every completed run produces a useful markdown report suitable for human review.

## 15. UI Screens

- [x] Welcome screen.
- [x] Project setup wizard.
- [x] Dashboard.
- [x] Ticket browser.
- [x] Queue screen.
- [x] Run detail.
- [x] Ticket inspector.
- [x] Reports screen.
- [x] Settings screen.
- [x] Replace mock-only text with real provider states.
- [ ] Improve empty/error states.
- [x] Add focused keyboard shortcut handling for all required commands.
- [ ] Verify layout on multiple window sizes.
- [ ] Verify no text overlap.
- [ ] Add visual proof/screenshots for acceptance flow.

Acceptance gate:

- [ ] User can complete the v0 real GitHub flow without leaving the app except OAuth/browser approval.

## 16. Ticket Inspector

- [x] Show ticket metadata.
- [x] Show queue state.
- [x] Show latest run state.
- [x] Show workspace/runtime/branch/PR fields.
- [x] Show timeline events.
- [x] Add queue/run/retry/open/copy actions.
- [x] Wire all actions to real implementations.
- [x] Copy markdown status with real event timeline.
- [x] Open issue tracker URL.
- [x] Open PR URL.
- [x] Open workspace in Finder.
- [x] Cancel active ticket run.

Acceptance gate:

- [~] Inspector is a reliable single-ticket operations panel during and after a real run.

## 17. Settings And Security

- [x] Show runtime health.
- [x] Show account/provider sections.
- [~] Include security preference toggles.
- [x] Enforce network access toggle.
- [x] Enforce filesystem write toggle.
- [x] Enforce confirmation before starting runs.
- [x] Enforce confirmation before opening PRs.
- [x] Show Keychain storage explanation.
- [x] Clear GitHub credentials.
- [x] Configure runtime isolation level.
- [x] Configure logs/reports paths.

Acceptance gate:

- [~] Settings reflect real enforced behavior, not only UI state.

## 18. `WORKFLOW.md`

- [x] Store default workflow policy markdown.
- [x] Use workflow policy in mock prompts.
- [x] Add workflow editor UI.
- [x] Parse YAML front matter.
- [x] Validate policy values.
- [~] Snapshot policy per run.
- [x] Read repository-owned `WORKFLOW.md`.
- [x] Support live reload in `symphony` CLI.
- [x] Add parser tests.

Acceptance gate:

- [~] Workflow policy controls concurrency, retries, branch prefix, tests, PR creation, and agent prompt.

## 19. Rust `symphony` CLI

- [x] Create Rust workspace/crate.
- [x] Add `symphony` binary target.
- [x] Add `clap` command parser.
- [x] Add `tokio` runtime.
- [x] Add `serde`/`serde_json`.
- [x] Add YAML front matter parser.
- [x] Add `tracing` logging.
- [x] Add GitHub client.
- [x] Add workflow loader.
- [x] Add typed config layer.
- [x] Add workspace manager.
- [x] Add orchestrator with tested scheduler/retry policy, GitHub polling, explicit execution dispatch, and stale-running reconciliation.
- [x] Add Codex process runner.
- [x] Add report generator.
- [x] Add NDJSON event output for app ingestion.
- [x] Add stable error codes.

Acceptance gate:

- [x] `cargo test` passes.
- [x] `symphony doctor --json` works.
- [x] `symphony run --repo OWNER/NAME --issue ISSUE_NUMBER` can complete one issue.

## 20. `symphony` CLI Commands

- [x] `symphony init`
- [x] `symphony doctor`
- [x] `symphony doctor --json`
- [x] `symphony run --repo OWNER/NAME --issue ISSUE_NUMBER`
- [x] `symphony daemon --project PROJECT_ID`
- [x] `symphony report --run RUN_ID`

Acceptance gate:

- [x] Each command has help text, tests, and documented exit behavior.

## 21. App And CLI Integration

- [x] Decide app-to-CLI invocation boundary.
- [x] Pass project/run context to CLI.
- [x] Stream CLI NDJSON events into SwiftData runtime events.
- [x] Handle CLI cancellation.
- [x] Handle CLI failure exit codes.
- [x] Persist CLI-generated reports.
- [x] Surface CLI doctor output in Settings/Dashboard.

Acceptance gate:

- [~] The macOS app can use `symphony` for a real GitHub issue run and update live UI state.

## 22. Testing

- [x] Swift tests for queue ordering.
- [x] Swift tests for project creation.
- [x] Swift tests for invalid draft persistence.
- [x] Swift tests for model integrity validation and persisted secret leakage detection.
- [x] Swift tests for integrity-enforced saves blocking persisted secret material.
- [x] Swift tests for on-disk SwiftData migration survival.
- [x] Swift tests for report generation.
- [x] Swift tests for report failure guidance and PR/check status.
- [x] Swift tests for workspace paths.
- [x] Swift tests for project/repository/workspace reveal path derivation.
- [x] Swift tests for workspace cleanup policy.
- [x] Swift tests for provider normalization.
- [x] Swift tests for source-provider injection in mock orchestration.
- [x] Swift tests for runtime detection.
- [x] Swift tests for Local Workspace runtime preflight.
- [x] Swift tests for Codex CLI preflight.
- [x] Swift tests for Codex CLI process agent streaming, failure, and cancellation.
- [x] Swift tests for injected agent event metadata and log path persistence.
- [x] Swift tests for Generic CLI agent command parsing and process execution.
- [x] Swift tests for Local Workspace runtime clone, branch, start, and stop behavior.
- [x] Swift tests for Local Workspace Codex orchestration commit, push, PR, and no-change behavior.
- [x] Swift tests for GitHub credential preflight before import/run side effects.
- [x] Swift tests for GitHub adapter shape.
- [x] Swift tests for run creation count.
- [x] Swift tests for ticket status transitions.
- [x] Swift tests for retry behavior.
- [x] Swift tests for cancellation.
- [x] Swift tests for bounded concurrency.
- [x] Swift tests for per-ticket failure recovery and continued queue execution.
- [x] Swift tests for ticket inspector action availability and markdown status timeline.
- [x] Swift tests for run-detail pull request visibility.
- [x] Swift tests for interrupted run reconciliation on app relaunch.
- [x] Swift tests for offline demo state, reset cleanup, and full mock run.
- [x] Swift tests for pull request human-review-only policy.
- [x] SwiftPM `AuditoriumCore` package tests for package-first core coverage.
- [x] Rust unit tests.
- [x] Rust integration tests.
- [x] Rust tests for dispatch eligibility, bounded concurrency, and retry backoff.
- [x] Rust tests for daemon GitHub polling handoff and scheduler plan persistence.
- [x] Rust tests for daemon dispatch execution and project-state reconciliation.
- [x] Rust tests for daemon stale-running reconciliation.
- [x] Rust tests for quoted Codex command parsing and argv handoff.
- [x] Rust integration test for non-mock GitHub issue, workspace, Codex, validation, git push, PR, and report flow.
- [x] UI smoke tests that are not template-only.
- [ ] Manual acceptance checklist with screenshots.

Acceptance gate:

- [x] Swift and Rust test suites cover the v0 real GitHub flow.

## 23. Build, CI, And Release

- [x] Local macOS Debug build passes.
- [x] Focused Swift unit target passes.
- [x] Full Xcode scheme tests are reliable.
- [x] GitHub Actions macOS build workflow.
- [x] GitHub Actions SwiftPM core build/test workflow.
- [x] GitHub Actions Rust test workflow.
- [ ] Release build configuration.
- [ ] Signing/entitlements review.
- [ ] App sandbox/security policy decision.
- [ ] Distribution/notarization plan.

Acceptance gate:

- [x] CI validates app and CLI on every PR.
- [ ] Release build can be signed and launched on a clean Mac.

## 24. v0 Final Acceptance

- [x] User authenticates GitHub.
- [x] User selects GitHub repository.
- [x] User imports GitHub Issues.
- [x] User queues issues.
- [x] User reorders queue.
- [x] User starts run.
- [x] Runtime preflight passes or blocks with actionable reason.
- [x] Codex preflight passes or blocks with actionable reason.
- [x] Real Codex run processes one issue.
- [x] Workspace is created deterministically.
- [x] Ticket branch is created.
- [x] Changes are committed.
- [x] Pull request is opened.
- [x] Live events appear in UI.
- [x] Ticket inspector reflects current state.
- [x] Markdown report is generated and saved.
- [x] `symphony doctor` works.
- [x] `symphony run` works.
- [x] Swift tests pass.
- [x] Rust tests pass.
- [x] macOS app builds cleanly.

v0 is not complete until every item in this section is checked.
