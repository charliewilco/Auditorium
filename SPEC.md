# Auditorium Specification

Status: Draft v0

Auditorium is a native, local-first macOS app for visual agent orchestration. It turns a repository plus an issue source into a queue of isolated coding-agent runs. The first production slice is GitHub-only: GitHub repositories, GitHub Issues, GitHub OAuth, local SwiftData persistence, Keychain secrets, Codex CLI agent execution, and an Apple Container-aware runtime path.

Auditorium must also ship with a Rust command-line service named `symphony`. The CLI is the headless orchestration engine and must follow the intent and service model of the OpenAI Symphony service specification at `https://github.com/openai/symphony/blob/main/SPEC.md`, adapted to Auditorium's GitHub-first product.

## Goals

- Connect GitHub as the source-code provider.
- Connect GitHub Issues as the issue tracker.
- Let a user create an orchestration project in a native macOS app.
- Import, browse, filter, and queue issues visually.
- Run queued issues through isolated per-ticket workspaces.
- Run a coding agent, initially Codex CLI, per ticket.
- Track live run state, logs, retries, events, PRs, failures, and reports.
- Generate durable markdown run reports.
- Persist local app state with SwiftData.
- Store secrets only in Keychain.
- Provide a Rust `symphony` CLI that can run the same orchestration flow headlessly.
- Keep provider interfaces reusable so future adapters can be added without reshaping the product.

## Non-Goals For v0

- Multi-provider production support beyond GitHub.
- Hosted multi-tenant orchestration.
- Full workflow-engine generality.
- Cloud sync.
- Background scheduling without explicit user opt-in.
- Arbitrary unreviewed network or filesystem access.
- Replacing GitHub's review workflow; successful v0 output is a PR plus report, not an auto-merge.

## Product Shape

Auditorium has two execution surfaces:

1. Native macOS app
	- User-facing control plane.
	- Visual queue, project setup, ticket browser, run detail, reports, settings, and inspector.
	- Owns SwiftData persistence and Keychain integration.
	- Can call into the same orchestration model as the CLI.

2. `symphony` Rust CLI
	- Headless daemon/runner.
	- Reads `WORKFLOW.md`.
	- Polls or runs selected GitHub issues.
	- Manages isolated workspaces.
	- Launches Codex.
	- Emits structured logs/events.
	- Produces markdown reports.
	- Can be driven by the macOS app or used independently in CI/dev environments.

## v0 Scope: GitHub Only

The v0 adapter set is:

```swift
final class GitHubRepositoryProvider: SourceCodeProvider {}
final class GitHubIssueTrackerProvider: IssueTrackerProvider {}
```

GitHub is both:

- Source-code provider: repository list, clone/update, branches, commits, pull requests.
- Issue tracker provider: issue list, issue details, comments, labels, state, assignees.

The app may keep enum-backed persistence names such as `RepositoryProviderKind.github` and `IssueProviderKind.githubIssues`, but runtime integration code must depend on provider protocols, not concrete enum switches.

## Future Sources

After v0, the following adapters should plug into the same provider boundaries:

```swift
final class LinearIssueTrackerProvider: IssueTrackerProvider {}
final class GitLabRepositoryProvider: SourceCodeProvider {}
final class GitLabIssueTrackerProvider: IssueTrackerProvider {}
final class BitbucketRepositoryProvider: SourceCodeProvider {}
final class AzureDevOpsRepositoryProvider: SourceCodeProvider {}
final class AzureBoardsIssueTrackerProvider: IssueTrackerProvider {}
final class GenericGitRepositoryProvider: SourceCodeProvider {}
```

Provider additions must not require changes to queue, run, ticket inspector, report, or orchestrator UI code beyond selection/registration.

## Provider Protocols

The app must expose protocol boundaries equivalent to:

```swift
protocol SourceCodeProvider {
	var kind: RepositoryProviderKind { get }
	var authentication: ProviderAuthenticationDescriptor { get }

	func listRepositories() async throws -> [RepositoryDescriptor]
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor
}

protocol IssueTrackerProvider {
	var kind: IssueProviderKind { get }
	var authentication: ProviderAuthenticationDescriptor { get }

	func listTickets(projectID: String) async throws -> [TicketDescriptor]
	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws
	func addComment(ticketID: String, body: String) async throws
}
```

Providers must normalize external payloads into Auditorium descriptors before they reach orchestration or UI code.

