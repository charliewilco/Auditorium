import Foundation
import SwiftData
import Testing

@testable import AuditoriumCore

@MainActor
struct AuditoriumCoreTests {
	@Test func workflowPolicyParserReadsCorePolicyValues() throws {
		let policy = try WorkflowPolicyParser().parse(
			"""
			---
			concurrency: 4
			max_retries: 3
			max_retry_backoff_ms: 8000
			branch_prefix: "codex"
			run_tests: false
			open_pull_request: true
			handoff_status: "Needs Review"
			update_issue_labels: true
			---
			Implement the issue.
			"""
		)

		#expect(policy.concurrency == 4)
		#expect(policy.maxRetries == 3)
		#expect(policy.maxRetryBackoffMilliseconds == 8_000)
		#expect(policy.branchPrefix == "codex")
		#expect(policy.runTests == false)
		#expect(policy.openPullRequest)
		#expect(policy.handoffStatus == "Needs Review")
		#expect(policy.updateIssueLabels)
		#expect(policy.prompt == "Implement the issue.")
	}

	@Test func workflowPolicyParserRejectsInvalidBooleanValues() {
		do {
			_ = try WorkflowPolicyParser().parse(
				"""
				---
				run_tests: maybe
				---
				Implement the issue.
				"""
			)
		}
		catch {
			#expect(error.localizedDescription == "run_tests must be a boolean.")
			return
		}
		Issue.record("Expected invalid boolean policy value to throw.")
	}

	@Test func workflowPolicyParserRejectsBlankBranchPrefix() {
		do {
			_ = try WorkflowPolicyParser().parse(
				"""
				---
				branch_prefix: ""
				---
				Implement the issue.
				"""
			)
		}
		catch {
			#expect(error.localizedDescription == "branch_prefix must not be empty.")
			return
		}
		Issue.record("Expected blank branch prefix to throw.")
	}

	@Test func workflowPolicyEditorBuffersValidProjectEditsBeforeSaving() throws {
		let project = Project(
			name: "Workflow Project",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
		var editor = WorkflowPolicyEditorState(project: project)
		let updatedMarkdown = """
			---
			concurrency: 5
			max_retries: 1
			branch_prefix: "codex"
			run_tests: false
			open_pull_request: true
			---
			Fix the selected issue.
			"""

		editor.draftMarkdown = updatedMarkdown

		#expect(editor.hasProject)
		#expect(editor.hasUnsavedChanges)
		#expect(editor.canSave)
		#expect(project.workflowPolicyMarkdown == WorkflowPolicy.defaultMarkdown)
		try editor.apply(to: project, now: Date(timeIntervalSince1970: 42))

		#expect(project.workflowPolicyMarkdown == updatedMarkdown)
		#expect(project.updatedAt == Date(timeIntervalSince1970: 42))
		#expect(editor.hasUnsavedChanges == false)
	}

	@Test func workflowPolicyEditorRejectsInvalidDrafts() throws {
		let project = Project(
			name: "Invalid Workflow",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
		var editor = WorkflowPolicyEditorState(project: project)

		editor.draftMarkdown = """
			---
			concurrency: 99
			---
			Prompt
			"""

		#expect(editor.isValid == false)
		#expect(editor.canSave == false)
		#expect(editor.validationError == "concurrency must be between 1 and 16.")
		#expect(throws: WorkflowPolicyEditorError.invalidPolicy("concurrency must be between 1 and 16.")) {
			try editor.apply(to: project)
		}
		#expect(project.workflowPolicyMarkdown == WorkflowPolicy.defaultMarkdown)
	}

	@Test func workflowPolicyEditorCanRestoreDefaultAndRevert() {
		let customMarkdown = """
			---
			concurrency: 2
			max_retries: 0
			---
			Custom prompt.
			"""
		let project = Project(
			name: "Custom Workflow",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex,
			workflowPolicyMarkdown: customMarkdown
		)
		var editor = WorkflowPolicyEditorState(project: project)

		editor.restoreDefault()
		#expect(editor.draftMarkdown == WorkflowPolicy.defaultMarkdown)
		#expect(editor.hasUnsavedChanges)

		editor.revert()
		#expect(editor.draftMarkdown == customMarkdown)
		#expect(editor.hasUnsavedChanges == false)
	}

	@Test func appCommandsHaveStableNotificationNamesForMenuActions() {
		#expect(AppCommand.allCases.map(\.title) == ["New Project", "Run Queue", "Dry Run", "Find Tickets", "Inspect Selected Ticket"])
		let notifications = AppCommand.allCases.compactMap(\.notificationName)

		#expect(notifications.count == 4)
		#expect(Set(notifications.map(\.rawValue)).count == notifications.count)
		#expect(AppCommand.newProject.notificationName == nil)
	}

	@Test func appStateHandlesProjectAndTicketSearchCommands() {
		let appState = AppState()

		appState.handle(.newProject)
		#expect(appState.isShowingProjectWizard)

		appState.handle(.findTickets)
		#expect(appState.selectedDestination == .tickets)
		#expect(appState.isTicketSearchPresented)
	}

	@Test func appStateInspectCommandSelectsFirstTicketOnlyWhenNeeded() {
		let appState = AppState()
		let firstTicketID = UUID()
		let selectedTicketID = UUID()

		appState.handle(.inspectSelectedTicket, firstTicketID: firstTicketID)
		#expect(appState.selectedTicketID == firstTicketID)

		appState.selectedTicketID = selectedTicketID
		appState.handle(.inspectSelectedTicket, firstTicketID: UUID())
		#expect(appState.selectedTicketID == selectedTicketID)
	}

	@Test func reportGeneratorUsesRecordedRunEvidenceInsteadOfMockPlaceholders() {
		let project = Project(
			name: "Evidence Project",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
		let run = RunRecord(
			projectID: project.id,
			status: .completed,
			totalTickets: 1,
			completedTickets: 1,
			pullRequestsCreated: 1,
			summary: "Completed 1 ticket."
		)
		run.endedAt = run.startedAt.addingTimeInterval(120)
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "42",
			title: "Use real report evidence",
			body: "Body",
			status: .needsReview,
			labels: ["reports"],
			assignee: nil,
			priority: .high,
			webURL: "https://github.com/charliewilco/Auditorium/issues/42",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 2,
			sourceProjectID: project.id
		)
		let ticketRun = TicketRunRecord(
			runID: run.id,
			ticketID: ticket.id,
			workspacePath: "/tmp/auditorium/workspaces/42",
			branchName: "auditorium/issue-42",
			status: .needsReview,
			logPath: "/tmp/auditorium/logs/42.log",
			pullRequestURL: "https://github.com/charliewilco/Auditorium/pull/42",
			summary: "Implemented the requested change.",
			confidence: 0.91
		)
		let pullRequest = PullRequestRecord(
			provider: .github,
			ticketRunID: ticketRun.id,
			title: "42: Use real report evidence",
			url: "https://github.com/charliewilco/Auditorium/pull/42",
			branchName: "auditorium/issue-42",
			targetBranch: "main",
			status: .open,
			checksStatus: .passed
		)
		let event = RuntimeEventRecord(
			runID: run.id,
			ticketRunID: ticketRun.id,
			level: .success,
			category: .tests,
			message: "cargo test passed."
		)

		let markdown = ReportGenerator().generate(
			project: project,
			run: run,
			ticketRuns: [ticketRun],
			tickets: [ticket],
			pullRequests: [pullRequest],
			events: [event]
		)

		#expect(markdown.contains("Run Status: Completed"))
		#expect(markdown.contains("Run Summary: Completed 1 ticket."))
		#expect(markdown.contains("Workspace: /tmp/auditorium/workspaces/42"))
		#expect(markdown.contains("Log: /tmp/auditorium/logs/42.log"))
		#expect(markdown.contains("- Pull Request Checks: Passed"))
		#expect(markdown.contains("- Last Event: [tests] cargo test passed."))
		#expect(!markdown.contains("Mocked file list unavailable"))
		#expect(!markdown.contains("Relevant tests simulated"))
	}

	@Test func reportGeneratorDocumentsCompletedDryRunsWithoutTicketRuns() {
		let project = Project(
			name: "Dry Run Project",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
		let run = RunRecord(
			projectID: project.id,
			status: .completed,
			totalTickets: 0,
			completedTickets: 0,
			summary: "Dry run completed. No workspaces or agents were started."
		)
		run.endedAt = run.startedAt.addingTimeInterval(1)
		let event = RuntimeEventRecord(
			runID: run.id,
			level: .success,
			category: .orchestration,
			message: "Dry run validated 0 enabled queue items."
		)

		let markdown = ReportGenerator().generate(
			project: project,
			run: run,
			ticketRuns: [],
			tickets: [],
			pullRequests: [],
			events: [event]
		)

		#expect(markdown.contains("Run Status: Completed"))
		#expect(markdown.contains("Run Summary: Dry run completed. No workspaces or agents were started."))
		#expect(markdown.contains("No completed tickets."))
		#expect(markdown.contains("No failed tickets."))
		#expect(markdown.contains("No blocked tickets."))
		#expect(markdown.contains("No canceled tickets."))
		#expect(markdown.contains("[orchestration] Dry run validated 0 enabled queue items."))
	}

	@Test func reportGeneratorIncludesCrossTicketFindings() {
		let project = Project(
			name: "Coordination Project",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
		let run = RunRecord(projectID: project.id, status: .completed, totalTickets: 1, completedTickets: 1, summary: "Done.")
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "1",
			title: "Coordinate runtime",
			body: "",
			status: .completed,
			labels: ["runtime"],
			assignee: nil,
			priority: .medium,
			webURL: "https://github.com/charliewilco/Auditorium/issues/1",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			sourceProjectID: project.id
		)
		let message = CoordinationMessageRecord(
			runID: run.id,
			externalMessageID: "coord-1",
			sourceIssueNumber: 1,
			targetIssueNumber: 4,
			kind: "finding",
			summary: "Runtime request shape overlaps.",
			changedFiles: ["RuntimeExecutionRequest.swift"]
		)

		let markdown = ReportGenerator().generate(
			project: project,
			run: run,
			ticketRuns: [],
			tickets: [ticket],
			pullRequests: [],
			events: [],
			coordinationMessages: [message]
		)

		#expect(markdown.contains("## Cross-ticket Findings"))
		#expect(markdown.contains("[finding] 1: Coordinate runtime -> #4"))
		#expect(markdown.contains("RuntimeExecutionRequest.swift"))
	}

	@Test func reportActionsCopyExportAndRevealUseDurableReportData() throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCoreTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let reportPath = root.appending(path: "saved-report.md")
		let exportPath = root.appending(path: "exported.md")
		let report = ReportRecord(
			projectID: UUID(),
			runID: UUID(),
			title: "Run 42: Fix / OAuth?",
			markdown: "# Run 42\n\nValidated report actions.",
			filePath: reportPath.path()
		)

		try ReportActions.export(report, to: exportPath)
		let exportedMarkdown = try String(contentsOf: exportPath, encoding: .utf8)

		#expect(ReportActions.markdownForCopy(report) == "# Run 42\n\nValidated report actions.")
		#expect(ReportActions.revealURL(for: report) == reportPath)
		#expect(ReportActions.suggestedExportFileName(for: report) == "Run 42- Fix - OAuth.md")
		#expect(exportedMarkdown == report.markdown)
	}

	@Test func appRunCoordinatorPersistsDryRunReportOutsideSwiftUIView() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCoreTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = ApplicationWorkspaceService(rootDirectory: root)
		let project = Project(
			name: "Coordinator Project",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "101",
			title: "Move run coordination",
			body: "Dry-run persistence should live outside SwiftUI.",
			status: .ready,
			labels: ["architecture"],
			assignee: nil,
			priority: .medium,
			webURL: "https://github.com/charliewilco/Auditorium/issues/101",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 2,
			sourceProjectID: project.id
		)
		let enabledItem = QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .medium)
		let disabledItem = QueueItemRecord(ticketID: UUID(), projectID: project.id, position: 1, priority: .low, isEnabled: false)
		context.insert(project)
		context.insert(ticket)
		context.insert(enabledItem)
		context.insert(disabledItem)
		try context.save()
		let coordinator = AppRunCoordinator(
			workspaceService: workspace,
			runtimeDetection: RuntimeDetectionService(staticChecks: []),
			reportGenerator: ReportGenerator()
		)

