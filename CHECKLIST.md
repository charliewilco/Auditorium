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

- [~] Documented commands build in the working tree; fresh-clone verification remains.
- [ ] CI proves the documented commands stay valid.

## 1. Domain Model And SwiftData

- [x] Define SwiftData records for projects, repositories, tickets, queue items, runs, ticket runs, PRs, runtime events, reports, and provider accounts.
- [x] Store provider/status enums as raw values for persistence.
- [x] Keep secrets out of SwiftData.
- [x] Store selected navigation state by stable IDs instead of long-lived model references.
- [x] Add `IssueTrackerRecord`.
- [ ] Add explicit schema migration plan.
- [ ] Add migration tests before changing persisted model shape.
- [ ] Add data validation helpers for invalid/corrupt persisted rows.

Acceptance gate:

- [ ] Existing app data survives one intentional schema migration.
- [ ] No persisted record can contain OAuth tokens or PATs.

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
- [~] Distinguish detected, authenticated, authorized, and implemented provider states in UI.

Acceptance gate:

- [ ] Queue/orchestration code depends on protocols or registry lookups, not hard-coded concrete provider types.
- [ ] Adding `LinearIssueTrackerProvider` requires no queue/run/report UI changes.

## 3. GitHub OAuth And Credentials

- [x] Model GitHub OAuth authorization/token endpoints.
- [x] Model OAuth scopes.
- [x] Store secret material through Keychain service.
- [x] Persist only account metadata in SwiftData.
- [~] Allow pasted access token as temporary bootstrap.
- [x] Implement GitHub OAuth device flow or native callback flow.
- [ ] Store and refresh OAuth token metadata safely.
- [x] Validate granted scopes.
- [~] Detect missing or insufficient GitHub credentials before import/run.
- [~] Add Settings UI for connected GitHub account.
- [x] Add clear credentials action.
- [x] Add tests for Keychain-backed account lifecycle.

Acceptance gate:

- [~] A user can connect GitHub without manually pasting a token.
- [x] Repository and issue APIs can share one GitHub account.
- [x] Clearing the account removes Keychain secrets and SwiftData metadata.

## 4. GitHub Source-Code Provider

- [x] List repositories visible to authenticated user.
- [ ] Fetch repository metadata.
- [x] Clone repository into project repository path.
- [x] Update existing clone safely.
- [ ] Create deterministic ticket branch names.
- [ ] Commit agent changes.
- [ ] Push ticket branch.
- [x] Open pull request.
- [ ] Fetch PR/check status.
- [x] Add tests with mocked GitHub API responses.

Acceptance gate:

- [ ] A queued issue can produce a GitHub PR URL from a real repository.
- [ ] Provider never force-pushes or rewrites history without explicit policy.

## 5. GitHub Issues Provider

- [x] List issues for selected repository.
- [ ] Support issue filter/query for v0.
- [ ] Fetch issue details.
- [x] Normalize issue number, node ID, title, body, labels, assignees, URL, timestamps, and state.
- [x] Add issue comments.
- [ ] Optionally add/update labels when workflow policy allows.
- [x] Avoid closing issues automatically in v0.
- [ ] Add pagination handling.
- [ ] Add rate-limit/error handling.
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
- [ ] Select GitHub account.
- [x] Select repository from real GitHub data.
- [ ] Select issue filter/query from real GitHub Issues data.
- [ ] Validate required fields before advancing each step.
- [ ] Add clearer error handling for failed creation.

Acceptance gate:

- [~] A user can create a real GitHub-backed project without mock data.

## 7. Demo Mode

- [x] Seed Burton Demo project.
- [x] Seed realistic demo tickets.
- [x] Make mock runtime work offline.
- [x] Make mock agent work offline.
- [x] Generate mock PR URLs.
- [x] Generate markdown report from mock run.
- [ ] Make demo mode explicit in UI.
- [ ] Ensure demo data never requires network access.
- [ ] Add reset demo project action.

Acceptance gate:

- [ ] A fresh app launch can complete the full demo flow offline.

## 8. Queue

- [x] Add tickets to queue.
- [x] Persist queue items.
- [x] Reorder queue items.
- [x] Enable/disable queue items.
- [x] Remove queue items.
- [x] Clear queue.
- [x] Add focused unit test for queue ordering.
- [ ] Add drag-and-drop verification.
- [ ] Add multi-select queue actions.
- [ ] Add per-run queue snapshot.
- [x] Prevent duplicate queue items reliably across all entry points.

Acceptance gate:

- [ ] User can select real GitHub issues, queue them, reorder them, and run only enabled items.

## 9. Runtime Detection And Runtime Providers

- [x] Detect Apple silicon.
- [x] Detect macOS version.
- [x] Detect Apple `container` CLI.
- [x] Check `container system version --format json`.
- [x] Check `container system status --format json`.
- [x] Detect Docker CLI and daemon.
- [x] Detect Git.
- [x] Detect Codex CLI.
- [x] Detect GitHub CLI.
- [x] Block unavailable Apple Container before workspace creation.
- [ ] Implement Apple Container runtime execution.
- [ ] Implement Docker runtime execution.
- [ ] Implement Local Workspace runtime execution.
- [ ] Expose runtime provider implementation status separately from detection status.
- [ ] Add "start container service" guidance without auto-starting it.

Acceptance gate:

- [ ] Runtime preflight blocks unsafe runs.
- [ ] At least one non-mock runtime can run a ticket workspace end-to-end.

## 10. Agent Providers

- [x] Add Mock Agent.
- [x] Detect Codex CLI.
- [x] Block Codex-backed run when Codex CLI is missing.
- [ ] Implement `CodexCLIProcessAgentProvider`.
- [ ] Launch Codex through `Process`.
- [ ] Capture stdout.
- [ ] Capture stderr.
- [ ] Persist log file path.
- [ ] Stream agent output into `RuntimeEventRecord`.
- [ ] Support cancellation.
- [ ] Parse final result into ticket-run status.
- [ ] Implement Generic CLI Agent configuration.

Acceptance gate:

- [ ] A real Codex CLI run can process one GitHub issue in a workspace and stream events into the app.

## 11. Orchestration Engine

- [x] Create `RunRecord` for mock runs.
- [x] Create one `TicketRunRecord` per enabled queue item in mock path.
- [x] Persist runtime events.
- [x] Generate report after mock run.
- [x] Block run before records/workspaces when runtime or agent preflight fails.
- [~] Accept concurrency value.
- [ ] Enforce bounded concurrency.
- [ ] Implement retry policy from workflow.
- [~] Implement cancellation state transitions.
- [ ] Implement per-ticket failure recovery.
- [ ] Snapshot queue and workflow policy per run.
- [ ] Reconcile run state on app relaunch.
- [ ] Move real long-running work out of SwiftUI views and into isolated services/actors.

Acceptance gate:

- [ ] Enabled queue items run with bounded concurrency and durable state transitions.
- [ ] Canceled/failed/retried runs produce accurate ticket and run records.

## 12. Workspace Management

- [x] Create deterministic app workspace root.
- [x] Create project directories.
- [x] Create deterministic ticket workspace paths.
- [x] Sanitize ticket IDs.
- [x] Add workspace path tests.
- [ ] Clone/update repository into workspace or project repository area.
- [ ] Decide and document workspace reuse policy.
- [ ] Add cleanup policy for canceled/terminal issues.
- [ ] Add workspace manifest per ticket run.
- [ ] Add Finder reveal for project/repo/workspace paths.

Acceptance gate:

- [ ] A real issue run has a deterministic, inspectable workspace containing the repository at the expected branch.

## 13. Git And Pull Requests

- [x] Create branch per ticket.
- [ ] Apply agent file changes.
- [x] Detect changed files.
- [x] Commit changes with deterministic message.
- [x] Push branch.
- [x] Open GitHub pull request.
- [ ] Store `PullRequestRecord`.
- [ ] Surface PR in run detail and ticket inspector.
- [x] Add PR to markdown report.
- [ ] Never auto-merge in v0.

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
- [ ] Include failure details and suggested actions.
- [ ] Include PR/check status.
- [ ] Add report golden tests.

Acceptance gate:

- [ ] Every completed run produces a useful markdown report suitable for human review.

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
- [ ] Replace mock-only text with real provider states.
- [ ] Improve empty/error states.
- [ ] Add focused keyboard shortcut handling for all required commands.
- [ ] Verify layout on multiple window sizes.
- [ ] Verify no text overlap.
- [ ] Add visual proof/screenshots for acceptance flow.

Acceptance gate:

- [ ] User can complete the v0 real GitHub flow without leaving the app except OAuth/browser approval.

## 16. Ticket Inspector