## Authentication

v0 authentication is GitHub OAuth-first.

Required behavior:

- Use GitHub OAuth for GitHub source and GitHub Issues.
- Store access/refresh tokens only in Keychain.
- Store only metadata in SwiftData.
- One GitHub account should satisfy both source-code and issue-tracker access for the same project.
- The app must expose authentication state in Settings.
- The app must support clearing credentials.
- The app must detect missing or insufficient credentials before run dispatch.

Implementation detail:

- v0 may temporarily allow a pasted OAuth access token while callback/device flow is being finished.
- Production v0 should prefer OAuth device flow or a custom URL callback flow suitable for native macOS.
- Requested scopes must be documented and minimal for the required GitHub operations.

## Core Domain Model

Auditorium persists these first-class records:

- Project
- RepositoryRecord
- IssueTrackerRecord
- TicketRecord
- QueueItemRecord
- RunRecord
- TicketRunRecord
- PullRequestRecord
- RuntimeEventRecord
- ReportRecord
- ProviderAccountRecord

Records must use stable UUIDs internally. Provider IDs, ticket numbers, issue numbers, branch names, and URLs are external identifiers and must not be the only primary keys.

## Project

A project represents:

- Source-code provider
- Repository
- Issue tracker
- Runtime provider
- Agent provider
- Workflow policy
- Queue configuration
- Run history

Minimum fields:

- `id`
- `name`
- `repositoryProviderKind`
- `repositoryName`
- `repositoryURL`
- `defaultBranch`
- `issueProviderKind`
- `runtimeProviderKind`
- `agentProviderKind`
- `workflowPolicyMarkdown`
- `createdAt`
- `updatedAt`

v0 defaults:

- Repository provider: GitHub
- Issue provider: GitHub Issues
- Runtime provider: Mock Runtime until Apple Container/local execution is complete
- Agent provider: Mock Agent until Codex process execution is complete

## Ticket

Tickets are normalized issue records.

Minimum fields:

- `id`
- `provider`
- `externalID`
- `title`
- `body`
- `status`
- `labels`
- `assignee`
- `priority`
- `webURL`
- `createdAt`
- `updatedAt`
- `estimatedComplexity`
- `blockedBy`
- `sourceProjectID`

v0 GitHub mapping:

- GitHub issue number or node ID maps to `externalID`.
- GitHub issue title maps to `title`.
- GitHub body maps to `body`.
- GitHub labels map to normalized `labels`.
- GitHub assignees map to `assignee`.
- GitHub issue URL maps to `webURL`.

## Queue

Queue items represent user-approved work.

Required behavior:

- Add selected tickets to queue.
- Reorder queue items.
- Enable or disable items.
- Remove items.
- Run all enabled queue items.
- Run a single selected ticket by creating a one-item queue or a one-off run request.
- Preserve queue order across launches.

The orchestrator must create exactly one `TicketRunRecord` per enabled queue item per run attempt unless dispatch is blocked by preflight.

## Runs

A run is a user-triggered execution session over enabled queue items.

Required statuses:

- pending
- running
- paused
- completed
- completedWithFailures
- canceled
- failed

Run completion must aggregate ticket-run outcomes:

- Completed count
- Failed count
- Blocked count
- PRs created
- Success rate
- Markdown report

## Ticket Runs

A ticket run is one ticket execution attempt.

Required fields:

- `id`
- `runID`
- `ticketID`
- `workspacePath`
- `containerID`
- `branchName`
- `status`
- `startedAt`
- `endedAt`
- `retryCount`
- `logPath`
- `pullRequestURL`
- `summary`
- `failureReason`
- `confidence`

Ticket-run lifecycle:

1. Pending
2. Preparing workspace
3. Starting runtime
4. Starting agent
5. Streaming events
6. Running validation
7. Creating pull request
8. Needs review, blocked, failed, canceled, or completed

## Runtime Events

Every meaningful transition must emit a structured event:

- level: debug, info, warning, error, success
- category: orchestration, provider, git, runtime, agent, tests, pullRequest, report
- message
- timestamp
- optional metadata JSON

Events must power:

- Run timeline
- Ticket inspector timeline
- Report timeline
- CLI logs

## Swift Stack

Required stack:

- Swift
- SwiftUI
- SwiftData
- Swift Concurrency
- Observation framework with `@Observable`
- AppKit only for macOS-specific operations
- macOS 15+ deployment target
- Apple Container features gated behind macOS 26+ and Apple silicon checks

Forbidden patterns:

- No `ObservableObject` for new app state.
- No `@Published`.
- No `StateObject`.
- No secret material in SwiftData.
- No orchestration logic inside SwiftUI views.

Preferred patterns:

- `@Observable` for app/session coordinators.
- `@State` for view-owned local state.
- `@Environment` for app services and SwiftData context.
- Stable IDs in navigation state.
- Dependency injection for services.
- Small SwiftUI views with one primary view per file where practical.

## SwiftData Persistence

SwiftData owns durable local app state.

Rules:

- Keep SwiftData models focused on durable records.
- Store enum raw values for migration-friendly persistence.
- Use computed enum accessors around raw strings.
- Do not store long-lived live model instances in global app state.
- Store selected IDs rather than selected model references.
- Use the main actor for MVP persistence coordination.
- Add migrations before changing persisted schema in incompatible ways.

SwiftData must persist:

- Projects
- Repositories
- Issue trackers
- Tickets
- Queue items
- Runs
- Ticket runs
- Pull requests
- Runtime events
- Reports
- Provider account metadata

SwiftData must not persist:

- OAuth access tokens
- OAuth refresh tokens
- PATs
- Agent credentials
- Raw private key material

## Keychain

Keychain stores secrets.

Required behavior:

- Store GitHub OAuth tokens by provider account.
- Retrieve tokens only inside provider/auth services.
- Delete tokens when account metadata is removed.
- Never include tokens in logs, reports, events, screenshots, or SwiftData.

## SwiftUI UI Requirements

The app must use `NavigationSplitView` with:

- Sidebar
- Main detail
- Right ticket/run inspector

Required screens:

- Welcome
- Project setup wizard
- Dashboard
- Ticket browser
- Queue
- Run detail
- Ticket inspector
- Reports
- Settings

UI principles:

- Native macOS density and controls.
- Tables/lists where data is tabular.
- Cards only for compact repeated summaries or status groups.
- Clear empty states.
- Clear error states.
- SF Symbols.
- Keyboard shortcuts for core actions.
- No marketing landing page after setup; the product surface is the queue/dashboard.

## Project Creation Flow

v0 creation flow:

1. Choose GitHub as source-code provider.
2. Authenticate with GitHub OAuth.
3. Select GitHub repository.
4. Choose GitHub Issues as issue tracker.
5. Select issue filter/query.
6. Choose runtime provider.
7. Choose agent provider.
8. Review project.
9. Persist project, repository, issue tracker, workflow policy, and optional imported tickets.

Creation must use a transient draft object and commit SwiftData records only on final creation.

## Runtime Providers

Runtime providers:

- Apple Container
- Local Workspace
- Mock Runtime

v0:

- Mock Runtime must work offline.
- Apple Container must be detected accurately but may remain execution-placeholder until implemented.
- Local Workspace must support real v0 execution.

Preflight:

- Runtime preflight must happen before creating runs, ticket runs, or workspace directories.
- Apple Container requires:
	- Apple silicon
	- macOS 26+
	- `container` executable
	- `container system version --format json`
	- `container system status --format json`
- Auditorium must not auto-start Apple Container services without explicit user action.

## Agent Providers

Agent providers:

- Codex CLI
- Generic CLI Agent
- Mock Agent

v0:

- Mock Agent must work offline.
- Codex CLI must be detected before Codex-backed runs.
- Real Codex process execution is required before production v0 is complete.

Codex execution requirements:

- Launch via `Process`.
- Use explicit executable path.
- Use explicit working directory.
- Capture stdout and stderr.
- Stream logs into runtime events.
- Support cancellation.
- Persist log file path.
- Convert final result into ticket-run status.

## Orchestration Engine

The orchestrator owns lifecycle and state transitions.

Responsibilities:

- Read enabled queue items.
- Run preflight checks.
- Create `RunRecord`.
- Create `TicketRunRecord`s.
- Enforce bounded concurrency.
- Prepare workspace.
- Start runtime.
- Start agent.
- Stream events.
- Track retries.
- Handle cancellation.
- Create PRs.
- Generate report.
- Persist all state changes.

The agent must not own orchestration. The agent can emit events, summaries, and recommendations; Auditorium owns run state, retries, cancellation, PR policy, and reporting.