		let run = try coordinator.createDryRun(
			project: project,
			queueItems: [enabledItem, disabledItem],
			tickets: [ticket],
			context: context
		)

		let persistedRun = try #require(context.fetch(FetchDescriptor<RunRecord>()).first)
		let event = try #require(context.fetch(FetchDescriptor<RuntimeEventRecord>()).first)
		let report = try #require(context.fetch(FetchDescriptor<ReportRecord>()).first)

		#expect(run.id == persistedRun.id)
		#expect(persistedRun.status == .completed)
		#expect(persistedRun.totalTickets == 1)
		#expect(persistedRun.reportMarkdown.contains("Run Summary: Dry run completed. No workspaces or agents were started."))
		#expect(event.message == "Dry run validated 1 enabled queue items.")
		#expect(report.markdown == persistedRun.reportMarkdown)
		#expect(FileManager.default.fileExists(atPath: report.filePath))
	}

	@Test func processCommandReturnsWhenDescendantKeepsOutputPipeOpen() async throws {
		let startedAt = Date()
		let result = try await ProcessCommand.runStreaming(
			executable: "/bin/sh",
			arguments: ["-lc", "(sleep 5) & printf 'done\\n'"]
		)

		#expect(result.standardOutput == "done\n")
		#expect(Date().timeIntervalSince(startedAt) < 2)
	}

	@Test func orchestrationRunPlanSnapshotsEnabledQueueInOrder() {
		let projectID = UUID()
		let first = QueueItemRecord(
			ticketID: UUID(),
			projectID: projectID,
			position: 2,
			priority: .high,
			isEnabled: true,
			concurrencyGroup: "ui"
		)
		let disabled = QueueItemRecord(ticketID: UUID(), projectID: projectID, position: 1, priority: .low, isEnabled: false)
		let second = QueueItemRecord(
			ticketID: UUID(),
			projectID: projectID,
			position: 0,
			priority: .urgent,
			isEnabled: true,
			concurrencyGroup: "auth"
		)

		let plan = OrchestrationRunPlan.make(
			queueItems: [first, disabled, second],
			requestedConcurrency: 2,
			workflowPolicyMarkdown: WorkflowPolicy.defaultMarkdown
		)

		#expect(plan.concurrency == 2)
		#expect(plan.queueSnapshot.map(\.ticketID) == [second.ticketID, first.ticketID])
		#expect(plan.queueSnapshot.map(\.concurrencyGroup) == ["auth", "ui"])
		#expect(plan.batches.map(\.count) == [2])
	}

	@Test func importedGitHubIssuesCanBeQueuedReorderedAndRunOnlyWhenEnabled() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Auditorium",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
		context.insert(project)
		try context.save()
		let provider = StaticCoreIssueTrackerProvider(tickets: [
			ticket(number: 101, labels: ["agent", "ui"], assignee: "charliewilco"),
			ticket(number: 102, labels: ["agent", "backend"], assignee: nil),
			ticket(number: 103, labels: ["agent", "tests"], assignee: "codex"),
		])

		let imported = try await ProjectIssueImportService().importTickets(for: project, context: context, provider: provider)
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>()).sorted { $0.externalID < $1.externalID }
		let queue = QueueService()
		try queue.addTickets([tickets[0].id], projectID: project.id, context: context)
		try queue.addTickets([tickets[1].id], projectID: project.id, context: context)
		try queue.addTickets([tickets[2].id], projectID: project.id, context: context)
		try queue.addTickets([tickets[1].id], projectID: project.id, context: context)
		try queue.moveQueueItems(from: IndexSet(integer: 2), to: 0, projectID: project.id, context: context)
		var queueItems = try context.fetch(FetchDescriptor<QueueItemRecord>()).sorted { $0.position < $1.position }
		let disabledItem = try #require(queueItems.first { $0.ticketID == tickets[1].id })
		try queue.setQueueItem(disabledItem, isEnabled: false, context: context)
		queueItems = try context.fetch(FetchDescriptor<QueueItemRecord>()).sorted { $0.position < $1.position }

		let plan = OrchestrationRunPlan.make(
			queueItems: queueItems,
			requestedConcurrency: 2,
			workflowPolicyMarkdown: WorkflowPolicy.defaultMarkdown
		)

		#expect(imported == 3)
		#expect(tickets.map(\.externalID) == ["101", "102", "103"])
		#expect(tickets.allSatisfy { $0.provider == .githubIssues && $0.sourceProjectID == project.id })
		#expect(queueItems.count == 3)
		#expect(queueItems.map(\.ticketID) == [tickets[2].id, tickets[0].id, tickets[1].id])
		#expect(queueItems.map(\.position) == [0, 1, 2])
		#expect(queueItems.first { $0.ticketID == tickets[1].id }?.isEnabled == false)
		#expect(tickets.allSatisfy { $0.status == .queued })
		#expect(plan.queueSnapshot.map(\.ticketID) == [tickets[2].id, tickets[0].id])
		#expect(plan.batches.map(\.count) == [2])
	}

	@Test func runRecordPersistsQueueSnapshotJSON() {
		let first = QueueRunSnapshot(id: UUID(), ticketID: UUID(), position: 0, priority: .high, concurrencyGroup: "ui")
		let second = QueueRunSnapshot(id: UUID(), ticketID: UUID(), position: 1, priority: .low, concurrencyGroup: "backend")
		let run = RunRecord(projectID: UUID())

		run.queueSnapshot = [first, second]

		#expect(run.queueSnapshotJSON.contains(first.ticketID.uuidString))
		#expect(run.queueSnapshot == [first, second])
	}

	@Test func workspaceCleanupRemovesOnlyOwnedTerminalWorkspaces() throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCoreTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let service = ApplicationWorkspaceService(rootDirectory: root)
		let projectID = UUID()
		let failedWorkspace = service.workspacePath(projectID: projectID, ticketExternalID: "CORE-101")
		let reviewWorkspace = service.workspacePath(projectID: projectID, ticketExternalID: "CORE-102")
		for workspace in [failedWorkspace, reviewWorkspace] {
			try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		}
		let unsafePath = root.deletingLastPathComponent().appending(path: "outside-auditorium").path()
		let ticketRuns = [
			TicketRunRecord(runID: UUID(), ticketID: UUID(), workspacePath: failedWorkspace.path(), status: .failed),
			TicketRunRecord(
				runID: UUID(),
				ticketID: UUID(),
				workspacePath: reviewWorkspace.path(),
				status: .needsReview,
				pullRequestURL: "https://github.com/charliewilco/Auditorium/pull/102"
			),
			TicketRunRecord(runID: UUID(), ticketID: UUID(), workspacePath: unsafePath, status: .canceled),
		]

		let result = try service.cleanupTicketWorkspaces(
			projectID: projectID,
			ticketRuns: ticketRuns,
			policy: .removeCanceledAndTerminalWithoutReview
		)

		#expect(result.removed == 1)
		#expect(result.preserved == 2)
		#expect(result.skippedUnsafePaths == [unsafePath])
		#expect(FileManager.default.fileExists(atPath: failedWorkspace.path()) == false)
		#expect(FileManager.default.fileExists(atPath: reviewWorkspace.path()))
	}

	@Test func gitBranchNameSanitizesTicketFields() {
		let ticket = TicketDescriptor(
			provider: .githubIssues,
			externalID: "ISSUE 42",
			title: "Fix OAuth / callback!",
			body: "Body",
			status: .ready,
			labels: [],
			assignee: nil,
			priority: .medium,
			webURL: nil,
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			blockedBy: []
		)

		let branch = GitBranchName.make(prefix: "auditorium", ticketExternalID: ticket.externalID, ticketTitle: ticket.title)

		#expect(branch == "auditorium/issue-42-fix-oauth-callback")
	}

	@Test func githubIssueFilterOptionsDeriveQueriesFromRealIssueMetadata() {
		let options = GitHubIssueFilterOption.options(from: [
			ticket(number: 1, labels: ["Ready for agent", "Bug"], assignee: "charlie"),
			ticket(number: 2, labels: ["ready for agent"], assignee: "charlie"),
			ticket(number: 3, labels: ["Enhancement"], assignee: "octo"),
		])

		#expect(options.map(\.rawValue).prefix(2) == ["state:open", "state:all"])
		#expect(options.contains { $0.title == "Ready for agent" && $0.rawValue == #"state:open label:"Ready for agent""# })
		#expect(options.contains { $0.title == "@charlie" && $0.rawValue == "state:open assignee:charlie" })
		#expect(options.first { $0.title == "Ready for agent" }?.subtitle == "2 issues with this label")
		#expect(options.first { $0.title == "@octo" }?.subtitle == "1 assigned issue")
	}

	@Test func githubAPIClientRetriesServerErrorThenSucceeds() async throws {
		let transport = ScriptedGitHubTransport(results: [
			.response(statusCode: 503, payload: "{}"),
			.response(statusCode: 200, payload: Self.githubRepositoriesPayload),
		])
		let client = GitHubAPIClient(token: "test", transport: transport, retryPolicy: Self.fastGitHubRetryPolicy, sleep: { _ in })

		let repositories = try await client.listRepositories()

		#expect(repositories.map(\.fullName) == ["charliewilco/Auditorium"])
		#expect(await transport.callCount() == 2)
	}

	@Test func githubAPIClientExhaustsServerErrorRetriesWithOriginalHTTPFailure() async {
		let transport = ScriptedGitHubTransport(results: [
			.response(statusCode: 503, payload: "{}"),
			.response(statusCode: 503, payload: "{}"),
			.response(statusCode: 503, payload: "{}"),
		])
		let client = GitHubAPIClient(
			token: "test",
			transport: transport,
			retryPolicy: GitHubAPIRetryPolicy(maxRetries: 2, baseDelay: .milliseconds(1), maxDelay: .milliseconds(1)),
			sleep: { _ in }
		)
		var message = ""

		do {
			_ = try await client.listRepositories()
		}
		catch {
			message = error.localizedDescription
		}

		#expect(message == "GitHub API request failed with HTTP 503.")
		#expect(await transport.callCount() == 3)
	}

	@Test func githubAPIClientDoesNotRetryAuthenticationFailure() async {
		let transport = ScriptedGitHubTransport(results: [
			.response(statusCode: 401, payload: "{}")
		])
		let client = GitHubAPIClient(token: "test", transport: transport, retryPolicy: Self.fastGitHubRetryPolicy, sleep: { _ in })
		var message = ""

		do {
			_ = try await client.listRepositories()
		}
		catch {
			message = error.localizedDescription
		}

		#expect(message == "GitHub credentials are missing, expired, or unauthorized.")
		#expect(await transport.callCount() == 1)
	}

	@Test func githubAPIClientDoesNotRetryNonRateLimitClientFailures() async {
		for statusCode in [404, 422] {
			let transport = ScriptedGitHubTransport(results: [
				.response(statusCode: statusCode, payload: "{}")
			])
			let client = GitHubAPIClient(token: "test", transport: transport, retryPolicy: Self.fastGitHubRetryPolicy, sleep: { _ in })
			var message = ""

			do {
				_ = try await client.listRepositories()
			}
			catch {
				message = error.localizedDescription
			}

			#expect(message == "GitHub API request failed with HTTP \(statusCode).")
			#expect(await transport.callCount() == 1)
		}
	}

	@Test func githubAPIClientRetriesRateLimitAndUsesClampedResetDelay() async throws {
		let reset = String(Int(Date().addingTimeInterval(60).timeIntervalSince1970))
		let transport = ScriptedGitHubTransport(results: [
			.response(statusCode: 403, payload: "{}", headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset]),
			.response(statusCode: 200, payload: "{}", headers: ["X-OAuth-Scopes": "repo, read:user"]),
		])
		let recorder = GitHubRetrySleepRecorder()
		let client = GitHubAPIClient(
			token: "test",
			transport: transport,
			retryPolicy: GitHubAPIRetryPolicy(maxRetries: 1, baseDelay: .milliseconds(1), maxDelay: .seconds(1)),
			sleep: { duration in
				await recorder.record(duration)
			}
		)

		let scopes = try await client.validateScopes()

		#expect(scopes == ["repo", "read:user"])
		#expect(await transport.callCount() == 2)
		#expect(await recorder.durations() == [.seconds(1)])
	}

	@Test func githubAPIClientRetriesTransientTransportErrorThenSucceeds() async throws {
		let transport = ScriptedGitHubTransport(results: [
			.urlError(URLError(.timedOut)),
			.response(statusCode: 200, payload: Self.githubRepositoriesPayload),
		])
		let client = GitHubAPIClient(token: "test", transport: transport, retryPolicy: Self.fastGitHubRetryPolicy, sleep: { _ in })

		let repositories = try await client.listRepositories()

		#expect(repositories.map(\.fullName) == ["charliewilco/Auditorium"])
		#expect(await transport.callCount() == 2)
	}

	@Test func githubAPIClientPropagatesCancellationDuringBackoff() async {
		let transport = ScriptedGitHubTransport(results: [
			.response(statusCode: 503, payload: "{}")
		])
		let client = GitHubAPIClient(
			token: "test",
			transport: transport,
			retryPolicy: GitHubAPIRetryPolicy(maxRetries: 1, baseDelay: .seconds(1), maxDelay: .seconds(1)),
			sleep: { _ in
				throw CancellationError()
			}
		)
		var didCancel = false

		do {
			_ = try await client.listRepositories()
		}
		catch is CancellationError {
			didCancel = true
		}
		catch {}

		#expect(didCancel)
		#expect(await transport.callCount() == 1)
	}

	@Test func providerStateSummariesExposeV0ProviderAvailability() {
		let repositoryProviders = ProviderStateSummaries.repositoryProviders()
		let issueProviders = ProviderStateSummaries.issueProviders()
		let agentProviders = ProviderStateSummaries.agentProviders()

		#expect(repositoryProviders.first { $0.id == RepositoryProviderKind.github.id }?.state == .implemented)
		#expect(repositoryProviders.first { $0.id == RepositoryProviderKind.gitlab.id }?.state == .unavailable)
		#expect(repositoryProviders.first { $0.id == RepositoryProviderKind.gitlab.id }?.detail.contains("GitHub-only") == true)
		#expect(issueProviders.first { $0.id == IssueProviderKind.githubIssues.id }?.state == .implemented)
		#expect(issueProviders.first { $0.id == IssueProviderKind.linear.id }?.state == .unavailable)
		#expect(issueProviders.first { $0.id == IssueProviderKind.imported.id }?.state == .unavailable)
		#expect(agentProviders.first { $0.id == AgentProviderKind.codex.id }?.state == .implemented)
		#expect(agentProviders.first { $0.id == AgentProviderKind.genericCLI.id }?.state == .implemented)
		#expect(agentProviders.first { $0.id == AgentProviderKind.mockAgent.id }?.state == .implemented)
	}

	@Test func providerRuntimeSummariesSeparateDetectionFromImplementation() {
		let statuses = ProviderStateSummaries.runtimeProviders(from: [
			RuntimeHealthCheck(id: "git", name: "Git", state: .available, detail: "/usr/bin/git", version: nil)
		])

		let localWorkspace = statuses.first { $0.kind == .localWorkspace }
		let mockRuntime = statuses.first { $0.kind == .mockRuntime }

		#expect(localWorkspace?.isRunnable == true)
		#expect(mockRuntime?.isRunnable == true)
	}

	@Test func githubCredentialSelectionOnlyIncludesAccountsWithSecrets() throws {
		let keychain = KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		let connected = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub Connected",
			keychainAccount: "connected-\(UUID().uuidString)"
		)
		let missingSecret = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub Missing",
			keychainAccount: "missing-\(UUID().uuidString)"
		)
		let unsupported = ProviderAccountRecord(
			providerKindRaw: "linear",
			displayName: "Linear",
			keychainAccount: "linear-\(UUID().uuidString)"
		)
		try keychain.storeSecret("gho_connected", account: connected.keychainAccount)
		defer { try? keychain.deleteSecret(account: connected.keychainAccount) }

		let selections = GitHubCredentialSelectionService().availableAccounts(
			from: [missingSecret, unsupported, connected]
		) { account in
			try keychain.readSecret(account: account)
		}

		#expect(selections.map(\.id) == [connected.id])
		#expect(selections.first?.displayName == "GitHub Connected")
	}

	@Test func projectEnvironmentSecretMetadataPersistsWhileValuesStayInKeychain() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let keychain = KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		let service = ProjectEnvironmentSecretService(keychain: keychain)
		let projectID = UUID()
		let secretValue = "github_pat_1234567890abcdefghijklmnopqrst"

		let record = try service.upsertSecret(projectID: projectID, name: "API_TOKEN", value: secretValue, context: context)
		defer { try? keychain.deleteSecret(account: record.keychainAccount) }

		let records = try context.fetch(FetchDescriptor<ProjectEnvironmentSecretRecord>())
		#expect(records.count == 1)
		#expect(records.first?.projectID == projectID)
		#expect(records.first?.name == "API_TOKEN")
		#expect(records.first?.isEnabled == true)
		#expect(records.first?.keychainAccount.contains(secretValue) == false)
		#expect(try keychain.readSecret(account: record.keychainAccount) == secretValue)
		#expect(try ModelIntegrityValidator.validate(context: context).isEmpty)
	}

	@Test func projectEnvironmentSecretServiceRejectsInvalidNames() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let service = ProjectEnvironmentSecretService(
			keychain: KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		)

		for name in ["api_token", "1TOKEN", "TOKEN-DASH", "TOKEN VALUE"] {
			#expect(throws: ProjectEnvironmentSecretError.invalidName(name)) {
				try service.upsertSecret(projectID: UUID(), name: name, value: "secret", context: context)
			}
		}
	}

	@Test func projectEnvironmentSecretDeleteRemovesKeychainValue() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let keychain = KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		let service = ProjectEnvironmentSecretService(keychain: keychain)

		let record = try service.upsertSecret(projectID: UUID(), name: "SERVICE_TOKEN", value: "secret-value", context: context)
		try service.deleteSecret(record, context: context)

		#expect(try context.fetch(FetchDescriptor<ProjectEnvironmentSecretRecord>()).isEmpty)
		#expect(try keychain.readSecret(account: record.keychainAccount) == nil)
	}

	@Test func projectEnvironmentSecretIntegrityRejectsSecretLikeMetadata() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let record = ProjectEnvironmentSecretRecord(
			projectID: UUID(),
			name: "SERVICE_TOKEN",
			keychainAccount: "gho_1234567890abcdefghijklmnopqrst"
		)
		context.insert(record)
		try context.save()

		let issues = try ModelIntegrityValidator.validate(context: context)
		let secretFields = Set(issues.filter { $0.reason.contains("secret") }.map { "\($0.model).\($0.field)" })

		#expect(secretFields == ["ProjectEnvironmentSecretRecord.keychainAccount"])
	}

	@Test func projectCreationReusesSelectedGitHubAccount() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCoreTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let keychain = KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		let account = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub Existing",
			keychainAccount: "existing-\(UUID().uuidString)"
		)
		try keychain.storeSecret("gho_existing", account: account.keychainAccount)
		defer { try? keychain.deleteSecret(account: account.keychainAccount) }
		context.insert(account)
		try context.save()
		let draft = ProjectDraft()
		draft.name = "Existing Account"
		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = "main"
		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.selectedRepositoryAccountID = account.id
		draft.importDemoTickets = false

		let projectID = try ProjectCreationService().createProject(
			from: draft,
			context: context,
			workspaceService: ApplicationWorkspaceService(rootDirectory: root),
			keychainService: keychain
		)

		let accounts = try context.fetch(FetchDescriptor<ProviderAccountRecord>())
		let repository = try #require(context.fetch(FetchDescriptor<RepositoryRecord>()).first { $0.projectID == projectID })
		let issueTracker = try #require(context.fetch(FetchDescriptor<IssueTrackerRecord>()).first { $0.projectID == projectID })
		#expect(accounts.map(\.id) == [account.id])
		#expect(repository.providerAccountID == account.id)
		#expect(issueTracker.providerAccountID == account.id)
	}

	@Test func projectCreationPersistsRealGitHubProjectWithoutDemoData() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCoreTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = ApplicationWorkspaceService(rootDirectory: root)
		let keychain = KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		let draft = ProjectDraft()
		draft.name = "Auditorium"
		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = "main"
		draft.repositoryCredential = "gho_real_project"
		draft.issueCredential = ""
		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.issueFilterName = "Open GitHub Issues"
		draft.issueTrackerURL = "https://github.com/charliewilco/Auditorium/issues"
		draft.runtimeProviderKind = .localWorkspace
		draft.agentProviderKind = .codex
		draft.importDemoTickets = false
		draft.importGitHubIssues = true

		let projectID = try ProjectCreationService().createProject(
			from: draft,
			context: context,
			workspaceService: workspace,
			keychainService: keychain
		)
		let project = try #require(context.fetch(FetchDescriptor<Project>()).first)
		let repository = try #require(context.fetch(FetchDescriptor<RepositoryRecord>()).first)
		let issueTracker = try #require(context.fetch(FetchDescriptor<IssueTrackerRecord>()).first)
		let account = try #require(context.fetch(FetchDescriptor<ProviderAccountRecord>()).first)
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())

		#expect(project.id == projectID)
		#expect(project.repositoryProviderKind == .github)
		#expect(project.issueProviderKind == .githubIssues)
		#expect(project.runtimeProviderKind == .localWorkspace)
		#expect(project.agentProviderKind == .codex)
		#expect(repository.provider == .github)
		#expect(repository.fullName == "charliewilco/Auditorium")
		#expect(repository.defaultBranch == "main")
		#expect(repository.providerAccountID == account.id)
		#expect(issueTracker.provider == .githubIssues)
		#expect(issueTracker.sourceIdentifier == "charliewilco/Auditorium")
		#expect(issueTracker.webURL == "https://github.com/charliewilco/Auditorium/issues")
		#expect(issueTracker.providerAccountID == account.id)
		#expect(tickets.isEmpty)
		#expect(try keychain.readSecret(account: account.keychainAccount) == "gho_real_project")
		#expect(FileManager.default.fileExists(atPath: workspace.projectDirectory(projectID: projectID).path()))
		for step in ProjectSetupStep.allCases {
			#expect(step.validationMessage(for: draft) == nil)
		}
	}

	@Test func oauthTokenMetadataNormalizesScopesAndExpiry() {
		let issuedAt = Date(timeIntervalSince1970: 1_000)
		let response = GitHubOAuthTokenResponse(
			accessToken: "gho_access",
			scope: "read:user, repo",
			tokenType: "bearer",
			expiresIn: 3_600,
			refreshToken: "ghr_refresh",
			refreshTokenExpiresIn: 7_200
		)
		let metadata = GitHubOAuthTokenMetadata(response: response, oauthClientID: "client-123", issuedAt: issuedAt)

		#expect(metadata.accessToken == "gho_access")
		#expect(metadata.oauthClientID == "client-123")
		#expect(metadata.grantedScopesRaw == "read:user,repo")
		#expect(metadata.tokenType == "bearer")
		#expect(metadata.accessTokenExpiresAt == Date(timeIntervalSince1970: 4_600))
		#expect(metadata.refreshToken == "ghr_refresh")
		#expect(metadata.refreshTokenExpiresAt == Date(timeIntervalSince1970: 8_200))
	}

	@Test func projectCreationStoresOAuthMetadataAndRefreshSecret() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCoreTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let keychain = KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		let issuedAt = Date(timeIntervalSince1970: 1_000)
		let draft = ProjectDraft()
		draft.name = "OAuth Metadata"
		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = "main"
		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.importDemoTickets = false
		draft.applyGitHubOAuthTokenResponse(
			GitHubOAuthTokenResponse(
				accessToken: "gho_access",
				scope: "repo,read:user",
				tokenType: "bearer",
				expiresIn: 3_600,
				refreshToken: "ghr_refresh",
				refreshTokenExpiresIn: 7_200
			),
			clientID: "client-123",
			issuedAt: issuedAt
		)

		_ = try ProjectCreationService().createProject(
			from: draft,
			context: context,
			workspaceService: ApplicationWorkspaceService(rootDirectory: root),
			keychainService: keychain
		)

		let account = try #require(context.fetch(FetchDescriptor<ProviderAccountRecord>()).first)
		let refreshTokenAccount = try #require(account.refreshTokenKeychainAccount)
		#expect(account.oauthClientID == "client-123")
		#expect(account.grantedScopes == ["repo", "read:user"])
		#expect(account.tokenType == "bearer")
		#expect(account.accessTokenExpiresAt == Date(timeIntervalSince1970: 4_600))
		#expect(account.refreshTokenExpiresAt == Date(timeIntervalSince1970: 8_200))
		#expect(try keychain.readSecret(account: account.keychainAccount) == "gho_access")
		#expect(try keychain.readSecret(account: refreshTokenAccount) == "ghr_refresh")

		try ProviderRegistry(keychainService: keychain).clearGitHubCredentials(context: context)

		#expect(try keychain.readSecret(account: account.keychainAccount) == nil)
		#expect(try keychain.readSecret(account: refreshTokenAccount) == nil)
	}

	@Test func providerRegistryRefreshesExpiredGitHubToken() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let keychain = KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		let now = Date(timeIntervalSince1970: 10_000)
		let project = Project(
			name: "Refresh",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
		let accessAccount = "access-\(UUID().uuidString)"
		let refreshAccount = "refresh-\(UUID().uuidString)"
		let account = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub Refresh",
			keychainAccount: accessAccount,
			oauthClientID: "client-123",
			grantedScopesRaw: "repo",
			tokenType: "bearer",
			accessTokenExpiresAt: now.addingTimeInterval(-1),
			refreshTokenKeychainAccount: refreshAccount,
			refreshTokenExpiresAt: now.addingTimeInterval(3_600)
		)
		try keychain.storeSecret("old-access", account: accessAccount)
		try keychain.storeSecret("old-refresh", account: refreshAccount)
		defer {
			try? keychain.deleteSecret(account: accessAccount)
			try? keychain.deleteSecret(account: refreshAccount)
		}
		context.insert(project)
		context.insert(
			RepositoryRecord(
				provider: .github,
				owner: "charliewilco",
				name: "Auditorium",
				fullName: "charliewilco/Auditorium",
				cloneURL: "https://github.com/charliewilco/Auditorium.git",
				webURL: "https://github.com/charliewilco/Auditorium",
				defaultBranch: "main",
				providerAccountID: account.id,
				projectID: project.id
			)
		)
		context.insert(account)
		try context.save()
		let payload = """
			{
				"access_token": "new-access",
				"scope": "repo,read:user",
				"token_type": "bearer",
				"expires_in": 900,
				"refresh_token": "new-refresh",
				"refresh_token_expires_in": 1800
			}
			"""
		let registry = ProviderRegistry(
			keychainService: keychain,
			githubOAuthService: GitHubOAuthDeviceFlowService(transport: MockGitHubTransport(payload: payload)),
			refreshSkew: 60,
			now: { now }
		)

		let token = try await registry.requireGitHubToken(for: project, context: context, operation: "testing refresh")

		#expect(token == "new-access")
		#expect(try keychain.readSecret(account: accessAccount) == "new-access")
		#expect(try keychain.readSecret(account: refreshAccount) == "new-refresh")
		#expect(account.grantedScopes == ["repo", "read:user"])
		#expect(account.accessTokenExpiresAt == now.addingTimeInterval(900))
		#expect(account.refreshTokenExpiresAt == now.addingTimeInterval(1_800))
		#expect(account.lastValidatedAt == now)
	}

	@Test func modelIntegrityValidatorRejectsPersistedSecretMaterial() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		context.insert(
			Project(
				name: "Secret Project",
				repositoryProviderKind: .github,
				repositoryName: "charliewilco/Auditorium",
				repositoryURL: "https://github.com/charliewilco/Auditorium?token=ghp_abcdefghijklmnopqrstuvwxyz",
				defaultBranch: "main",
				issueProviderKind: .githubIssues,
				runtimeProviderKind: .mockRuntime,
				agentProviderKind: .mockAgent
			)
		)

		let issues = try ModelIntegrityValidator.validate(context: context)

		#expect(issues.contains { $0.model == "Project" && $0.field == "repositoryURL" })
	}

	@Test func projectSetupStepValidationBlocksMissingCredentialsAndRequiredFields() {
		let draft = ProjectDraft()

		#expect(ProjectSetupStep.repositoryProvider.validationMessage(for: draft) == nil)
		#expect(ProjectSetupStep.repositoryCredentials.validationMessage(for: draft)?.contains("Connect GitHub") == true)

		draft.repositoryCredential = "gho_example"
		#expect(ProjectSetupStep.issueCredentials.validationMessage(for: draft) == nil)

		draft.name = " "
		#expect(ProjectSetupStep.repository.validationMessage(for: draft) == "Project name is required.")

		draft.name = "Auditorium"
		draft.repositoryName = " "
		#expect(ProjectSetupStep.repository.validationMessage(for: draft) == "Repository is required.")

		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = " "
		#expect(ProjectSetupStep.repository.validationMessage(for: draft) == "Repository URL is required.")

		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = " "
		#expect(ProjectSetupStep.repository.validationMessage(for: draft) == "Default branch is required.")
	}

	@Test func projectSetupStepValidationAcceptsCompleteRealGitHubDraft() {
		let draft = ProjectDraft()
		draft.name = "Auditorium"
		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = "main"
		draft.repositoryCredential = "gho_example"
		draft.issueCredential = "gho_example"
		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.issueTrackerURL = "https://github.com/charliewilco/Auditorium/issues"
		draft.importGitHubIssues = true
		draft.branchPrefix = "codex"

		for step in ProjectSetupStep.allCases {
			#expect(step.validationMessage(for: draft) == nil)
		}
	}

	@Test func projectSetupStepValidationChecksIssueSourceAndRunDefaults() {
		let draft = ProjectDraft()
		draft.issueCredential = "gho_example"
		draft.issueSourceName = " "

		#expect(ProjectSetupStep.issueSource.validationMessage(for: draft) == "Issue source name is required.")

		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = " "
		#expect(ProjectSetupStep.issueSource.validationMessage(for: draft) == "Issue source identifier is required.")

		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.issueTrackerURL = " "
		draft.importGitHubIssues = true
		#expect(ProjectSetupStep.issueSource.validationMessage(for: draft) == "Issue tracker URL is required when importing GitHub issues.")

		draft.issueTrackerURL = "https://github.com/charliewilco/Auditorium/issues"
		draft.concurrency = 0
		#expect(ProjectSetupStep.runDefaults.validationMessage(for: draft) == "Concurrency must be at least 1.")

		draft.concurrency = 1
		draft.maxRetries = -1
		#expect(ProjectSetupStep.runDefaults.validationMessage(for: draft) == "Max retries cannot be negative.")

		draft.maxRetries = 0
		draft.branchPrefix = " "
		#expect(ProjectSetupStep.runDefaults.validationMessage(for: draft) == "Branch prefix is required.")
	}

	@Test func runPreflightSummaryBlocksMissingCredentialsPermissionsToolsAndInvalidWorkflow() {
		let project = Project(
			name: "Preflight",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex,
			workflowPolicyMarkdown: """
				---
				branch_prefix: ""
				---
				Invalid workflow.
				"""
		)
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "42",
			title: "Fix preflight",
			body: "Body",
			status: .ready,
			labels: [],
			assignee: nil,
			priority: .medium,
			webURL: "",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			sourceProjectID: project.id
		)
		let queueItem = QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .medium)
		let summary = RunPreflightSummary.make(
			project: project,
			queueItems: [queueItem],
			tickets: [ticket],
			runtimeHealth: [
				RuntimeHealthCheck(id: "git", name: "Git", state: .available, detail: "/usr/bin/git", version: nil),
				RuntimeHealthCheck(
					id: "codex",
					name: "Codex CLI",
					state: .needsSetup,
					detail: "Codex CLI was not found.",
					version: nil
				),
			],
			providerAccounts: [],
			preferences: RunSecurityPreferences(
				allowNetworkAccess: false,
				allowFilesystemWrite: false,
				requireRunConfirmation: true,
				requirePullRequestConfirmation: true
			),
			workspaceRoot: "/tmp/workspaces",
			secretReader: { _ in nil }
		)

		#expect(summary.canStartRun == false)
		#expect(summary.blockingChecks.contains { $0.id == "workflow" })
		#expect(summary.blockingChecks.contains { $0.id == "network" })
		#expect(summary.blockingChecks.contains { $0.id == "filesystem" })
		#expect(summary.blockingChecks.contains { $0.id == "tool-codex" })
		#expect(summary.blockingChecks.contains { $0.id == "tool-gh" })
		#expect(summary.blockingChecks.contains { $0.id == "github-account" })
	}

	@Test func runPreflightSummaryReportsReadyRunPlan() {
		let project = Project(
			name: "Ready",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex,
			workflowPolicyMarkdown: """
				---
				branch_prefix: "auditorium"
				validation:
				  command: "swift test"
				open_pull_request: true
				---
				Implement safely.
				"""
		)
		let account = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub Charlie",
			keychainAccount: "github-token",
			grantedScopesRaw: "repo,read:user"
		)
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "7",
			title: "Fix review packet",
			body: "Body",
			status: .ready,
			labels: [],
			assignee: nil,
			priority: .medium,
			webURL: "",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			sourceProjectID: project.id
		)
		let summary = RunPreflightSummary.make(
			project: project,
			queueItems: [QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .medium)],
			tickets: [ticket],
			runtimeHealth: [
				RuntimeHealthCheck(id: "git", name: "Git", state: .available, detail: "/usr/bin/git", version: nil),
				RuntimeHealthCheck(
					id: "codex",
					name: "Codex CLI",
					state: .available,
					detail: "/opt/homebrew/bin/codex",
					version: nil
				),
				RuntimeHealthCheck(id: "gh", name: "GitHub CLI", state: .available, detail: "/opt/homebrew/bin/gh", version: nil),
			],
			providerAccounts: [account],
			preferences: RunSecurityPreferences(
				allowNetworkAccess: true,
				allowFilesystemWrite: true,
				requireRunConfirmation: true,
				requirePullRequestConfirmation: true
			),
			workspaceRoot: "/tmp/workspaces",
			secretReader: { _ in "gho_token" }
		)

		#expect(summary.canStartRun)
		#expect(summary.enabledIssueCount == 1)
		#expect(summary.branchPrefix == "auditorium")
		#expect(summary.validationCommand == "swift test")
		#expect(summary.opensPullRequests)
		#expect(summary.accountTitle == "GitHub Charlie")

		let noPullRequestProject = Project(
			name: "No PR",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex,
			workflowPolicyMarkdown: """
				---
				open_pull_request: false
				---
				Implement safely.
				"""
		)
		let noPullRequestSummary = RunPreflightSummary.make(
			project: noPullRequestProject,
			queueItems: [QueueItemRecord(ticketID: ticket.id, projectID: noPullRequestProject.id, position: 0, priority: .medium)],
			tickets: [ticket],
			runtimeHealth: [
				RuntimeHealthCheck(id: "git", name: "Git", state: .available, detail: "/usr/bin/git", version: nil),
				RuntimeHealthCheck(
					id: "codex",
					name: "Codex CLI",
					state: .available,
					detail: "/opt/homebrew/bin/codex",
					version: nil
				),
				RuntimeHealthCheck(id: "gh", name: "GitHub CLI", state: .available, detail: "/opt/homebrew/bin/gh", version: nil),
			],
			providerAccounts: [account],
			preferences: RunSecurityPreferences(
				allowNetworkAccess: true,
				allowFilesystemWrite: true,
				requireRunConfirmation: true,
				requirePullRequestConfirmation: false
			),
			workspaceRoot: "/tmp/workspaces",
			secretReader: { _ in "gho_token" }
		)

		#expect(noPullRequestSummary.opensPullRequests == false)
		#expect(noPullRequestSummary.checks.first { $0.id == "pull-request-confirmation" }?.state == .passed)
	}

	@Test func runReviewPacketDerivesReviewStateFromRecordsEventsAndReports() {
		let projectID = UUID()
		let run = RunRecord(
			projectID: projectID,
			status: .completedWithFailures,
			totalTickets: 2,
			completedTickets: 1,
			failedTickets: 1,
			reportMarkdown: """
				# Report

				## Changed Files
				- Sources/App.swift

				## Validation
				Validation passed.
				"""
		)
		let successfulTicket = TicketRecord(
			provider: .githubIssues,
			externalID: "1",
			title: "Success",
			body: "Body",
			status: .needsReview,
			labels: [],
			assignee: nil,
			priority: .medium,
			webURL: "",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			sourceProjectID: projectID
		)
		let failedTicket = TicketRecord(
			provider: .githubIssues,
			externalID: "2",
			title: "Failure",
			body: "Body",
			status: .failed,
			labels: [],
			assignee: nil,
			priority: .medium,
			webURL: "",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			sourceProjectID: projectID
		)
		let successfulRun = TicketRunRecord(
			runID: run.id,
			ticketID: successfulTicket.id,
			branchName: "auditorium/issue-1",
			status: .needsReview
		)
		let failedRun = TicketRunRecord(
			runID: run.id,
			ticketID: failedTicket.id,
			status: .failed,
			failureReason: "Validation failed."
		)
		let pullRequest = PullRequestRecord(
			provider: .github,
			ticketRunID: successfulRun.id,
			title: "Issue 1",
			url: "https://github.com/charliewilco/Auditorium/pull/1",
			branchName: "auditorium/issue-1",
			targetBranch: "main",
			status: .open,
			checksStatus: .pending
		)
		let event = RuntimeEventRecord(
			runID: run.id,
			ticketRunID: successfulRun.id,
			level: .success,
			category: .tests,
			message: "Workflow validation passed.",
			metadataJSON: #"{"changedFiles":["Sources/App.swift","Tests/AppTests.swift"]}"#
		)
		let report = ReportRecord(
			projectID: projectID,
			runID: run.id,
			title: "Run Report",
			markdown: run.reportMarkdown,
			filePath: "/tmp/report.md"
		)

		let packet = RunReviewPacket.make(
			run: run,
			ticketRuns: [successfulRun, failedRun],
			tickets: [successfulTicket, failedTicket],
			events: [event],
			coordinationMessages: [],
			pullRequests: [pullRequest],
			reports: [report]
		)

		#expect(packet.pullRequests.count == 1)
		#expect(packet.reportTitle == "Run Report")
		#expect(packet.changedFiles == ["Sources/App.swift", "Tests/AppTests.swift"])
		#expect(packet.validationSummary == "Validation passed.")
		#expect(packet.failedTickets.map(\.externalID) == ["2"])
		#expect(packet.nextAction.localizedCaseInsensitiveContains("retry"))
	}

	@Test func projectDashboardStateHandlesEmptyProjectAndQueue() {
		let state = ProjectDashboardState(
			project: nil,
			tickets: [],
			queueItems: [],
			runs: [],
			ticketRuns: [],
			pullRequests: [],
			reports: [],
			events: [],
			preflightSummary: nil,
			now: Date(timeIntervalSince1970: 0)
		)

		#expect(state.projectTitle == "No Project")
		#expect(state.readinessKind == .noProject)
		#expect(state.canRunQueue == false)
		#expect(state.queuePreview.isEmpty)
		#expect(state.reviewItems.isEmpty)
	}

	@Test func projectDashboardStateMarksEnabledQueueAsReady() {
		let project = dashboardProject()
		let ticket = dashboardTicket(projectID: project.id, externalID: "1", status: .ready)
		let queueItem = QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .high)

		let state = ProjectDashboardState(
			project: project,
			tickets: [ticket],
			queueItems: [queueItem],
			runs: [],
			ticketRuns: [],
			pullRequests: [],
			reports: [],
			events: [],
			preflightSummary: dashboardPreflight(
				enabledIssueCount: 1,
				checks: [.init(id: "queue", title: "Enabled Tickets", detail: "1 ticket will run.", state: .passed)]
			),
			now: Date(timeIntervalSince1970: 0)
		)

		#expect(state.readinessKind == .ready)
		#expect(state.canRunQueue)
		#expect(state.enabledQueueCount == 1)
		#expect(state.queuePreview.map(\.externalID) == ["1"])
	}

	@Test func projectDashboardStateSurfacesBlockedPreflight() {
		let project = dashboardProject()
		let ticket = dashboardTicket(projectID: project.id, externalID: "2", status: .ready)
		let queueItem = QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .medium)

		let state = ProjectDashboardState(
			project: project,
			tickets: [ticket],
			queueItems: [queueItem],
			runs: [],
			ticketRuns: [],
			pullRequests: [],
			reports: [],
			events: [],
			preflightSummary: dashboardPreflight(
				enabledIssueCount: 1,
				checks: [.init(id: "github", title: "GitHub Account", detail: "No GitHub account is connected.", state: .blocked)]
			),
			now: Date(timeIntervalSince1970: 0)
		)

		#expect(state.readinessKind == .blocked)
		#expect(state.readinessTitle == "Blocked")
		#expect(state.topBlocker == "GitHub Account")
		#expect(state.canRunQueue == false)
	}

	@Test func projectDashboardStateSummarizesActiveRunAndReviewRows() {
		let project = dashboardProject()
		let runningTicket = dashboardTicket(projectID: project.id, externalID: "3", status: .running)
		let failedTicket = dashboardTicket(projectID: project.id, externalID: "4", status: .failed)
		let reviewTicket = dashboardTicket(projectID: project.id, externalID: "5", status: .needsReview)
		let run = RunRecord(
			projectID: project.id,
			startedAt: Date(timeIntervalSince1970: 20),
			status: .running,
			totalTickets: 3,
			completedTickets: 1,
			failedTickets: 1,
			blockedTickets: 0,
			summary: "Running dashboard test tickets."
		)
		let runningTicketRun = TicketRunRecord(
			runID: run.id,
			ticketID: runningTicket.id,
			status: .running,
			startedAt: Date(timeIntervalSince1970: 21)
		)
		let failedTicketRun = TicketRunRecord(
			runID: run.id,
			ticketID: failedTicket.id,
			status: .failed,
			startedAt: Date(timeIntervalSince1970: 22),
			failureReason: "Validation failed."
		)
		let reviewTicketRun = TicketRunRecord(
			runID: run.id,
			ticketID: reviewTicket.id,
			status: .needsReview,
			startedAt: Date(timeIntervalSince1970: 23),
			pullRequestURL: "https://github.com/charliewilco/Auditorium/pull/5"
		)
		let event = RuntimeEventRecord(runID: run.id, level: .info, category: .agent, message: "Agent is running.")

		let state = ProjectDashboardState(
			project: project,
			tickets: [runningTicket, failedTicket, reviewTicket],
			queueItems: [],
			runs: [run],
			ticketRuns: [runningTicketRun, failedTicketRun, reviewTicketRun],
			pullRequests: [],
			reports: [],
			events: [event],
			preflightSummary: dashboardPreflight(enabledIssueCount: 0, checks: []),
			now: Date(timeIntervalSince1970: 0)
		)

		#expect(state.activeRun?.status == .running)
		#expect(state.activeRun?.progressText == "2 of 3 finished")
		#expect(state.activeRun?.runningTicketCount == 1)
		#expect(state.reviewItems.map(\.externalID) == ["5", "4"])
		#expect(state.activeRunEvents.map(\.message) == ["Agent is running."])
	}

	@Test func projectDashboardStateSortsRecentPullRequestsAndReports() {
		let project = dashboardProject()
		let ticket = dashboardTicket(projectID: project.id, externalID: "6", status: .needsReview)
		let run = RunRecord(projectID: project.id, status: .completed, totalTickets: 1, completedTickets: 1)
		let ticketRun = TicketRunRecord(runID: run.id, ticketID: ticket.id, status: .needsReview)
		let pullRequest = PullRequestRecord(
			provider: .github,
			ticketRunID: ticketRun.id,
			title: "Issue 6",
			url: "https://github.com/charliewilco/Auditorium/pull/6",
			branchName: "auditorium/issue-6",
			targetBranch: "main",
			status: .open,
			checksStatus: .passed,
			createdAt: Date(timeIntervalSince1970: 10)
		)
		let report = ReportRecord(
			projectID: project.id,
			runID: run.id,
			title: "Run Report",
			markdown: "Report",
			filePath: "/tmp/report.md",
			createdAt: Date(timeIntervalSince1970: 20)
		)

		let state = ProjectDashboardState(
			project: project,
			tickets: [ticket],
			queueItems: [],
			runs: [run],
			ticketRuns: [ticketRun],
			pullRequests: [pullRequest],
			reports: [report],
			events: [],
			preflightSummary: dashboardPreflight(enabledIssueCount: 0, checks: []),
			now: Date(timeIntervalSince1970: 0)
		)

		#expect(state.recentOutputs.map(\.title) == ["Run Report", "Issue 6"])
		#expect(state.recentOutputs.map(\.kind) == [.report, .pullRequest])
	}

	@Test func onboardingChecksValidateInstalledToolsAndAuthentication() async {
		let detection = RuntimeDetectionService(commandRunner: { launchPath, arguments in
			switch (launchPath, arguments) {
			case ("/usr/bin/which", ["container"]):
				RuntimeCommandResult(exitCode: 0, output: "/opt/homebrew/bin/container")
			case ("/usr/bin/which", ["codex"]):
				RuntimeCommandResult(exitCode: 0, output: "/opt/homebrew/bin/codex")
			case ("/usr/bin/which", ["gh"]):
				RuntimeCommandResult(exitCode: 0, output: "/opt/homebrew/bin/gh")
			case ("/opt/homebrew/bin/container", ["--version"]):
				RuntimeCommandResult(exitCode: 0, output: "container CLI version 0.12.3")
			case ("/opt/homebrew/bin/container", ["system", "status"]):
				RuntimeCommandResult(exitCode: 1, output: "apiserver is not running and not registered with launchd")
			case ("/opt/homebrew/bin/codex", ["--version"]):
				RuntimeCommandResult(exitCode: 0, output: "codex-cli 0.139.0")
			case ("/opt/homebrew/bin/codex", ["login", "status"]):
				RuntimeCommandResult(exitCode: 0, output: "Logged in using ChatGPT")
			case ("/opt/homebrew/bin/gh", ["--version"]):
				RuntimeCommandResult(exitCode: 0, output: "gh version 2.93.0\nhttps://github.com/cli/cli/releases/tag/v2.93.0")
			case ("/opt/homebrew/bin/gh", ["auth", "status", "--hostname", "github.com"]):
				RuntimeCommandResult(
					exitCode: 0,
					output: "github.com\n  ✓ Logged in to github.com account charliewilco (keyring)"
				)
			default:
				nil
			}
		})

		let checks = await detection.onboardingChecks()
		let checksByID = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })

		#expect(checksByID["container"]?.state == .unavailable)
		#expect(checksByID["container"]?.detail.contains("apiserver is not running") == true)
		#expect(checksByID["codex-auth"]?.state == .available)
		#expect(checksByID["codex-auth"]?.detail == "Logged in using ChatGPT")
		#expect(checksByID["github-auth"]?.state == .available)
		#expect(checksByID["github-auth"]?.detail == "GitHub CLI is authenticated for github.com as charliewilco.")
	}

	@Test func onboardingChecksReportMissingAuthenticationSeparatelyFromInstallation() async {
		let detection = RuntimeDetectionService(commandRunner: { launchPath, arguments in
			switch (launchPath, arguments) {
			case ("/usr/bin/which", ["container"]):
				RuntimeCommandResult(exitCode: 1, output: "")
			case ("/usr/bin/which", ["codex"]):
				RuntimeCommandResult(exitCode: 0, output: "/opt/homebrew/bin/codex")
			case ("/usr/bin/which", ["gh"]):
				RuntimeCommandResult(exitCode: 0, output: "/opt/homebrew/bin/gh")
			case ("/opt/homebrew/bin/codex", ["--version"]):
				RuntimeCommandResult(exitCode: 0, output: "codex-cli 0.139.0")
			case ("/opt/homebrew/bin/codex", ["login", "status"]):
				RuntimeCommandResult(exitCode: 1, output: "Not logged in")
			case ("/opt/homebrew/bin/gh", ["--version"]):
				RuntimeCommandResult(exitCode: 0, output: "gh version 2.93.0")
			case ("/opt/homebrew/bin/gh", ["auth", "status", "--hostname", "github.com"]):
				RuntimeCommandResult(exitCode: 1, output: "You are not logged into any GitHub hosts.")
			default:
				nil
			}
		})

		let checksByID = Dictionary(uniqueKeysWithValues: await detection.onboardingChecks().map { ($0.id, $0) })

		#expect(checksByID["container"]?.state == .needsSetup)
		#expect(checksByID["codex-auth"]?.state == .needsSetup)
		#expect(checksByID["codex-auth"]?.detail.contains("no authenticated session") == true)
		#expect(checksByID["github-auth"]?.state == .needsSetup)
		#expect(checksByID["github-auth"]?.detail.contains("authentication is missing or invalid") == true)
	}

	private func ticket(number: Int, labels: [String], assignee: String?) -> TicketDescriptor {
		TicketDescriptor(
			provider: .githubIssues,
			externalID: "\(number)",
			title: "Issue \(number)",
			body: "Body",
			status: .ready,
			labels: labels,
			assignee: assignee,
			priority: .medium,
			webURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/\(number)"),
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 0),
			estimatedComplexity: 1,
			blockedBy: []
		)
	}

	private func dashboardProject() -> Project {
		Project(
			name: "Dashboard Project",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
	}

	private func dashboardTicket(projectID: UUID, externalID: String, status: TicketStatus) -> TicketRecord {
		TicketRecord(
			provider: .githubIssues,
			externalID: externalID,
			title: "Issue \(externalID)",
			body: "Body",
			status: status,
			labels: ["dashboard"],
			assignee: nil,
			priority: .medium,
			webURL: "https://github.com/charliewilco/Auditorium/issues/\(externalID)",
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 0),
			estimatedComplexity: 1,
			sourceProjectID: projectID
		)
	}

	private func dashboardPreflight(enabledIssueCount: Int, checks: [RunPreflightSummary.Check]) -> RunPreflightSummary {
		RunPreflightSummary(
			repositoryName: "charliewilco/Auditorium",
			issueCount: enabledIssueCount,
			enabledIssueCount: enabledIssueCount,
			branchPrefix: "auditorium",
			validationCommand: "swift test",
			opensPullRequests: true,
			workspaceRoot: "/tmp/auditorium/workspaces",
			accountTitle: "GitHub",
			scopeSummary: "repo, read:user",
			checks: checks
		)
	}

	private static let fastGitHubRetryPolicy = GitHubAPIRetryPolicy(maxRetries: 3, baseDelay: .milliseconds(1), maxDelay: .milliseconds(1))

	private static let githubRepositoriesPayload = """
		[
			{
				"name": "Auditorium",
				"full_name": "charliewilco/Auditorium",
				"clone_url": "https://github.com/charliewilco/Auditorium.git",
				"html_url": "https://github.com/charliewilco/Auditorium",
				"default_branch": "main",
				"owner": { "login": "charliewilco" }
			}
		]
		"""
}