- [x] Show ticket metadata.
- [x] Show queue state.
- [x] Show latest run state.
- [x] Show workspace/container/branch/PR fields.
- [x] Show timeline events.
- [~] Add queue/run/retry/open/copy actions.
- [ ] Wire all actions to real implementations.
- [ ] Copy markdown status with real event timeline.
- [ ] Open issue tracker URL.
- [ ] Open PR URL.
- [ ] Open workspace in Finder.
- [ ] Cancel active ticket run.

Acceptance gate:

- [ ] Inspector is a reliable single-ticket operations panel during and after a real run.

## 17. Settings And Security

- [x] Show runtime health.
- [~] Show account/provider sections.
- [~] Include security preference toggles.
- [ ] Enforce network access toggle.
- [ ] Enforce filesystem write toggle.
- [ ] Enforce confirmation before starting runs.
- [ ] Enforce confirmation before opening PRs.
- [ ] Show Keychain storage explanation.
- [x] Clear GitHub credentials.
- [ ] Configure runtime isolation level.
- [ ] Configure logs/reports paths.

Acceptance gate:

- [ ] Settings reflect real enforced behavior, not only UI state.

## 18. `WORKFLOW.md`

- [x] Store default workflow policy markdown.
- [x] Use workflow policy in mock prompts.
- [ ] Add workflow editor UI.
- [x] Parse YAML front matter.
- [~] Validate policy values.
- [~] Snapshot policy per run.
- [x] Read repository-owned `WORKFLOW.md`.
- [ ] Support live reload in `symphony` CLI.
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
- [~] Add orchestrator.
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
- [~] `symphony daemon --project PROJECT_ID`
- [x] `symphony report --run RUN_ID`

Acceptance gate:

- [ ] Each command has help text, tests, and documented exit behavior.

## 21. App And CLI Integration

- [x] Decide app-to-CLI invocation boundary.
- [x] Pass project/run context to CLI.
- [x] Stream CLI NDJSON events into SwiftData runtime events.
- [x] Handle CLI cancellation.
- [x] Handle CLI failure exit codes.
- [x] Persist CLI-generated reports.
- [ ] Surface CLI doctor output in Settings/Dashboard.

Acceptance gate:

- [ ] The macOS app can use `symphony` for a real GitHub issue run and update live UI state.

## 22. Testing

- [x] Swift tests for queue ordering.
- [x] Swift tests for project creation.
- [x] Swift tests for invalid draft persistence.
- [x] Swift tests for report generation.
- [x] Swift tests for workspace paths.
- [x] Swift tests for provider normalization.
- [x] Swift tests for runtime detection.
- [x] Swift tests for Apple Container preflight.
- [x] Swift tests for Codex CLI preflight.
- [x] Swift tests for GitHub adapter shape.
- [ ] Swift tests for run creation count.
- [ ] Swift tests for ticket status transitions.
- [ ] Swift tests for retry behavior.
- [x] Swift tests for cancellation.
- [ ] Swift tests for bounded concurrency.
- [x] Rust unit tests.
- [ ] Rust integration tests.
- [ ] UI smoke tests that are not template-only.
- [ ] Manual acceptance checklist with screenshots.

Acceptance gate:

- [ ] Swift and Rust test suites cover the v0 real GitHub flow.

## 23. Build, CI, And Release

- [x] Local macOS Debug build passes.
- [x] Focused Swift unit target passes.
- [x] Full Xcode scheme tests are reliable.
- [x] GitHub Actions macOS build workflow.
- [x] GitHub Actions Rust test workflow.
- [ ] Release build configuration.
- [ ] Signing/entitlements review.
- [ ] App sandbox/security policy decision.
- [ ] Distribution/notarization plan.

Acceptance gate:

- [ ] CI validates app and CLI on every PR.
- [ ] Release build can be signed and launched on a clean Mac.

## 24. v0 Final Acceptance

- [~] User authenticates GitHub.
- [x] User selects GitHub repository.
- [x] User imports GitHub Issues.
- [ ] User queues issues.
- [ ] User reorders queue.
- [ ] User starts run.
- [ ] Runtime preflight passes or blocks with actionable reason.
- [ ] Codex preflight passes or blocks with actionable reason.
- [x] Real Codex run processes one issue.
- [x] Workspace is created deterministically.
- [x] Ticket branch is created.
- [x] Changes are committed.
- [x] Pull request is opened.
- [ ] Live events appear in UI.
- [ ] Ticket inspector reflects current state.
- [x] Markdown report is generated and saved.
- [x] `symphony doctor` works.
- [x] `symphony run` works.
- [x] Swift tests pass.
- [x] Rust tests pass.
- [x] macOS app builds cleanly.

v0 is not complete until every item in this section is checked.