## Bounded Concurrency

The orchestrator must support bounded concurrency.

Rules:

- User/project workflow policy sets default concurrency.
- Run request may override concurrency.
- Disabled queue items do not consume slots.
- Failed preflight consumes no slots and creates no ticket runs.
- Ticket runs must be isolated from one another.

## Retry Behavior

Retries are policy-driven.

Required behavior:

- Read max retry count from workflow policy.
- Retry transient runtime/agent failures until limit.
- Do not retry blocked tickets automatically.
- Do not retry canceled tickets automatically.
- Record retry count per ticket run.
- Emit retry events.

## WORKFLOW.md

Each project has a workflow policy modeled after a repository-owned `WORKFLOW.md`.

The app must:

- Store a project workflow policy.
- Let the user view/edit the policy.
- Snapshot the policy used for each run.
- Pass the policy to agent prompts.
- Eventually support reading the repository's real `WORKFLOW.md`.

Default policy:

```markdown
---
concurrency: 3
max_retries: 2
handoff_status: "Needs Review"
branch_prefix: "auditorium"
run_tests: true
open_pull_request: true
---
You are an autonomous coding agent working on a single issue.
Your job:
1. Read the issue carefully.
2. Inspect the repository.
3. Create a focused implementation plan.
4. Make the smallest correct change.
5. Run relevant tests.
6. Fix failures.
7. Commit changes on a ticket-specific branch.
8. Open a pull request.
9. Leave a concise summary for human review.
Do not make unrelated changes.
Do not touch secrets.
Do not rewrite large areas unless the issue requires it.
When blocked, explain exactly what is missing.
```

## Reports

Every run must produce a markdown report.

Required sections:

- Project
- Repository
- Issue source
- Run ID
- Started
- Ended
- Duration
- Summary
- Pull requests
- Completed tickets
- Failed tickets
- Blocked tickets
- Timeline

The app must support:

- Preview markdown.
- Copy markdown.
- Export `.md`.
- Reveal exported report in Finder.
- Persist report in project history.

The CLI must support:

- Write report to file.
- Print report path.
- Optionally print summary to stdout.

## Rust `symphony` CLI

Auditorium must ship with a Rust CLI named `symphony`.

Suggested workspace layout:

```text
crates/
  symphony/
    Cargo.toml
    src/
      main.rs
      config.rs
      github.rs
      workflow.rs
      workspace.rs
      orchestrator.rs
      codex.rs
      report.rs
      logs.rs
```

The CLI must follow the upstream Symphony service specification's core model:

- Long-running orchestration service.
- Workflow loader for `WORKFLOW.md`.
- Typed configuration layer.
- Issue tracker client.
- Orchestrator-owned scheduler state.
- Workspace manager.
- Agent runner.
- Structured logging.
- Optional status surface.

Auditorium-specific v0 adaptations:

- `tracker.kind` supports `github_issues`.
- `source.kind` supports `github`.
- GitHub credentials may come from:
	- `GITHUB_TOKEN`
	- keychain bridge supplied by the macOS app
	- explicit CLI option
- Codex command defaults to `codex`.
- Workspace root defaults to Auditorium's application support directory when launched by the app, or a CLI-provided path when launched manually.

Required commands:

```text
symphony init
symphony doctor
symphony run --repo OWNER/NAME --issue ISSUE_NUMBER
symphony daemon --project PROJECT_ID
symphony report --run RUN_ID
```

Command behavior:

- `init`
	- Create a default `WORKFLOW.md` if absent.
	- Never overwrite without confirmation or `--force`.

- `doctor`
	- Check GitHub authentication.
	- Check Git.
	- Check Codex CLI.
	- Check Apple Container when requested.
	- Print machine-readable JSON with `--json`.

- `run`
	- Run one GitHub issue through the orchestrator.
	- Create/reuse deterministic workspace.
	- Launch Codex.
	- Emit events.
	- Create PR if policy enables it.
	- Write report.

- `daemon`
	- Poll eligible GitHub issues.
	- Enforce bounded concurrency.
	- Reconcile running issues.
	- Retry transient failures with backoff.
	- Watch/reload `WORKFLOW.md`.

- `report`
	- Print or export a prior run report.

Required Rust implementation choices:

- Use `tokio` for async runtime.
- Use `clap` for CLI parsing.
- Use `serde`/`serde_json` for structured data.
- Use `serde_yaml` or equivalent for workflow front matter.
- Use `tracing` for structured logs.
- Use `reqwest` or an equivalent HTTP client for GitHub API access.
- Use `git2` or Git CLI wrapper, but choose one policy and document it.
- Use typed domain structs for issues, runs, workspaces, and events.

CLI output requirements:

- Human-readable logs by default.
- JSON output with `--json`.
- Non-zero exit on failed preflight or failed run.
- Stable error codes for app integration.

CLI/app integration:

- The macOS app may invoke the Rust CLI for real orchestration.
- The CLI should emit newline-delimited JSON events for the app to ingest.
- The app remains the durable SwiftData UI state owner.
- The CLI remains the headless worker/runtime implementation.

## GitHub Integration Requirements

Source-code provider must support:

- List repositories visible to authenticated user.
- Resolve repository metadata.
- Clone or update repository.
- Create ticket branch.
- Commit changes.
- Push branch.
- Open pull request.
- Return PR URL and checks state when available.

Issue tracker provider must support:

- List issues by repository/filter.
- Fetch issue details.
- Normalize labels and assignees.
- Add comment.
- Optionally update labels/state if configured.

v0 should avoid surprising destructive behavior:

- Do not close issues automatically.
- Do not merge PRs automatically.
- Do not force-push.
- Do not overwrite user changes in a reused workspace without explicit policy.

## Filesystem Layout

Default app workspace:

```text
~/Library/Application Support/Auditorium/
  Projects/
    <project-id>/
      Repositories/
      Workspaces/
        <ticket-id>/
      Logs/
      Reports/
```

Rules:

- Ticket IDs must be sanitized for paths.
- Workspaces must be deterministic.
- Reports must be durable files.
- Logs must be durable files.
- The app must be able to reveal workspace/report paths in Finder.

## Settings

Settings sections:

- Accounts
- GitHub
- Agent providers
- Runtime providers
- Security
- Concurrency
- Reports
- Logs

Security settings:

- Show where secrets are stored.
- Clear credentials.
- Require confirmation before starting runs.
- Require confirmation before opening PRs.
- Allow network access.
- Allow filesystem writes.
- Runtime isolation level.

Settings must reflect enforced behavior, not only visual preferences.

## Testing Requirements

Use Swift Testing for app tests.

Required Swift tests:

- Project creation.
- Queue ordering.
- Ticket status transitions.
- Report generation.
- Runtime detection parsing.
- Workspace path generation.
- Provider normalization.
- GitHub adapter shape.
- Agent preflight.
- Runtime preflight.
- Retry behavior.
- Run aggregation.

Required Rust CLI tests:

- `WORKFLOW.md` parsing.
- Config defaults and validation.
- GitHub issue normalization.
- Workspace sanitization.
- Dispatch eligibility.
- Bounded concurrency.
- Retry backoff.
- JSON event output.
- Report generation.
- `doctor --json` output.

## v0 Completion Criteria

v0 is complete only when all are true:

1. User can authenticate GitHub.
2. User can select a GitHub repository.
3. User can import GitHub Issues.
4. User can queue issues.
5. User can reorder queue.
6. User can run queue.
7. Runtime preflight blocks unsafe/missing runtime.
8. Agent preflight blocks missing Codex CLI.
9. Real Codex process execution runs for at least one issue.
10. Per-ticket workspace is created deterministically.
11. Git branch is created per ticket.
12. Code changes can be committed.
13. Pull request can be opened.
14. Run events stream live into the app.
15. Ticket inspector reflects current state.
16. Markdown report is generated and saved.
17. `symphony doctor` works.
18. `symphony run` works for one GitHub issue.
19. Swift tests pass.
20. Rust tests pass.
21. macOS app builds cleanly.

## Current Prototype Gaps

Known incomplete areas:

- GitHub OAuth callback/device flow.
- Real GitHub API implementation.
- Real Git clone/branch/commit/push implementation.
- Real Codex `Process` runner.
- Real Apple Container execution.
- True bounded concurrency.
- Workflow policy parser and live reload.
- Retry policy enforcement.
- Rust `symphony` CLI.
- Full UI acceptance tests.
- SwiftData migrations.
- Security toggles enforcement.

These gaps should be treated as product requirements, not optional polish.