private struct MockGitHubTransport: GitHubAPITransport {
	let payload: String
	let statusCode: Int
	let headers: [String: String]

	init(payload: String, statusCode: Int = 200, headers: [String: String] = [:]) {
		self.payload = payload
		self.statusCode = statusCode
		self.headers = headers
	}

	func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
		return (Data(payload.utf8), response)
	}
}

private enum ScriptedGitHubTransportResult: Sendable {
	case response(statusCode: Int, payload: String, headers: [String: String] = [:])
	case urlError(URLError)
}

private actor ScriptedGitHubTransport: GitHubAPITransport {
	private var results: [ScriptedGitHubTransportResult]
	private var calls = 0

	init(results: [ScriptedGitHubTransportResult]) {
		self.results = results
	}

	func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		calls += 1
		let result = results.isEmpty ? .response(statusCode: 500, payload: "{}") : results.removeFirst()
		switch result {
		case .response(let statusCode, let payload, let headers):
			let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
			return (Data(payload.utf8), response)
		case .urlError(let error):
			throw error
		}
	}

	func callCount() -> Int {
		calls
	}
}

private actor GitHubRetrySleepRecorder {
	private var recordedDurations: [Duration] = []

	func record(_ duration: Duration) {
		recordedDurations.append(duration)
	}

	func durations() -> [Duration] {
		recordedDurations
	}
}

private struct StaticCoreIssueTrackerProvider: IssueTrackerProvider {
	let tickets: [TicketDescriptor]

	var kind: IssueProviderKind { .githubIssues }
	var authentication: ProviderAuthenticationDescriptor {
		ProviderAuthenticationDescriptor(method: .oauth, displayName: "Test GitHub", oauth: GitHubOAuth.descriptor)
	}

	func listTickets(projectID: String) async throws -> [TicketDescriptor] {
		tickets
	}

	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws {}

	func addComment(ticketID: String, body: String) async throws {}
}
