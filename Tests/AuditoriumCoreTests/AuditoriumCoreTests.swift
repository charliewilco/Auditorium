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

	@Test func projectRunSupervisorOwnsQueueFillProviderRequirement() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumSupervisorTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let project = Project(
			name: "Supervisor Queue Fill",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		context.insert(project)
		try context.save()
		let supervisor = ProjectRunSupervisor(
			workspaceService: ApplicationWorkspaceService(rootDirectory: root),
			runtimeDetection: RuntimeDetectionService(staticChecks: []),
			reportGenerator: ReportGenerator()
		)

		do {
			_ = try await supervisor.fillQueue(project: project, context: context)
			Issue.record("Expected queue fill to require an issue provider registry.")
		}
		catch let error as ProviderError {
			#expect(error.localizedDescription == "An issue provider is required to fill the queue.")
		}
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

	@Test func orchestrationRunPlanBatchesRespectConcurrencyGroups() {
		let projectID = UUID()
		let firstUI = QueueItemRecord(ticketID: UUID(), projectID: projectID, position: 0, priority: .high, concurrencyGroup: "ui")
		let secondUI = QueueItemRecord(ticketID: UUID(), projectID: projectID, position: 1, priority: .high, concurrencyGroup: "ui")
		let firstBackend = QueueItemRecord(
			ticketID: UUID(),
			projectID: projectID,
			position: 2,
			priority: .medium,
			concurrencyGroup: "backend"
		)
		let docs = QueueItemRecord(ticketID: UUID(), projectID: projectID, position: 3, priority: .low, concurrencyGroup: "docs")
		let secondBackend = QueueItemRecord(
			ticketID: UUID(),
			projectID: projectID,
			position: 4,
			priority: .medium,
			concurrencyGroup: "backend"
		)

		let plan = OrchestrationRunPlan.make(
			queueItems: [firstUI, secondUI, firstBackend, docs, secondBackend],
			requestedConcurrency: 3,
			workflowPolicyMarkdown: WorkflowPolicy.defaultMarkdown
		)

		#expect(
			plan.queueSnapshot.map(\.ticketID) == [
				firstUI.ticketID,
				secondUI.ticketID,
				firstBackend.ticketID,
				docs.ticketID,
				secondBackend.ticketID,
			]
		)
		#expect(
			plan.batches.map { $0.map(\.ticketID) } == [
				[firstUI.ticketID, firstBackend.ticketID, docs.ticketID],
				[secondUI.ticketID, secondBackend.ticketID],
			]
		)
		#expect(plan.batches.allSatisfy { batch in Set(batch.map(\.concurrencyGroup)).count == batch.count })
	}

	@Test func ticketDispatcherSkipsIneligibleTicketsAndKeepsQueueOrder() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let now = Date(timeIntervalSince1970: 100)
		let project = Project(
			name: "Dispatcher",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent,
			workflowPolicyMarkdown: """
				---
				concurrency: 2
				max_retries: 2
				max_retry_backoff_ms: 8000
				branch_prefix: "auditorium"
				run_tests: false
				open_pull_request: false
				---
				Run the ticket.
				"""
		)
		let first = ticketRecord(projectID: project.id, externalID: "1", status: .ready, priority: .medium)
		let tieBreaker = ticketRecord(projectID: project.id, externalID: "2", status: .ready, priority: .urgent)
		let blocked = ticketRecord(projectID: project.id, externalID: "3", status: .ready, blockedBy: ["9"])
		let blocker = ticketRecord(projectID: project.id, externalID: "9", status: .ready)
		let terminal = ticketRecord(projectID: project.id, externalID: "4", status: .completed)
		let active = ticketRecord(projectID: project.id, externalID: "5", status: .running)
		let retryBackoff = ticketRecord(projectID: project.id, externalID: "6", status: .failed)
		let retryLimit = ticketRecord(projectID: project.id, externalID: "7", status: .failed)
		let disabled = ticketRecord(projectID: project.id, externalID: "8", status: .ready)

		context.insert(project)
		[first, tieBreaker, blocked, blocker, terminal, active, retryBackoff, retryLimit, disabled].forEach(context.insert)
		context.insert(
			QueueItemRecord(ticketID: first.id, projectID: project.id, position: 0, priority: .medium, createdAt: now)
		)
		context.insert(
			QueueItemRecord(ticketID: tieBreaker.id, projectID: project.id, position: 0, priority: .urgent, createdAt: now)
		)
		context.insert(QueueItemRecord(ticketID: blocked.id, projectID: project.id, position: 1, priority: .high))
		context.insert(QueueItemRecord(ticketID: terminal.id, projectID: project.id, position: 2, priority: .high))
		context.insert(QueueItemRecord(ticketID: active.id, projectID: project.id, position: 3, priority: .medium))
		context.insert(QueueItemRecord(ticketID: retryBackoff.id, projectID: project.id, position: 4, priority: .medium))
		context.insert(QueueItemRecord(ticketID: retryLimit.id, projectID: project.id, position: 5, priority: .medium))
		context.insert(QueueItemRecord(ticketID: disabled.id, projectID: project.id, position: 6, priority: .low, isEnabled: false))
		context.insert(TicketRunRecord(runID: UUID(), ticketID: active.id, status: .running, startedAt: now.addingTimeInterval(-10)))
		context.insert(
			TicketRunRecord(
				runID: UUID(),
				ticketID: retryBackoff.id,
				status: .failed,
				endedAt: now.addingTimeInterval(-0.5),
				retryCount: 1
			)
		)
		context.insert(
			TicketRunRecord(runID: UUID(), ticketID: retryLimit.id, status: .failed, endedAt: now.addingTimeInterval(-10), retryCount: 3)
		)
		try context.save()

		let plan = try TicketDispatcherService().makeDispatchPlan(project: project, requestedConcurrency: 0, context: context, now: now)

		#expect(plan.orchestrationPlan.concurrency == 2)
		#expect(plan.orchestrationPlan.queueSnapshot.map(\.ticketID) == [tieBreaker.id, first.id])
		#expect(
			plan.skippedItems.map(\.reason) == [
				.unresolvedBlocker,
				.terminalTicket,
				.alreadyRunning,
				.retryBackoff,
				.retryLimitReached,
				.disabled,
			]
		)
	}

	@Test func ticketDispatcherUsesRetryPolicyForPreviouslyFailedRuns() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let now = Date(timeIntervalSince1970: 100)
		let project = Project(
			name: "No Retry Dispatcher",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent,
			workflowPolicyMarkdown: """
				---
				concurrency: 1
				max_retries: 0
				branch_prefix: "auditorium"
				run_tests: false
				open_pull_request: false
				---
				Run the ticket.
				"""
		)
		let failedTicket = ticketRecord(projectID: project.id, externalID: "10", status: .failed, priority: .high)
		context.insert(project)
		context.insert(failedTicket)
		context.insert(QueueItemRecord(ticketID: failedTicket.id, projectID: project.id, position: 0, priority: .high))
		context.insert(
			TicketRunRecord(
				runID: UUID(),
				ticketID: failedTicket.id,
				status: .failed,
				endedAt: now.addingTimeInterval(-10),
				retryCount: 1
			)
		)
		try context.save()

		let plan = try TicketDispatcherService().makeDispatchPlan(project: project, requestedConcurrency: 1, context: context, now: now)

		#expect(plan.orchestrationPlan.queueSnapshot.isEmpty)
		#expect(plan.skippedItems.map(\.reason) == [.retryLimitReached])
		#expect(plan.skippedItems.first?.detail == "Retry count 1 is not eligible under max retries 0.")
	}

	@Test func orchestratorPersistsDispatcherSkipEventsInRunJournal() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCoreTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let project = Project(
			name: "Dispatcher Journal",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent,
			workflowPolicyMarkdown: """
				---
				concurrency: 1
				max_retries: 0
				branch_prefix: "auditorium"
				run_tests: false
				open_pull_request: false
				---
				Run the ticket.
				"""
		)
		let runnable = ticketRecord(projectID: project.id, externalID: "21", status: .ready)
		let blocked = ticketRecord(projectID: project.id, externalID: "22", status: .blocked)
		context.insert(project)
		context.insert(runnable)
		context.insert(blocked)
		context.insert(QueueItemRecord(ticketID: runnable.id, projectID: project.id, position: 0, priority: .medium))
		context.insert(QueueItemRecord(ticketID: blocked.id, projectID: project.id, position: 1, priority: .medium))
		try context.save()
		let orchestrator = Orchestrator(
			workspaceService: ApplicationWorkspaceService(rootDirectory: root),
			runtimeDetection: RuntimeDetectionService(staticChecks: []),
			reportGenerator: ReportGenerator(),
			mockAgentProvider: InstantAgentProvider()
		)

		try await orchestrator.execute(projectID: project.id, concurrency: 1, context: context)

		let run = try #require(context.fetch(FetchDescriptor<RunRecord>()).first)
		let ticketRuns = try context.fetch(FetchDescriptor<TicketRunRecord>())
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>()).filter { $0.runID == run.id }

		#expect(run.totalTickets == 1)
		#expect(run.queueSnapshot.map(\.ticketID) == [runnable.id])
		#expect(ticketRuns.map(\.ticketID) == [runnable.id])
		#expect(events.contains { $0.message == "Dispatcher selected 1 ticket runs and skipped 1." })
		#expect(events.contains { $0.message == "Dispatcher skipped queue item: Blocked Ticket." })
	}

	@Test func orchestratorCancellationPersistsReportAndQueuesReportBack() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCancellationTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let project = Project(
			name: "Cancellation Journal",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent,
			workflowPolicyMarkdown: """
				---
				concurrency: 1
				branch_prefix: "auditorium"
				run_tests: false
				open_pull_request: false
				---
				Run the ticket.
				"""
		)
		let ticket = ticketRecord(projectID: project.id, externalID: "23", status: .ready)
		context.insert(project)
		context.insert(ticket)
		context.insert(QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .medium))
		try context.save()
		let orchestrator = Orchestrator(
			workspaceService: ApplicationWorkspaceService(rootDirectory: root),
			runtimeDetection: RuntimeDetectionService(staticChecks: []),
			reportGenerator: ReportGenerator(),
			mockAgentProvider: CancelingAgentProvider()
		)

		try await orchestrator.execute(projectID: project.id, concurrency: 1, context: context)

		let run = try #require(context.fetch(FetchDescriptor<RunRecord>()).first)
		let ticketRun = try #require(context.fetch(FetchDescriptor<TicketRunRecord>()).first)
		let report = try #require(context.fetch(FetchDescriptor<ReportRecord>()).first)
		let reportBack = try #require(context.fetch(FetchDescriptor<TicketReportBackRecord>()).first)
		let dispatcher = try #require(context.fetch(FetchDescriptor<DispatcherRunRecord>()).first)
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>()).filter { $0.runID == run.id }

		#expect(run.status == .canceled)
		#expect(run.summary == "Run canceled by user.")
		#expect(run.reportMarkdown.contains("Run canceled by user."))
		#expect(ticket.status == .canceled)
		#expect(ticketRun.status == .canceled)
		#expect(ticketRun.lifecyclePhase == .reportBackPending)
		#expect(ticketRun.failedPhase == .running)
		#expect(report.runID == run.id)
		#expect(FileManager.default.fileExists(atPath: report.filePath))
		#expect(reportBack.ticketRunID == ticketRun.id)
		#expect(reportBack.status == .pending)
		#expect(reportBack.externalTicketID == "23")
		#expect(dispatcher.status == .canceled)
		#expect(dispatcher.resumeAction == "Review canceled ticket runs before requeueing.")
		#expect(events.contains { $0.message == "Run canceled by user." })
		#expect(events.contains { $0.message == "ticket_report_back_queued" && $0.ticketRunID == ticketRun.id })
	}

	@Test func orchestratorCancellationStopsLocalRuntimeHandle() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumLocalRuntimeStop-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let project = Project(
			name: "Local Runtime Stop",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex,
			workflowPolicyMarkdown: """
				---
				concurrency: 1
				branch_prefix: "auditorium"
				run_tests: false
				open_pull_request: false
				---
				Run the ticket.
				"""
		)
		let ticket = ticketRecord(projectID: project.id, externalID: "24", status: .ready)
		context.insert(project)
		context.insert(ticket)
		context.insert(QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .medium))
		try context.save()
		let orchestrator = Orchestrator(
			workspaceService: ApplicationWorkspaceService(rootDirectory: root),
			runtimeDetection: RuntimeDetectionService(staticChecks: [
				RuntimeHealthCheck(id: "git", name: "Git", state: .available, detail: "/usr/bin/git", version: nil),
				RuntimeHealthCheck(
					id: "codex",
					name: "Codex CLI",
					state: .available,
					detail: "/opt/homebrew/bin/codex",
					version: nil
				),
			]),
			reportGenerator: ReportGenerator(),
			localWorkspaceSourceProvider: TestSourceCodeProvider(),
			codexAgentProvider: CancelingAgentProvider()
		)

		try await orchestrator.execute(projectID: project.id, concurrency: 1, context: context)

		let run = try #require(context.fetch(FetchDescriptor<RunRecord>()).first)
		let ticketRun = try #require(context.fetch(FetchDescriptor<TicketRunRecord>()).first)
		let stoppedMarker = URL(fileURLWithPath: ticketRun.workspacePath).appending(path: ".auditorium/runtime-stopped")
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>()).filter { $0.runID == run.id }

		#expect(ticketRun.status == .canceled)
		#expect(FileManager.default.fileExists(atPath: stoppedMarker.path()))
		#expect(events.contains { $0.message == "Runtime handle \(ticketRun.runtimeID) stopped." })
	}

	@Test func containerWorkspaceRuntimeStopKillsNamedContainerAndWritesReceipt() async throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumContainerRuntimeStop-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let projectID = UUID()
		let workspaceService = ApplicationWorkspaceService(rootDirectory: root)
		let runner = RecordingContainerCommandRunner(result: ProcessResult(exitCode: 0, standardOutput: "", standardError: ""))
		let runtime = ContainerWorkspaceRuntimeProvider(
			workspaceService: workspaceService,
			projectID: projectID,
			sourceProvider: TestSourceCodeProvider(),
			containerControl: ContainerRuntimeControl(
				executablePath: "/bin/container-test",
				asyncCommandRunner: { executable, arguments, allowsNonZeroExit in
					try await runner.run(executable: executable, arguments: arguments, allowsNonZeroExit: allowsNonZeroExit)
				}
			)
		)
		let ticket = TicketDescriptor(
			provider: .githubIssues,
			externalID: "ISSUE-77",
			title: "Stop Container Runtime",
			body: "Stop the named container.",
			status: .ready,
			labels: ["runtime"],
			assignee: nil,
			priority: .medium,
			webURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/77"),
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 2,
			blockedBy: []
		)
		let repository = RepositoryDescriptor(
			provider: .github,
			owner: "charliewilco",
			name: "Auditorium",
			fullName: "charliewilco/Auditorium",
			cloneURL: URL(string: "https://github.com/charliewilco/Auditorium.git")!,
			webURL: URL(string: "https://github.com/charliewilco/Auditorium")!,
			defaultBranch: "main"
		)

		let workspace = try await runtime.prepareWorkspace(for: ticket, repository: repository)
		let handle = try await runtime.startExecution(
			RuntimeExecutionRequest(ticket: ticket, workspace: workspace, policyMarkdown: WorkflowPolicy.defaultMarkdown)
		)
		try await runtime.stopExecution(handle: handle)

		let calls = await runner.recordedCalls()
		let receiptURL = workspace.path.appending(path: ".auditorium/container-runtime-stopped")
		let receipt = try #require(
			try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any]
		)
		let containerName = ContainerizedCodexAgentProvider.containerName(forRuntimeID: "container-issue-77")

		#expect(calls.map(\.executable) == ["/bin/container-test"])
		#expect(calls.map(\.arguments) == [["container", "kill", containerName]])
		#expect(receipt["id"] as? String == "container-issue-77")
		#expect(receipt["containerName"] as? String == containerName)
		#expect(receipt["workspacePath"] as? String == workspace.path.path())
		#expect(receipt["killExitCode"] as? Int == 0)
		#expect(receipt["killFailureReason"] == nil)
	}

	@Test func containerWorkspaceRuntimeStopRecordsKillFailureWithoutThrowing() async throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumContainerRuntimeStopFailure-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let runner = RecordingContainerCommandRunner(error: ProviderError.unavailable("container cli unavailable"))
		let runtime = ContainerWorkspaceRuntimeProvider(
			workspaceService: ApplicationWorkspaceService(rootDirectory: root),
			projectID: UUID(),
			sourceProvider: TestSourceCodeProvider(),
			containerControl: ContainerRuntimeControl(
				executablePath: "/bin/container-test",
				asyncCommandRunner: { executable, arguments, allowsNonZeroExit in
					try await runner.run(executable: executable, arguments: arguments, allowsNonZeroExit: allowsNonZeroExit)
				}
			)
		)
		let workspace = root.appending(path: "workspace")
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		let handle = RuntimeExecutionHandle(id: "container-issue-78", workspacePath: workspace)

		try await runtime.stopExecution(handle: handle)

		let calls = await runner.recordedCalls()
		let receiptURL = workspace.appending(path: ".auditorium/container-runtime-stopped")
		let receipt = try #require(
			try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any]
		)
		let containerName = ContainerizedCodexAgentProvider.containerName(forRuntimeID: "container-issue-78")

		#expect(calls.map(\.arguments) == [["container", "kill", containerName]])
		#expect(receipt["containerName"] as? String == containerName)
		#expect(receipt["killExitCode"] == nil)
		#expect(receipt["killFailureReason"] as? String == "container cli unavailable")
	}

	@Test func containerRuntimeControlCentralizesContainerCLICommands() async throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumContainerRuntimeControl-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let runner = RecordingContainerCommandRunner(result: ProcessResult(exitCode: 0, standardOutput: "", standardError: ""))
		let control = ContainerRuntimeControl(
			executablePath: "/bin/container-test",
			asyncCommandRunner: { executable, arguments, allowsNonZeroExit in
				try await runner.run(executable: executable, arguments: arguments, allowsNonZeroExit: allowsNonZeroExit)
			}
		)

		let killResult = await control.killContainer(named: "auditorium-container-1")
		let imageExists = try await control.imageExists(named: "localhost/auditorium-codex:test")
		try await control.buildImage(named: "localhost/auditorium-codex:test", context: root)

		let calls = await runner.recordedCalls()

		#expect(killResult.result?.exitCode == 0)
		#expect(imageExists)
		#expect(
			calls == [
				RecordingContainerCommandRunner.Call(
					executable: "/bin/container-test",
					arguments: ["container", "kill", "auditorium-container-1"],
					allowsNonZeroExit: true
				),
				RecordingContainerCommandRunner.Call(
					executable: "/bin/container-test",
					arguments: ["container", "image", "inspect", "localhost/auditorium-codex:test"],
					allowsNonZeroExit: true
				),
				RecordingContainerCommandRunner.Call(
					executable: "/bin/container-test",
					arguments: ["container", "build", "--tag", "localhost/auditorium-codex:test", root.path()],
					allowsNonZeroExit: false
				),
			]
		)
		#expect(ContainerRuntimeControl.containerName(forRuntimeID: "Container ISSUE_99") == "auditorium-container-issue-99")
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

	@Test func queueFillRefreshesProviderTicketsAndQueuesNextEligibleTicketsInPriorityOrder() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Queue Fill",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let prequeued = TicketRecord(
			provider: .githubIssues,
			externalID: "2",
			title: "Existing urgent",
			body: "Already queued.",
			status: .queued,
			labels: [],
			assignee: nil,
			priority: .urgent,
			webURL: "https://github.com/charliewilco/Auditorium/issues/2",
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 1),
			estimatedComplexity: 1,
			sourceProjectID: project.id
		)
		context.insert(project)
		context.insert(prequeued)
		context.insert(QueueItemRecord(ticketID: prequeued.id, projectID: project.id, position: 0, priority: .urgent))
		try context.save()
		let provider = StaticCoreIssueTrackerProvider(tickets: [
			ticket(number: 1, labels: ["ready"], assignee: nil, priority: .high, updatedAt: 10),
			ticket(number: 2, labels: ["ready"], assignee: nil, priority: .urgent, updatedAt: 1),
			ticket(number: 3, labels: ["ready"], assignee: nil, priority: .high, updatedAt: 20),
			ticket(number: 4, labels: ["done"], assignee: nil, status: .completed, priority: .urgent, updatedAt: 30),
			ticket(number: 5, labels: ["ready"], assignee: nil, priority: .medium, updatedAt: 40),
			ticket(number: 6, labels: ["ready"], assignee: nil, priority: .low, updatedAt: 50),
		])

		let result = try await QueueFillService().queueNextTickets(for: project, limit: 3, context: context, provider: provider)
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		let queueItems = try context.fetch(FetchDescriptor<QueueItemRecord>()).sorted { $0.position < $1.position }
		let queuedExternalIDs = queueItems.compactMap { item in
			tickets.first { $0.id == item.ticketID }?.externalID
		}

		#expect(result == QueueFillResult(queuedCount: 3, skippedCount: 1, alreadyQueuedCount: 1))
		#expect(queuedExternalIDs == ["2", "3", "1", "5"])
		#expect(tickets.first { $0.externalID == "2" }?.title == "Issue 2")
		#expect(tickets.first { $0.externalID == "2" }?.status == .queued)
		#expect(tickets.first { $0.externalID == "4" }?.status == .completed)
	}

	@Test func queueFillHonorsCapacityExcludedLabelsAndBlockedMetadata() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Queue Fill Policy",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let existing = ticketRecord(projectID: project.id, externalID: "10", status: .queued)
		context.insert(project)
		context.insert(existing)
		context.insert(QueueItemRecord(ticketID: existing.id, projectID: project.id, position: 0, priority: .medium))
		try context.save()
		let blocked = ticket(number: 11, labels: ["ready"], assignee: nil, priority: .urgent, updatedAt: 11, blockedBy: ["10"])
		let manual = ticket(number: 12, labels: ["manual"], assignee: nil, priority: .urgent, updatedAt: 12)
		let first = ticket(number: 13, labels: ["ready"], assignee: nil, priority: .high, updatedAt: 13)
		let second = ticket(number: 14, labels: ["ready"], assignee: nil, priority: .medium, updatedAt: 14)
		let provider = StaticCoreIssueTrackerProvider(tickets: [blocked, manual, first, second])

		let result = try await QueueFillService().queueNextTickets(
			for: project,
			policy: QueueFillPolicy(limit: 12, maxQueueDepth: 2),
			context: context,
			provider: provider
		)
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		let queueItems = try context.fetch(FetchDescriptor<QueueItemRecord>()).sorted { $0.position < $1.position }
		let queuedExternalIDs = queueItems.compactMap { item in
			tickets.first { $0.id == item.ticketID }?.externalID
		}

		#expect(result == QueueFillResult(queuedCount: 1, skippedCount: 1, alreadyQueuedCount: 1))
		#expect(queuedExternalIDs == ["10", "13"])
		#expect(tickets.first { $0.externalID == "11" }?.status == .ready)
		#expect(tickets.first { $0.externalID == "12" }?.status == .ready)
	}

	@Test func ticketReportBackPublishesSuccessCommentAndHandoffLabel() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Report Back",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let ticket = ticketRecord(projectID: project.id, externalID: "42", status: .needsReview)
		let run = RunRecord(projectID: project.id, status: .completed, totalTickets: 1, completedTickets: 1)
		run.workflowPolicySnapshotMarkdown = """
			---
			handoff_status: "Needs Review"
			---
			Implement safely.
			"""
		let ticketRun = TicketRunRecord(
			runID: run.id,
			ticketID: ticket.id,
			branchName: "auditorium/42",
			status: .needsReview,
			lifecyclePhase: .reportBackPending,
			pullRequestURL: "https://github.com/charliewilco/Auditorium/pull/42",
			summary: "Implemented safely."
		)
		let pullRequest = PullRequestRecord(
			provider: .github,
			ticketRunID: ticketRun.id,
			title: "42: Report Back",
			url: "https://github.com/charliewilco/Auditorium/pull/42",
			branchName: "auditorium/42",
			targetBranch: "main",
			status: .open,
			checksStatus: .pending
		)
		let provider = RecordingIssueTrackerProvider(
			commentURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/42#issuecomment-1")
		)
		context.insert(project)
		context.insert(ticket)
		context.insert(run)
		context.insert(ticketRun)
		context.insert(pullRequest)
		try context.save()

		await TicketReportBackService().publishTerminalTicketRuns(
			project: project,
			run: run,
			ticketRuns: [ticketRun],
			tickets: [ticket],
			pullRequests: [pullRequest],
			policy: try WorkflowPolicyParser().parse(run.workflowPolicySnapshotMarkdown),
			provider: provider,
			context: context
		)

		let attempts = try context.fetch(FetchDescriptor<TicketReportBackRecord>())
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())
		let completedEvent = try #require(events.first { $0.message == "ticket_report_back_completed" })
		#expect(provider.comments.map(\.ticketID) == ["42"])
		#expect(provider.comments.first?.body.contains("Pull request: https://github.com/charliewilco/Auditorium/pull/42") == true)
		#expect(provider.comments.first?.body.contains(ticketRun.logPath) == false)
		#expect(provider.labels.count == 1)
		#expect(provider.labels.first?.0 == "42")
		#expect(provider.labels.first?.1 == ["Needs Review"])
		#expect(attempts.first?.status == .succeeded)
		#expect(attempts.first?.attemptCount == 1)
		#expect(attempts.first?.commentURL == "https://github.com/charliewilco/Auditorium/issues/42#issuecomment-1")
		#expect(ticketRun.lifecyclePhase == .reviewReady)
		#expect(completedEvent.metadataJSON.contains(#""status":"succeeded""#))
		#expect(completedEvent.metadataJSON.contains(#""attemptCount":1"#))
		#expect(completedEvent.metadataJSON.contains(#""externalTicketID":"42""#))
		#expect(
			completedEvent.metadataJSON.contains(
				#""commentURL":"https:\/\/github.com\/charliewilco\/Auditorium\/issues\/42#issuecomment-1""#
			)
		)
		#expect(events.contains { $0.message == "ticket_lifecycle_transition" })
	}

	@Test func ticketReportBackCommentRedactsLocalPathsAndSensitiveFreeFormText() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Safe Report Back",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let ticket = ticketRecord(projectID: project.id, externalID: "49", status: .failed)
		let run = RunRecord(projectID: project.id, status: .completedWithFailures, totalTickets: 1, failedTickets: 1)
		let ticketRun = TicketRunRecord(
			runID: run.id,
			ticketID: ticket.id,
			status: .failed,
			lifecyclePhase: .reportBackPending,
			failedPhase: .running,
			summary: "Report at /tmp/auditorium/report.md with GH_TOKEN=ghs_secret.",
			failureReason: "Codex auth was at /Users/charlie/.codex/auth.json and OPENAI_API_KEY=sk-secret."
		)
		let provider = RecordingIssueTrackerProvider()
		context.insert(project)
		context.insert(ticket)
		context.insert(run)
		context.insert(ticketRun)
		try context.save()

		await TicketReportBackService().publishTerminalTicketRuns(
			project: project,
			run: run,
			ticketRuns: [ticketRun],
			tickets: [ticket],
			pullRequests: [],
			policy: ParsedWorkflowPolicy.defaultPolicy(),
			provider: provider,
			context: context
		)

		let body = try #require(provider.comments.first?.body)
		#expect(body.contains("[local path redacted]"))
		#expect(body.contains("[sensitive value redacted]"))
		#expect(body.contains("/Users/charlie") == false)
		#expect(body.contains("/tmp/auditorium") == false)
		#expect(body.contains("ghs_secret") == false)
		#expect(body.contains("sk-secret") == false)
		#expect(body.contains("auth.json") == false)
		#expect(body.contains("Run: \(run.id.uuidString)"))
	}

	@Test func ticketReportBackPublishesThroughHandoffProviderContract() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Handoff Contract",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let ticket = ticketRecord(projectID: project.id, externalID: "44", status: .needsReview)
		let run = RunRecord(projectID: project.id, status: .completed, totalTickets: 1, completedTickets: 1)
		run.workflowPolicySnapshotMarkdown = """
			---
			handoff_status: "Needs Review"
			update_issue_labels: true
			---
			Implement safely.
			"""
		let ticketRun = TicketRunRecord(
			runID: run.id,
			ticketID: ticket.id,
			branchName: "auditorium/44",
			status: .needsReview,
			lifecyclePhase: .reportBackPending,
			pullRequestURL: "https://github.com/charliewilco/Auditorium/pull/44",
			summary: "Ready for review."
		)
		let handoffProvider = RecordingHandoffProvider(
			receipt: TicketHandoffReceipt(
				commentURL: URL(string: "https://provider.example/tickets/44#handoff")
			)
		)
		context.insert(project)
		context.insert(ticket)
		context.insert(run)
		context.insert(ticketRun)
		try context.save()

		let result = await TicketReportBackService().publishTerminalTicketRuns(
			project: project,
			run: run,
			ticketRuns: [ticketRun],
			tickets: [ticket],
			pullRequests: [],
			policy: try WorkflowPolicyParser().parse(run.workflowPolicySnapshotMarkdown),
			provider: handoffProvider,
			context: context
		)

		let attempt = try #require(context.fetch(FetchDescriptor<TicketReportBackRecord>()).first)
		#expect(result == TicketReportBackSweepResult(attemptedCount: 1, succeededCount: 1, failedCount: 0))
		#expect(handoffProvider.requests.count == 1)
		#expect(handoffProvider.requests.first?.ticketID == "44")
		#expect(handoffProvider.requests.first?.labels == ["Needs Review"])
		#expect(handoffProvider.requests.first?.body.contains("Run: \(run.id.uuidString)") == true)
		#expect(attempt.status == .succeeded)
		#expect(attempt.provider == .githubIssues)
		#expect(attempt.commentURL == "https://provider.example/tickets/44#handoff")
		#expect(ticketRun.lifecyclePhase == .reviewReady)
	}

	@Test func ticketReportBackQueuesPendingOutboxBeforeProviderDelivery() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let now = Date(timeIntervalSince1970: 100)
		let project = Project(
			name: "Pending Outbox",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let completedTicket = ticketRecord(projectID: project.id, externalID: "46", status: .completed)
		let failedTicket = ticketRecord(projectID: project.id, externalID: "47", status: .failed)
		let runningTicket = ticketRecord(projectID: project.id, externalID: "48", status: .running)
		let run = RunRecord(projectID: project.id, status: .completedWithFailures, totalTickets: 3)
		let completedRun = TicketRunRecord(
			runID: run.id,
			ticketID: completedTicket.id,
			status: .completed,
			lifecyclePhase: .reportBackPending
		)
		let failedRun = TicketRunRecord(
			runID: run.id,
			ticketID: failedTicket.id,
			status: .failed,
			lifecyclePhase: .reportBackPending,
			failedPhase: .running,
			failureReason: "Validation failed."
		)
		let runningRun = TicketRunRecord(runID: run.id, ticketID: runningTicket.id, status: .running, lifecyclePhase: .running)
		context.insert(project)
		context.insert(completedTicket)
		context.insert(failedTicket)
		context.insert(runningTicket)
		context.insert(run)
		context.insert(completedRun)
		context.insert(failedRun)
		context.insert(runningRun)
		try ModelIntegrityValidator.save(context: context)

		let queuedCount = try TicketReportBackService().ensurePendingReportBacks(
			run: run,
			ticketRuns: [completedRun, failedRun, runningRun],
			tickets: [completedTicket, failedTicket, runningTicket],
			context: context,
			now: now
		)
		let secondQueuedCount = try TicketReportBackService().ensurePendingReportBacks(
			run: run,
			ticketRuns: [completedRun, failedRun, runningRun],
			tickets: [completedTicket, failedTicket, runningTicket],
			context: context,
			now: now.addingTimeInterval(1)
		)

		let attempts = try context.fetch(FetchDescriptor<TicketReportBackRecord>()).sorted { $0.externalTicketID < $1.externalTicketID }
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())
		#expect(queuedCount == 2)
		#expect(secondQueuedCount == 0)
		#expect(attempts.map(\.externalTicketID) == ["46", "47"])
		#expect(attempts.allSatisfy { $0.status == .pending && $0.attemptCount == 0 })
		#expect(attempts.allSatisfy { $0.provider == .githubIssues })
		#expect(events.filter { $0.message == "ticket_report_back_queued" }.count == 2)
		#expect(
			events.contains { event in
				event.message == "ticket_report_back_queued"
					&& event.metadataJSON.contains(#""status":"pending""#)
					&& event.metadataJSON.contains(#""attemptCount":0"#)
					&& event.metadataJSON.contains(#""externalTicketID":"46""#)
			}
		)
		#expect(failedRun.status == .failed)
		#expect(failedRun.failedPhase == .running)
	}

	@Test func ticketReportBackRecordsProviderFailureWithoutChangingTicketRunState() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Report Back Failure",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let ticket = ticketRecord(projectID: project.id, externalID: "43", status: .failed)
		let run = RunRecord(projectID: project.id, status: .completedWithFailures, totalTickets: 1, failedTickets: 1)
		let ticketRun = TicketRunRecord(
			runID: run.id,
			ticketID: ticket.id,
			status: .failed,
			lifecyclePhase: .failed,
			failedPhase: .running,
			summary: "Validation failed.",
			failureReason: "Tests failed."
		)
		let provider = RecordingIssueTrackerProvider(commentError: ProviderError.unavailable("GitHub comments are unavailable."))
		context.insert(project)
		context.insert(ticket)
		context.insert(run)
		context.insert(ticketRun)
		try context.save()

		await TicketReportBackService().publishTerminalTicketRuns(
			project: project,
			run: run,
			ticketRuns: [ticketRun],
			tickets: [ticket],
			pullRequests: [],
			policy: try WorkflowPolicyParser().parse(WorkflowPolicy.defaultMarkdown),
			provider: provider,
			context: context
		)

		let attempts = try context.fetch(FetchDescriptor<TicketReportBackRecord>())
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())
		let failedEvent = try #require(events.first { $0.message == "ticket_report_back_failed" })
		#expect(provider.comments.count == 1)
		#expect(provider.labels.isEmpty)
		#expect(attempts.first?.status == .failed)
		#expect(attempts.first?.attemptCount == 1)
		#expect(attempts.first?.retryAfter != nil)
		#expect(attempts.first?.failureReason == "GitHub comments are unavailable.")
		#expect(ticket.status == .failed)
		#expect(ticketRun.status == .failed)
		#expect(ticketRun.lifecyclePhase == .reportBackPending)
		#expect(ticketRun.failedPhase == .running)
		#expect(run.status == .completedWithFailures)
		#expect(failedEvent.metadataJSON.contains(#""status":"failed""#))
		#expect(failedEvent.metadataJSON.contains(#""attemptCount":1"#))
		#expect(failedEvent.metadataJSON.contains(#""externalTicketID":"43""#))
		#expect(failedEvent.metadataJSON.contains(#""failureReason":"GitHub comments are unavailable.""#))
	}

	@Test func ticketReportBackRetriesFailedAttemptsAndSkipsSucceededAttempts() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Report Back Retry",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let ticket = ticketRecord(projectID: project.id, externalID: "44", status: .failed)
		let run = RunRecord(projectID: project.id, status: .completedWithFailures, totalTickets: 1, failedTickets: 1)
		let ticketRun = TicketRunRecord(
			runID: run.id,
			ticketID: ticket.id,
			status: .failed,
			lifecyclePhase: .failed,
			failedPhase: .running,
			failureReason: "Interrupted."
		)
		context.insert(project)
		context.insert(ticket)
		context.insert(run)
		context.insert(ticketRun)
		context.insert(
			TicketReportBackRecord(
				ticketRunID: ticketRun.id,
				provider: .githubIssues,
				externalTicketID: "44",
				status: .failed,
				attemptCount: 1,
				attemptedAt: Date(timeIntervalSince1970: 1),
				retryAfter: Date(timeIntervalSince1970: 2),
				failureReason: "network"
			)
		)
		try context.save()
		let provider = RecordingIssueTrackerProvider(
			commentURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/44#issuecomment-2")
		)

		let retryResult = await TicketReportBackService().publishTerminalTicketRuns(
			project: project,
			run: run,
			ticketRuns: [ticketRun],
			tickets: [ticket],
			pullRequests: [],
			policy: ParsedWorkflowPolicy.defaultPolicy(),
			provider: provider,
			context: context
		)
		let skipResult = await TicketReportBackService().publishTerminalTicketRuns(
			project: project,
			run: run,
			ticketRuns: [ticketRun],
			tickets: [ticket],
			pullRequests: [],
			policy: ParsedWorkflowPolicy.defaultPolicy(),
			provider: provider,
			context: context
		)

		let attempts = try context.fetch(FetchDescriptor<TicketReportBackRecord>())
		#expect(retryResult == TicketReportBackSweepResult(attemptedCount: 1, succeededCount: 1, failedCount: 0))
		#expect(skipResult == TicketReportBackSweepResult(attemptedCount: 0, succeededCount: 0, failedCount: 0))
		#expect(provider.comments.count == 1)
		#expect(attempts.count == 1)
		#expect(attempts.first?.status == .succeeded)
		#expect(attempts.first?.attemptCount == 2)
		#expect(ticketRun.status == .failed)
		#expect(ticketRun.lifecyclePhase == .reviewReady)
		#expect(ticketRun.failedPhase == .running)
	}

	@Test func ticketReportBackSkipsFreshInFlightAttemptsAndRetriesStaleAttempts() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let now = Date(timeIntervalSince1970: 1_000)
		let project = Project(
			name: "Report Back Lease",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let ticket = ticketRecord(projectID: project.id, externalID: "45", status: .needsReview)
		let run = RunRecord(projectID: project.id, status: .completed, totalTickets: 1, completedTickets: 1)
		let ticketRun = TicketRunRecord(runID: run.id, ticketID: ticket.id, status: .needsReview, lifecyclePhase: .reportBackPending)
		let attempt = TicketReportBackRecord(
			ticketRunID: ticketRun.id,
			provider: .githubIssues,
			externalTicketID: "45",
			status: .inFlight,
			attemptCount: 1,
			attemptedAt: now.addingTimeInterval(-10),
			inFlightStartedAt: now.addingTimeInterval(-10)
		)
		context.insert(project)
		context.insert(ticket)
		context.insert(run)
		context.insert(ticketRun)
		context.insert(attempt)
		try context.save()
		let provider = RecordingIssueTrackerProvider()
		let service = TicketReportBackService(inFlightTimeout: 300)

		let freshResult = await service.publishTerminalTicketRuns(
			project: project,
			run: run,
			ticketRuns: [ticketRun],
			tickets: [ticket],
			pullRequests: [],
			policy: ParsedWorkflowPolicy.defaultPolicy(),
			provider: provider,
			context: context,
			now: now
		)
		attempt.inFlightStartedAt = now.addingTimeInterval(-301)
		attempt.updatedAt = now.addingTimeInterval(-301)
		let staleResult = await service.publishTerminalTicketRuns(
			project: project,
			run: run,
			ticketRuns: [ticketRun],
			tickets: [ticket],
			pullRequests: [],
			policy: ParsedWorkflowPolicy.defaultPolicy(),
			provider: provider,
			context: context,
			now: now
		)

		#expect(freshResult == TicketReportBackSweepResult(attemptedCount: 0, succeededCount: 0, failedCount: 0))
		#expect(staleResult == TicketReportBackSweepResult(attemptedCount: 1, succeededCount: 1, failedCount: 0))
		#expect(provider.comments.count == 1)
		#expect(attempt.status == .succeeded)
		#expect(attempt.attemptCount == 2)
		#expect(attempt.inFlightStartedAt == nil)
		#expect(ticketRun.lifecyclePhase == .reviewReady)
	}

	@Test func resumeAfterLaunchRetriesDueReportBacksWithoutRunReconciliation() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let now = Date(timeIntervalSince1970: 100)
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumReportBackResume-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let project = Project(
			name: "Report-back Resume",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .imported,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let ticket = TicketRecord(
			provider: .imported,
			externalID: "88",
			title: "Retry handoff",
			body: "Body",
			status: .completed,
			labels: [],
			assignee: nil,
			priority: .medium,
			webURL: "https://github.com/charliewilco/Auditorium/issues/88",
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 1),
			estimatedComplexity: 1,
			sourceProjectID: project.id
		)
		let run = RunRecord(
			projectID: project.id,
			status: .completed,
			totalTickets: 1,
			workflowPolicySnapshotMarkdown: """
				---
				concurrency: 1
				branch_prefix: "auditorium"
				run_tests: false
				open_pull_request: false
				---
				Report back only.
				"""
		)
		let ticketRun = TicketRunRecord(
			runID: run.id,
			ticketID: ticket.id,
			branchName: "auditorium/88",
			status: .completed,
			lifecyclePhase: .reportBackPending,
			endedAt: Date(timeIntervalSince1970: 80),
			summary: "Completed locally."
		)
		let attempt = TicketReportBackRecord(
			ticketRunID: ticketRun.id,
			provider: .imported,
			externalTicketID: ticket.externalID,
			status: .failed,
			attemptCount: 1,
			attemptedAt: Date(timeIntervalSince1970: 80),
			retryAfter: Date(timeIntervalSince1970: 90),
			failureReason: "Temporary provider failure.",
			updatedAt: Date(timeIntervalSince1970: 80)
		)
		context.insert(project)
		context.insert(ticket)
		context.insert(run)
		context.insert(ticketRun)
		context.insert(attempt)
		try ModelIntegrityValidator.save(context: context)
		let supervisor = ProjectRunSupervisor(
			workspaceService: ApplicationWorkspaceService(rootDirectory: root),
			runtimeDetection: RuntimeDetectionService(staticChecks: []),
			reportGenerator: ReportGenerator(),
			providerRegistry: ProviderRegistry(
				keychainService: KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
			)
		)

		let result = try await supervisor.resumeAfterLaunch(context: context, now: now)
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())

		#expect(result.reconciledRuns == 0)
		#expect(result.reconciledTicketRuns == 0)
		#expect(attempt.status == .succeeded)
		#expect(attempt.attemptCount == 2)
		#expect(attempt.retryAfter == nil)
		#expect(attempt.inFlightStartedAt == nil)
		#expect(ticketRun.lifecyclePhase == .reviewReady)
		#expect(events.contains { $0.message == "ticket_report_back_started" })
		#expect(events.contains { $0.message == "ticket_report_back_completed" })
	}

	@Test func runRecordPersistsQueueSnapshotJSON() {
		let first = QueueRunSnapshot(id: UUID(), ticketID: UUID(), position: 0, priority: .high, concurrencyGroup: "ui")
		let second = QueueRunSnapshot(id: UUID(), ticketID: UUID(), position: 1, priority: .low, concurrencyGroup: "backend")
		let run = RunRecord(projectID: UUID())

		run.queueSnapshot = [first, second]

		#expect(run.queueSnapshotJSON.contains(first.ticketID.uuidString))
		#expect(run.queueSnapshot == [first, second])
	}

	@Test func ticketRunLifecycleServicePersistsPhaseFailurePhaseAndStructuredEvents() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let runID = UUID()
		let ticketRun = TicketRunRecord(runID: runID, ticketID: UUID())
		context.insert(ticketRun)

		TicketRunLifecycleService().transition(ticketRun, to: .preparing, runID: runID, context: context, reason: "workspace")
		TicketRunLifecycleService().fail(ticketRun, runID: runID, context: context, reason: "validation")
		try ModelIntegrityValidator.save(context: context)

		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())
		#expect(ticketRun.lifecyclePhase == .failed)
		#expect(ticketRun.failedPhase == .preparing)
		#expect(events.map(\.message).contains("ticket_lifecycle_transition"))
		#expect(events.map(\.message).contains("ticket_lifecycle_failed"))
		#expect(events.contains { $0.metadataJSON.contains("\"nextPhase\":\"failed\"") })
	}

	@Test func ticketRunLifecycleServiceAllowsCanonicalWalkAwayPath() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let runID = UUID()
		let ticketRun = TicketRunRecord(runID: runID, ticketID: UUID())
		let service = TicketRunLifecycleService()
		context.insert(ticketRun)

		#expect(service.transition(ticketRun, to: .preparing, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .running, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .artifactPersisted, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .prCreated, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .reportBackPending, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .reported, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .reviewReady, runID: runID, context: context))
		try ModelIntegrityValidator.save(context: context)

		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())
		#expect(ticketRun.lifecyclePhase == .reviewReady)
		#expect(events.filter { $0.message == "ticket_lifecycle_transition" }.count == 7)
		#expect(events.contains { $0.message == "ticket_lifecycle_transition_rejected" } == false)
	}

	@Test func ticketRunLifecycleServiceRejectsInvalidPhaseJump() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let runID = UUID()
		let ticketRun = TicketRunRecord(runID: runID, ticketID: UUID())
		let service = TicketRunLifecycleService()
		context.insert(ticketRun)

		let didTransition = service.transition(
			ticketRun,
			to: .reviewReady,
			runID: runID,
			context: context,
			reason: "cannot review before report-back"
		)
		try ModelIntegrityValidator.save(context: context)

		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())
		#expect(didTransition == false)
		#expect(ticketRun.lifecyclePhase == .queued)
		#expect(events.contains { $0.message == "ticket_lifecycle_transition" } == false)
		#expect(
			events.contains { event in
				event.message == "ticket_lifecycle_transition_rejected"
					&& event.metadataJSON.contains("\"previousPhase\":\"queued\"")
					&& event.metadataJSON.contains("\"nextPhase\":\"reviewReady\"")
			}
		)
	}

	@Test func ticketRunLifecycleServiceRequiresArtifactsBeforePullRequestDecision() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let runID = UUID()
		let ticketRun = TicketRunRecord(runID: runID, ticketID: UUID())
		let service = TicketRunLifecycleService()
		context.insert(ticketRun)

		#expect(service.transition(ticketRun, to: .preparing, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .running, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .prCreated, runID: runID, context: context) == false)
		#expect(ticketRun.lifecyclePhase == .running)
		#expect(service.transition(ticketRun, to: .artifactPersisted, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .noPullRequest, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .reportBackPending, runID: runID, context: context))
		try ModelIntegrityValidator.save(context: context)

		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())
		#expect(events.contains { $0.message == "ticket_lifecycle_transition_rejected" })
		#expect(ticketRun.lifecyclePhase == .reportBackPending)
	}

	@Test func ticketRunLifecycleServiceKeepsFailurePhaseThroughReportBackAndReview() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let runID = UUID()
		let ticketRun = TicketRunRecord(runID: runID, ticketID: UUID(), lifecyclePhase: .running)
		let service = TicketRunLifecycleService()
		context.insert(ticketRun)

		service.fail(ticketRun, runID: runID, context: context, reason: "interrupted")
		#expect(service.transition(ticketRun, to: .reportBackPending, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .reported, runID: runID, context: context))
		#expect(service.transition(ticketRun, to: .reviewReady, runID: runID, context: context))
		try ModelIntegrityValidator.save(context: context)

		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())
		#expect(ticketRun.lifecyclePhase == .reviewReady)
		#expect(ticketRun.failedPhase == .running)
		#expect(events.contains { $0.message == "ticket_lifecycle_failed" })
		#expect(events.filter { $0.message == "ticket_lifecycle_transition" }.count == 3)
	}

	@Test func dispatcherStateServicePersistsPlanAndRefreshesRunBuckets() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Dispatcher State",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let firstTicket = ticketRecord(projectID: project.id, externalID: "71", status: .ready, priority: .high)
		let secondTicket = ticketRecord(projectID: project.id, externalID: "72", status: .ready, priority: .medium)
		let disabledTicket = ticketRecord(projectID: project.id, externalID: "73", status: .ready, priority: .low)
		let firstItem = QueueItemRecord(ticketID: firstTicket.id, projectID: project.id, position: 0, priority: .high)
		let secondItem = QueueItemRecord(ticketID: secondTicket.id, projectID: project.id, position: 1, priority: .medium)
		let disabledItem = QueueItemRecord(
			ticketID: disabledTicket.id,
			projectID: project.id,
			position: 2,
			priority: .low,
			isEnabled: false
		)
		context.insert(project)
		context.insert(firstTicket)
		context.insert(secondTicket)
		context.insert(disabledTicket)
		context.insert(firstItem)
		context.insert(secondItem)
		context.insert(disabledItem)
		let dispatchPlan = try TicketDispatcherService().makeDispatchPlan(project: project, requestedConcurrency: 3, context: context)
		let run = RunRecord(projectID: project.id, status: .running, totalTickets: dispatchPlan.orchestrationPlan.queueSnapshot.count)
		let ticketRuns = dispatchPlan.orchestrationPlan.queueSnapshot.map { TicketRunRecord(runID: run.id, ticketID: $0.ticketID) }
		context.insert(run)
		for ticketRun in ticketRuns {
			context.insert(ticketRun)
		}

		let started = try DispatcherStateService().start(
			projectID: project.id,
			run: run,
			dispatchPlan: dispatchPlan,
			ticketRuns: ticketRuns,
			context: context,
			now: Date(timeIntervalSince1970: 10)
		)
		try ModelIntegrityValidator.save(context: context)

		#expect(started.status == .running)
		#expect(started.requestedConcurrency == 3)
		#expect(started.effectiveConcurrency == 3)
		#expect(started.selectedTicketRunIDs == ticketRuns.map(\.id))
		#expect(started.pendingTicketRunIDs == ticketRuns.map(\.id))
		#expect(started.skippedQueueItemIDs == [disabledItem.id])
		#expect(started.skipReasonCounts == [TicketDispatchSkipReason.disabled.rawValue: 1])
		#expect(started.selectedCount == 2)
		#expect(started.skippedCount == 1)
		#expect(started.pendingCount == 2)

		ticketRuns[0].status = .running
		ticketRuns[1].status = .completed
		let refreshed = try DispatcherStateService().refresh(
			run: run,
			ticketRuns: ticketRuns,
			context: context,
			now: Date(timeIntervalSince1970: 20)
		)

		#expect(refreshed.status == .running)
		#expect(refreshed.pendingCount == 0)
		#expect(refreshed.runningTicketRunIDs == [ticketRuns[0].id])
		#expect(refreshed.terminalTicketRunIDs == [ticketRuns[1].id])

		ticketRuns[0].status = .failed
		run.status = .completedWithFailures
		run.endedAt = Date(timeIntervalSince1970: 30)
		let terminal = try DispatcherStateService().refresh(
			run: run,
			ticketRuns: ticketRuns,
			context: context,
			now: Date(timeIntervalSince1970: 31)
		)
		try ModelIntegrityValidator.save(context: context)

		#expect(terminal.status == .completedWithFailures)
		#expect(terminal.terminalTicketRunIDs == ticketRuns.map(\.id))
		#expect(terminal.terminalCount == 2)
		#expect(terminal.completedAt == Date(timeIntervalSince1970: 30))
		#expect(terminal.resumeAction == "Review completed dispatcher results.")
	}

	@Test func dispatcherRecoveryRequeuesInterruptedTicketsIdempotently() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Dispatcher Recovery",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let disabledQueuedTicket = ticketRecord(projectID: project.id, externalID: "81", status: .failed, priority: .high)
		let missingQueueTicket = ticketRecord(projectID: project.id, externalID: "82", status: .failed, priority: .medium)
		let completedTicket = ticketRecord(projectID: project.id, externalID: "83", status: .completed, priority: .low)
		let run = RunRecord(projectID: project.id, status: .failed, totalTickets: 3)
		let disabledQueuedRun = TicketRunRecord(runID: run.id, ticketID: disabledQueuedTicket.id, status: .failed)
		let missingQueueRun = TicketRunRecord(runID: run.id, ticketID: missingQueueTicket.id, status: .failed)
		let completedRun = TicketRunRecord(runID: run.id, ticketID: completedTicket.id, status: .completed)
		let disabledItem = QueueItemRecord(
			ticketID: disabledQueuedTicket.id,
			projectID: project.id,
			position: 0,
			priority: .high,
			isEnabled: false
		)
		let dispatcher = DispatcherRunRecord(
			projectID: project.id,
			runID: run.id,
			status: .reconciled,
			requestedConcurrency: 2,
			effectiveConcurrency: 2,
			selectedTicketRunIDs: [disabledQueuedRun.id, missingQueueRun.id, completedRun.id],
			terminalTicketRunIDs: [disabledQueuedRun.id, missingQueueRun.id, completedRun.id],
			selectedCount: 3,
			terminalCount: 3,
			startedAt: Date(timeIntervalSince1970: 1),
			updatedAt: Date(timeIntervalSince1970: 2),
			resumeAction: "Review reconciled failures, then requeue tickets that still need work."
		)
		context.insert(project)
		context.insert(disabledQueuedTicket)
		context.insert(missingQueueTicket)
		context.insert(completedTicket)
		context.insert(run)
		context.insert(disabledQueuedRun)
		context.insert(missingQueueRun)
		context.insert(completedRun)
		context.insert(disabledItem)
		context.insert(dispatcher)
		try ModelIntegrityValidator.save(context: context)

		let result = try DispatcherRecoveryService().recoverReconciledRuns(
			projectID: project.id,
			context: context,
			now: Date(timeIntervalSince1970: 10)
		)
		let queueItems = try context.fetch(FetchDescriptor<QueueItemRecord>()).sorted { $0.position < $1.position }
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())

		#expect(result.scannedDispatcherRuns == 1)
		#expect(result.recoveredTicketIDs == [disabledQueuedTicket.id, missingQueueTicket.id])
		#expect(result.alreadyQueuedTicketIDs.isEmpty)
		#expect(result.skippedTicketIDs.isEmpty)
		#expect(result.recoveredProjectIDs == [project.id])
		#expect(result.hasRecoverableWork)
		#expect(queueItems.map(\.ticketID) == [disabledQueuedTicket.id, missingQueueTicket.id])
		#expect(queueItems.map(\.isEnabled) == [true, true])
		#expect(queueItems.map(\.position) == [0, 1])
		#expect(disabledQueuedTicket.status == .queued)
		#expect(missingQueueTicket.status == .queued)
		#expect(completedTicket.status == .completed)
		#expect(dispatcher.resumeAction.contains("Recovered 2 interrupted ticket runs"))
		#expect(events.contains { $0.message == "dispatcher_recovery_requeued" })

		let secondResult = try DispatcherRecoveryService().recoverReconciledRuns(projectID: project.id, context: context)
		let secondQueueItems = try context.fetch(FetchDescriptor<QueueItemRecord>())

		#expect(secondResult.recoveredTicketIDs.isEmpty)
		#expect(secondResult.alreadyQueuedTicketIDs == [disabledQueuedTicket.id, missingQueueTicket.id])
		#expect(secondResult.hasRecoverableWork)
		#expect(secondQueueItems.count == 2)
	}

	@Test func projectRunSupervisorPreparesRecoveredWorkResumeCommand() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumResumeCommand-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let project = Project(
			name: "Resume Command",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let otherProject = Project(
			name: "Other Project",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Other",
			repositoryURL: "https://github.com/charliewilco/Other",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let ticket = ticketRecord(projectID: project.id, externalID: "84", status: .failed, priority: .high)
		let run = RunRecord(projectID: project.id, status: .failed, totalTickets: 1, failedTickets: 1)
		let ticketRun = TicketRunRecord(runID: run.id, ticketID: ticket.id, status: .failed)
		let dispatcher = DispatcherRunRecord(
			projectID: project.id,
			runID: run.id,
			status: .reconciled,
			requestedConcurrency: 1,
			effectiveConcurrency: 1,
			selectedTicketRunIDs: [ticketRun.id],
			terminalTicketRunIDs: [ticketRun.id],
			selectedCount: 1,
			terminalCount: 1,
			startedAt: Date(timeIntervalSince1970: 1),
			updatedAt: Date(timeIntervalSince1970: 2),
			resumeAction: "Review reconciled failures, then requeue tickets that still need work."
		)
		context.insert(project)
		context.insert(otherProject)
		context.insert(ticket)
		context.insert(run)
		context.insert(ticketRun)
		context.insert(dispatcher)
		try ModelIntegrityValidator.save(context: context)
		let supervisor = ProjectRunSupervisor(
			workspaceService: ApplicationWorkspaceService(rootDirectory: root),
			runtimeDetection: RuntimeDetectionService(staticChecks: []),
			reportGenerator: ReportGenerator()
		)

		let command = try supervisor.prepareRecoveredWorkResume(projectID: project.id, context: context)

		#expect(command.projectIDs == [project.id])
		#expect(command.ticketIDs == [ticket.id])
		#expect(command.recoveredTicketIDs == [ticket.id])
		#expect(command.alreadyQueuedTicketIDs.isEmpty)
		#expect(command.canStartSingleProject)
		#expect(command.summary == "Resume 1 recovered ticket across 1 project.")
		#expect(ticket.status == .queued)

		do {
			try supervisor.startApprovedRecoveredWork(command, project: otherProject, concurrency: 1, context: context)
			Issue.record("Expected recovered work for another project to be rejected.")
		}
		catch let error as ProviderError {
			#expect(error.localizedDescription == "Recovered dispatcher work must target the selected project before it can start.")
		}
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

	@Test func runReconciliationKillsActiveContainerRunsWithoutDeletingWorkspaces() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCoreTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = root.appending(path: "workspace")
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		let project = Project(
			name: "Container Reconcile",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let ticket = ticketRecord(projectID: project.id, externalID: "77", status: .running)
		let run = RunRecord(projectID: project.id, status: .running, totalTickets: 1)
		let ticketRun = TicketRunRecord(
			runID: run.id,
			ticketID: ticket.id,
			workspacePath: workspace.path(),
			runtimeID: "container-77",
			status: .running,
			lifecyclePhase: .running
		)
		var killed: [String] = []
		context.insert(project)
		context.insert(ticket)
		context.insert(run)
		context.insert(ticketRun)
		context.insert(
			ContainerRunRecord(
				projectID: project.id,
				runID: run.id,
				ticketRunID: ticketRun.id,
				runtimeID: ticketRun.runtimeID,
				containerName: "auditorium-container-77",
				status: .running,
				workspacePath: workspace.path()
			)
		)
		context.insert(
			DispatcherRunRecord(
				projectID: project.id,
				runID: run.id,
				status: .running,
				requestedConcurrency: 1,
				effectiveConcurrency: 1,
				selectedTicketRunIDs: [ticketRun.id],
				runningTicketRunIDs: [ticketRun.id],
				selectedCount: 1,
				runningCount: 1,
				startedAt: Date(timeIntervalSince1970: 1),
				updatedAt: Date(timeIntervalSince1970: 1),
				resumeAction: "Resume dispatcher for unfinished ticket runs."
			)
		)
		try context.save()

		let result = try RunReconciliationService(killContainer: { killed.append($0) }, inspectContainer: { _ in true })
			.reconcileInterruptedRuns(context: context)
		let containers = try context.fetch(FetchDescriptor<ContainerRunRecord>())
		let dispatcher = try #require(context.fetch(FetchDescriptor<DispatcherRunRecord>()).first)
		let reportBack = try #require(context.fetch(FetchDescriptor<TicketReportBackRecord>()).first)
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())

		#expect(result.killedContainers == ["auditorium-container-77"])
		#expect(result.reconciledProjectIDs == [project.id])
		#expect(killed == ["auditorium-container-77"])
		#expect(containers.first?.status == .killed)
		#expect(ticketRun.status == .failed)
		#expect(ticketRun.lifecyclePhase == .failed)
		#expect(ticketRun.failedPhase == .running)
		#expect(ticket.status == .failed)
		#expect(dispatcher.status == .reconciled)
		#expect(dispatcher.runningCount == 0)
		#expect(dispatcher.terminalTicketRunIDs == [ticketRun.id])
		#expect(dispatcher.failureReason?.contains("interrupted during a previous app session") == true)
		#expect(reportBack.ticketRunID == ticketRun.id)
		#expect(reportBack.status == .pending)
		#expect(reportBack.attemptCount == 0)
		#expect(reportBack.externalTicketID == "77")
		#expect(events.contains { $0.message == "ticket_report_back_queued" && $0.ticketRunID == ticketRun.id })
		#expect(FileManager.default.fileExists(atPath: workspace.path()))
	}

	@Test func reconciledInterruptedRunsCanReportBackAsFailures() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Reconciled Report Back",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .containerWorkspace,
			agentProviderKind: .codex
		)
		let ticket = ticketRecord(projectID: project.id, externalID: "78", status: .running)
		let run = RunRecord(projectID: project.id, status: .running, totalTickets: 1)
		let ticketRun = TicketRunRecord(
			runID: run.id,
			ticketID: ticket.id,
			runtimeID: "container-78",
			status: .running,
			lifecyclePhase: .running
		)
		context.insert(project)
		context.insert(ticket)
		context.insert(run)
		context.insert(ticketRun)
		try context.save()

		_ = try RunReconciliationService(killContainer: { _ in }, inspectContainer: { _ in true })
			.reconcileInterruptedRuns(context: context)
		let provider = RecordingIssueTrackerProvider()
		let result = await TicketReportBackService().publishTerminalTicketRuns(
			project: project,
			run: run,
			ticketRuns: [ticketRun],
			tickets: [ticket],
			pullRequests: [],
			policy: ParsedWorkflowPolicy.defaultPolicy(),
			provider: provider,
			context: context
		)

		#expect(result == TicketReportBackSweepResult(attemptedCount: 1, succeededCount: 1, failedCount: 0))
		#expect(provider.comments.count == 1)
		#expect(provider.comments.first?.body.contains("Run was interrupted during a previous app session.") == true)
		#expect(provider.labels.isEmpty)
		#expect(ticketRun.status == .failed)
		#expect(ticketRun.lifecyclePhase == .reviewReady)
		#expect(ticketRun.failedPhase == .running)
	}

	@Test func containerRunTrackingMarksMissingActiveContainersAsOrphanedAndReadsLogTail() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumContainerTracking-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let logURL = root.appending(path: "container.log")
		try "first\nsecond\nthird".write(to: logURL, atomically: true, encoding: .utf8)
		let record = ContainerRunRecord(
			projectID: UUID(),
			runID: UUID(),
			ticketRunID: UUID(),
			runtimeID: "container-88",
			containerName: "auditorium-container-88",
			status: .running,
			workspacePath: root.path(),
			logPath: logURL.path()
		)
		context.insert(record)
		try context.save()

		let orphaned = try ContainerRunTrackingService().markMissingActiveContainersAsOrphaned(
			context: context,
			inspectContainer: { _ in false }
		)
		let tail = ContainerRunTrackingService().logTail(for: record, maximumBytes: 12)

		#expect(orphaned == ["auditorium-container-88"])
		#expect(record.status == .orphaned)
		#expect(tail.contains("third"))
	}

	@Test func containerRunTrackingPersistsInspectableMetadataWithoutSecretValues() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let runID = UUID()
		let ticketRun = TicketRunRecord(
			runID: runID,
			ticketID: UUID(),
			workspacePath: "/tmp/auditorium/workspace",
			runtimeID: "container-99",
			status: .running,
			startedAt: Date(timeIntervalSince1970: 10),
			logPath: "/tmp/auditorium/container.log"
		)
		context.insert(ticketRun)

		let trackedRecord = try ContainerRunTrackingService().recordRunningContainer(
			projectID: UUID(),
			runID: runID,
			ticketRun: ticketRun,
			context: context,
			imageName: "localhost/auditorium-codex:test",
			environmentVariableNames: ["RUNTIME_TOKEN", "INVALID-NAME", "GH_TOKEN", "GH_TOKEN"]
		)
		let record = try #require(trackedRecord)
		try ContainerRunTrackingService().recordAgentEvent(
			ticketRun: ticketRun,
			event: AgentEvent(
				level: .error,
				category: .agent,
				message: "container_codex_failed",
				outcome: .failed,
				metadataJSON: #"{"exitCode":7}"#,
				logPath: "/tmp/auditorium/final.log"
			),
			context: context,
			now: Date(timeIntervalSince1970: 20)
		)
		ticketRun.status = .failed
		ticketRun.failureReason = "Containerized Codex CLI exited with status 7."
		ticketRun.endedAt = Date(timeIntervalSince1970: 21)
		try ContainerRunTrackingService().markTerminal(ticketRun: ticketRun, context: context)
		try ModelIntegrityValidator.save(context: context)

		#expect(record.imageName == "localhost/auditorium-codex:test")
		#expect(record.environmentVariableNames == ["GH_TOKEN", "RUNTIME_TOKEN"])
		#expect(record.environmentVariableNamesJSON.contains("gho_super_secret") == false)
		#expect(record.environmentVariableNamesJSON.contains("runtime-secret-value") == false)
		#expect(record.exitCode == 7)
		#expect(record.logPath == "/tmp/auditorium/final.log")
		#expect(record.status == .failed)
		#expect(record.cleanupEligibility == .eligible)
		#expect(record.reconciliationState == .terminal)
	}

	@Test func containerCleanupPlanningProducesExplicitDryRunActionsWithoutDeletingWorkspaces() throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumContainerCleanup-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let projectID = UUID()
		let otherProjectID = UUID()
		let eligibleWorkspace = root.appending(path: "eligible")
		let preservedWorkspace = root.appending(path: "preserved")
		try FileManager.default.createDirectory(at: eligibleWorkspace, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: preservedWorkspace, withIntermediateDirectories: true)
		let eligible = ContainerRunRecord(
			id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
			projectID: projectID,
			runID: UUID(),
			ticketRunID: UUID(),
			runtimeID: "container-eligible",
			containerName: "auditorium-container-eligible",
			status: .failed,
			workspacePath: eligibleWorkspace.path(),
			lastSeenAt: Date(timeIntervalSince1970: 1),
			cleanupEligibility: .eligible,
			reconciliationState: .terminal
		)
		let preserve = ContainerRunRecord(
			id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
			projectID: projectID,
			runID: UUID(),
			ticketRunID: UUID(),
			runtimeID: "container-preserve",
			containerName: "auditorium-container-preserve",
			status: .completed,
			workspacePath: preservedWorkspace.path(),
			lastSeenAt: Date(timeIntervalSince1970: 2),
			cleanupEligibility: .preserveWorkspace,
			reconciliationState: .terminal
		)
		let active = ContainerRunRecord(
			id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
			projectID: projectID,
			runID: UUID(),
			ticketRunID: UUID(),
			runtimeID: "container-active",
			containerName: "auditorium-container-active",
			status: .running,
			lastSeenAt: Date(timeIntervalSince1970: 3),
			cleanupEligibility: .eligible,
			reconciliationState: .active
		)
		let otherProject = ContainerRunRecord(
			projectID: otherProjectID,
			runID: UUID(),
			ticketRunID: UUID(),
			runtimeID: "container-other",
			containerName: "auditorium-container-other",
			status: .failed,
			cleanupEligibility: .eligible
		)

		let plan = ContainerCleanupPlanningService().makePlan(
			containers: [preserve, otherProject, active, eligible],
			projectID: projectID
		)

		#expect(plan.scannedCount == 3)
		#expect(plan.actionableCount == 1)
		#expect(plan.preservedCount == 1)
		#expect(plan.skippedCount == 1)
		#expect(plan.actionableContainerNames == ["auditorium-container-eligible"])
		#expect(
			plan.actions.map(\.containerName) == [
				"auditorium-container-eligible",
				"auditorium-container-preserve",
				"auditorium-container-active",
			]
		)
		#expect(plan.actions.map(\.kind) == [.removeTerminalContainer, .preserve, .skip])
		#expect(plan.actions.map(\.workspacePath).contains(eligibleWorkspace.path()))
		#expect(FileManager.default.fileExists(atPath: eligibleWorkspace.path()))
		#expect(FileManager.default.fileExists(atPath: preservedWorkspace.path()))
	}

	@Test func containerCleanupPlanningRequiresExplicitPolicyToStopActiveContainers() throws {
		let projectID = UUID()
		let active = ContainerRunRecord(
			projectID: projectID,
			runID: UUID(),
			ticketRunID: UUID(),
			runtimeID: "container-active",
			containerName: "auditorium-container-active",
			status: .running,
			cleanupEligibility: .eligible,
			reconciliationState: .active
		)

		let defaultPlan = ContainerCleanupPlanningService().makePlan(containers: [active], projectID: projectID)
		let explicitStopPlan = ContainerCleanupPlanningService().makePlan(
			containers: [active],
			projectID: projectID,
			policy: ContainerCleanupPolicy(allowsActiveContainerStop: true)
		)

		#expect(defaultPlan.actions.map(\.kind) == [.skip])
		#expect(defaultPlan.actions.first?.reason.contains("stop or reconciliation") == true)
		#expect(explicitStopPlan.actions.map(\.kind) == [.stopContainer])
		#expect(explicitStopPlan.actionableContainerNames == ["auditorium-container-active"])
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
			RuntimeHealthCheck(id: "git", name: "Git", state: .available, detail: "/usr/bin/git", version: nil),
			RuntimeHealthCheck(id: "container", name: "Container CLI", state: .available, detail: "running", version: nil),
		])

		let localWorkspace = statuses.first { $0.kind == .localWorkspace }
		let containerWorkspace = statuses.first { $0.kind == .containerWorkspace }
		let mockRuntime = statuses.first { $0.kind == .mockRuntime }

		#expect(localWorkspace?.isRunnable == true)
		#expect(containerWorkspace?.isRunnable == true)
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

	@Test func reviewWorkbenchStateDerivesDenseRowsAndDispatcherSkipsFromDurableRecords() throws {
		let projectID = UUID()
		let runID = UUID()
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "12",
			title: "Containerized handoff",
			body: "Body",
			status: .needsReview,
			labels: [],
			assignee: nil,
			priority: .high,
			webURL: "",
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 0),
			estimatedComplexity: 2,
			sourceProjectID: projectID
		)
		let ticketRun = TicketRunRecord(
			runID: runID,
			ticketID: ticket.id,
			workspacePath: "/tmp/workspace",
			runtimeID: "container-12",
			branchName: "auditorium/issue-12",
			status: .needsReview,
			lifecyclePhase: .reviewReady,
			startedAt: Date(timeIntervalSince1970: 10),
			logPath: "/tmp/container.log",
			pullRequestURL: "https://github.com/charliewilco/Auditorium/pull/12",
			summary: "Ready for review.",
			confidence: 0.91
		)
		let pullRequest = PullRequestRecord(
			provider: .github,
			ticketRunID: ticketRun.id,
			title: "Issue 12",
			url: "https://github.com/charliewilco/Auditorium/pull/12",
			branchName: "auditorium/issue-12",
			targetBranch: "main",
			status: .open,
			checksStatus: .passed
		)
		let reportBack = TicketReportBackRecord(
			ticketRunID: ticketRun.id,
			provider: .githubIssues,
			externalTicketID: "12",
			status: .succeeded,
			attemptCount: 1,
			commentURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/12#issuecomment-1")?.absoluteString
		)
		let container = ContainerRunRecord(
			projectID: projectID,
			runID: runID,
			ticketRunID: ticketRun.id,
			runtimeID: "container-12",
			containerName: "auditorium-container-12",
			status: .completed,
			imageName: "localhost/auditorium-codex:test",
			environmentVariableNames: ["GH_TOKEN"],
			workspacePath: "/tmp/workspace",
			logPath: "/tmp/container.log",
			exitCode: 0,
			cleanupEligibility: .preserveWorkspace,
			reconciliationState: .terminal
		)
		let changedFilesEvent = RuntimeEventRecord(
			runID: runID,
			ticketRunID: ticketRun.id,
			level: .success,
			category: .git,
			message: "Changed files recorded.",
			metadataJSON: #"{"changedFiles":["Sources/App.swift"]}"#
		)
		let skipID = UUID()
		let skippedEvent = RuntimeEventRecord(
			runID: runID,
			level: .info,
			category: .orchestration,
			message: "Dispatcher skipped queue item: Retry Backoff.",
			metadataJSON:
				#"{"queueItemID":"\#(skipID.uuidString)","ticketID":"\#(ticket.id.uuidString)","reason":"retryBackoff","detail":"Retry available later."}"#
		)

		let state = ReviewWorkbenchState.make(
			ticketRuns: [ticketRun],
			tickets: [ticket],
			events: [changedFilesEvent, skippedEvent],
			coordinationMessages: [],
			pullRequests: [pullRequest],
			reportBacks: [reportBack],
			containerRuns: [container],
			logTailProvider: { _ in "tail line" }
		)

		let row = try #require(state.rows.first)
		#expect(row.ticketExternalID == "12")
		#expect(row.pullRequestURL == "https://github.com/charliewilco/Auditorium/pull/12")
		#expect(row.reportBackStatus == .succeeded)
		#expect(row.reportBackCommentURL == "https://github.com/charliewilco/Auditorium/issues/12#issuecomment-1")
		#expect(row.containerStatus == .completed)
		#expect(row.containerImageName == "localhost/auditorium-codex:test")
		#expect(row.containerEnvironmentVariableNames == ["GH_TOKEN"])
		#expect(row.containerExitCode == 0)
		#expect(row.containerCleanupEligibility == .preserveWorkspace)
		#expect(row.containerReconciliationState == .terminal)
		#expect(row.changedFiles == ["Sources/App.swift"])
		#expect(row.logTail == "tail line")
		#expect(row.nextAction == "Review the pull request and merge only after human approval.")
		#expect(
			state.skippedItems == [
				ReviewWorkbenchState.SkippedItem(
					id: skipID,
					ticketID: ticket.id,
					reason: "retryBackoff",
					detail: "Retry available later."
				)
			]
		)
	}

	@Test func reviewWorkbenchStatePrioritizesPendingReportBackNextAction() throws {
		let projectID = UUID()
		let runID = UUID()
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "13",
			title: "Failed handoff",
			body: "Body",
			status: .failed,
			labels: [],
			assignee: nil,
			priority: .medium,
			webURL: "",
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 0),
			estimatedComplexity: 2,
			sourceProjectID: projectID
		)
		let ticketRun = TicketRunRecord(
			runID: runID,
			ticketID: ticket.id,
			status: .failed,
			lifecyclePhase: .reportBackPending,
			failedPhase: .running,
			failureReason: "Validation failed."
		)
		let reportBack = TicketReportBackRecord(
			ticketRunID: ticketRun.id,
			provider: .githubIssues,
			externalTicketID: "13",
			status: .pending,
			attemptCount: 0
		)

		let state = ReviewWorkbenchState.make(
			ticketRuns: [ticketRun],
			tickets: [ticket],
			events: [],
			coordinationMessages: [],
			pullRequests: [],
			reportBacks: [reportBack],
			containerRuns: [],
			logTailProvider: { _ in "" }
		)

		let row = try #require(state.rows.first)
		#expect(row.runStatus == .failed)
		#expect(row.reportBackStatus == .pending)
		#expect(row.nextAction == "Publish the pending report-back; execution state is already preserved.")
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
			case ("/usr/bin/which", ["git"]):
				RuntimeCommandResult(exitCode: 0, output: "/usr/bin/git")
			case ("/usr/bin/which", ["codex"]):
				RuntimeCommandResult(exitCode: 0, output: "/opt/homebrew/bin/codex")
			case ("/usr/bin/which", ["gh"]):
				RuntimeCommandResult(exitCode: 0, output: "/opt/homebrew/bin/gh")
			case ("/usr/bin/git", ["--version"]):
				RuntimeCommandResult(exitCode: 0, output: "git version 2.50.1")
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

		#expect(checks.map(\.id) == ["git", "codex-auth", "github-auth"])
		#expect(checksByID["git"]?.state == .available)
		#expect(checksByID["git"]?.detail == "/usr/bin/git")
		#expect(checksByID["git"]?.version == "git version 2.50.1")
		#expect(checksByID["codex-auth"]?.state == .available)
		#expect(checksByID["codex-auth"]?.detail == "Logged in using ChatGPT")
		#expect(checksByID["github-auth"]?.state == .available)
		#expect(checksByID["github-auth"]?.detail == "GitHub CLI is authenticated for github.com as charliewilco.")
	}

	@Test func onboardingChecksReportMissingAuthenticationSeparatelyFromInstallation() async {
		let detection = RuntimeDetectionService(commandRunner: { launchPath, arguments in
			switch (launchPath, arguments) {
			case ("/usr/bin/which", ["git"]):
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

		#expect(Set(checksByID.keys) == ["git", "codex-auth", "github-auth"])
		#expect(checksByID["git"]?.state == .needsSetup)
		#expect(checksByID["codex-auth"]?.state == .needsSetup)
		#expect(checksByID["codex-auth"]?.detail.contains("no authenticated session") == true)
		#expect(checksByID["github-auth"]?.state == .needsSetup)
		#expect(checksByID["github-auth"]?.detail.contains("authentication is missing or invalid") == true)
	}

	@Test func onboardingChecksRejectGitShimThatCannotRun() async {
		let detection = RuntimeDetectionService(commandRunner: { launchPath, arguments in
			switch (launchPath, arguments) {
			case ("/usr/bin/which", ["git"]):
				RuntimeCommandResult(exitCode: 0, output: "/usr/bin/git")
			case ("/usr/bin/which", ["codex"]), ("/usr/bin/which", ["gh"]):
				RuntimeCommandResult(exitCode: 1, output: "")
			case ("/usr/bin/git", ["--version"]):
				RuntimeCommandResult(exitCode: 1, output: "xcode-select: note: no developer tools were found")
			default:
				nil
			}
		})

		let gitCheck = await detection.onboardingChecks().first { $0.id == "git" }

		#expect(gitCheck?.state == .needsSetup)
		#expect(gitCheck?.detail.contains("could not run") == true)
		#expect(gitCheck?.detail.contains("Xcode Command Line Tools") == true)
	}

	@Test func codexAuthBundleCopiesOnlyAuthFileAndCleansUp() async throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCodexAuthBundleTests-\(UUID().uuidString)")
		let sourceCodexHome = root.appending(path: "source/.codex")
		let temporaryRoot = root.appending(path: "tmp")
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: sourceCodexHome, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
		try #"{"tokens":"secret"}"#.write(to: sourceCodexHome.appending(path: "auth.json"), atomically: true, encoding: .utf8)
		try "model = \"test\"\n".write(to: sourceCodexHome.appending(path: "config.toml"), atomically: true, encoding: .utf8)
		try FileManager.default.createDirectory(at: sourceCodexHome.appending(path: "sessions"), withIntermediateDirectories: true)
		let service = CodexAuthBundleService(
			sourceCodexHome: sourceCodexHome,
			temporaryRoot: temporaryRoot,
			statusValidator: {}
		)

		let bundle = try await service.createBundle()
		defer { service.cleanUp(bundle) }

		#expect(FileManager.default.fileExists(atPath: bundle.directory.appending(path: "auth.json").path()))
		#expect(FileManager.default.fileExists(atPath: bundle.directory.appending(path: "config.toml").path()) == false)
		#expect(FileManager.default.fileExists(atPath: bundle.directory.appending(path: "sessions").path()) == false)
		service.cleanUp(bundle)
		#expect(FileManager.default.fileExists(atPath: bundle.directory.path()) == false)
	}

	@Test func containerizedCodexArgumentsInheritEnvironmentWithoutSecretValues() throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumContainerCodexArguments-\(UUID().uuidString)")
		let workspace = root.appending(path: "workspace")
		let codexHome = root.appending(path: ".codex")
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
		let request = AgentRunRequest(
			ticket: ticket(number: 42, labels: ["runtime"], assignee: nil),
			repository: RepositoryDescriptor(
				provider: .github,
				owner: "charliewilco",
				name: "Auditorium",
				fullName: "charliewilco/Auditorium",
				cloneURL: URL(string: "https://github.com/charliewilco/Auditorium.git")!,
				webURL: URL(string: "https://github.com/charliewilco/Auditorium")!,
				defaultBranch: "main"
			),
			workspace: WorkspaceDescriptor(path: workspace, runtimeID: "container-42", branchName: "auditorium/42"),
			policyMarkdown: WorkflowPolicy.defaultMarkdown,
			environment: [
				"GH_TOKEN": "gho_super_secret",
				"RUNTIME_TOKEN": "runtime-secret-value",
				"INVALID-NAME": "invalid-secret-value",
			]
		)
		let arguments = ContainerizedCodexAgentProvider.containerRunArguments(
			configuration: ContainerizedCodexAgentConfiguration(
				imageName: "localhost/auditorium-codex:test",
				hostUserID: "501",
				hostGroupID: "20"
			),
			request: request,
			authBundle: CodexAuthBundle(directory: codexHome),
			containerName: "auditorium-container-42"
		)
		let joinedArguments = arguments.joined(separator: " ")

		#expect(arguments.contains("container"))
		#expect(arguments.contains("run"))
		#expect(arguments.contains("localhost/auditorium-codex:test"))
		#expect(arguments.contains("GH_TOKEN"))
		#expect(arguments.contains("RUNTIME_TOKEN"))
		#expect(arguments.contains("INVALID-NAME") == false)
		#expect(joinedArguments.contains("gho_super_secret") == false)
		#expect(joinedArguments.contains("runtime-secret-value") == false)
		#expect(joinedArguments.contains("invalid-secret-value") == false)
		#expect(joinedArguments.contains("source=\(workspace.path())") == true)
		#expect(joinedArguments.contains("source=\(codexHome.path())") == true)
		#expect(arguments.contains("--ignore-user-config"))
	}

	private func ticket(
		number: Int,
		labels: [String],
		assignee: String?,
		status: TicketStatus = .ready,
		priority: PriorityLevel = .medium,
		updatedAt: TimeInterval = 0,
		blockedBy: [String] = []
	) -> TicketDescriptor {
		TicketDescriptor(
			provider: .githubIssues,
			externalID: "\(number)",
			title: "Issue \(number)",
			body: "Body",
			status: status,
			labels: labels,
			assignee: assignee,
			priority: priority,
			webURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/\(number)"),
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: updatedAt),
			estimatedComplexity: 1,
			blockedBy: blockedBy
		)
	}

	private func ticketRecord(
		projectID: UUID,
		externalID: String,
		status: TicketStatus,
		priority: PriorityLevel = .medium,
		blockedBy: [String] = []
	) -> TicketRecord {
		TicketRecord(
			provider: .githubIssues,
			externalID: externalID,
			title: "Issue \(externalID)",
			body: "Body",
			status: status,
			labels: [],
			assignee: nil,
			priority: priority,
			webURL: "https://github.com/charliewilco/Auditorium/issues/\(externalID)",
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 0),
			estimatedComplexity: 1,
			blockedBy: blockedBy,
			sourceProjectID: projectID
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

	func addComment(ticketID: String, body: String) async throws -> URL? { nil }
}

private struct InstantAgentProvider: AgentProvider {
	func runAgent(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
		AsyncThrowingStream { continuation in
			continuation.yield(
				AgentEvent(
					level: .success,
					category: .agent,
					message: "instant_agent_completed",
					summary: "Completed \(request.ticket.externalID).",
					outcome: .completed
				)
			)
			continuation.finish()
		}
	}
}

private struct CancelingAgentProvider: AgentProvider {
	func runAgent(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
		throw CancellationError()
	}
}

private actor RecordingContainerCommandRunner {
	struct Call: Equatable {
		let executable: String
		let arguments: [String]
		let allowsNonZeroExit: Bool
	}

	private let result: ProcessResult?
	private let error: Error?
	private var calls: [Call] = []

	init(result: ProcessResult? = nil, error: Error? = nil) {
		self.result = result
		self.error = error
	}

	func run(executable: String, arguments: [String], allowsNonZeroExit: Bool) throws -> ProcessResult {
		calls.append(Call(executable: executable, arguments: arguments, allowsNonZeroExit: allowsNonZeroExit))
		if let error {
			throw error
		}
		return result ?? ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
	}

	func recordedCalls() -> [Call] {
		calls
	}
}

private struct TestSourceCodeProvider: SourceCodeProvider {
	let kind = RepositoryProviderKind.github
	let authentication = ProviderAuthenticationDescriptor(method: .oauth, displayName: "Test GitHub", oauth: GitHubOAuth.descriptor)

	func listRepositories() async throws -> [RepositoryDescriptor] { [] }

	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws {
		try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
	}

	func createBranch(named branchName: String, in repositoryPath: URL) async throws {
		try FileManager.default.createDirectory(at: repositoryPath.appending(path: ".auditorium"), withIntermediateDirectories: true)
		try branchName.write(
			to: repositoryPath.appending(path: ".auditorium/branch"),
			atomically: true,
			encoding: .utf8
		)
	}

	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor {
		PullRequestDescriptor(
			title: request.title,
			url: URL(string: "https://github.com/charliewilco/Auditorium/pull/1")!,
			branchName: request.branchName,
			targetBranch: request.targetBranch,
			status: .open,
			checksStatus: .pending
		)
	}
}

private final class RecordingHandoffProvider: HandoffProvider {
	let kind = IssueProviderKind.githubIssues
	let authentication = ProviderAuthenticationDescriptor(method: .oauth, displayName: "Recording Handoff", oauth: GitHubOAuth.descriptor)
	let receipt: TicketHandoffReceipt
	var requests: [TicketHandoffRequest] = []

	init(receipt: TicketHandoffReceipt = TicketHandoffReceipt(commentURL: nil)) {
		self.receipt = receipt
	}

	func publishHandoff(_ request: TicketHandoffRequest) async throws -> TicketHandoffReceipt {
		requests.append(request)
		return receipt
	}
}

private final class RecordingIssueTrackerProvider: IssueTrackerProvider {
	let kind = IssueProviderKind.githubIssues
	let authentication = ProviderAuthenticationDescriptor(method: .oauth, displayName: "Recording GitHub", oauth: GitHubOAuth.descriptor)
	let tickets: [TicketDescriptor]
	let commentURL: URL?
	let commentError: Error?
	var comments: [(ticketID: String, body: String)] = []
	var labels: [(String, [String])] = []

	init(tickets: [TicketDescriptor] = [], commentURL: URL? = nil, commentError: Error? = nil) {
		self.tickets = tickets
		self.commentURL = commentURL
		self.commentError = commentError
	}

	func listTickets(projectID: String) async throws -> [TicketDescriptor] {
		tickets
	}

	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws {}

	func addComment(ticketID: String, body: String) async throws -> URL? {
		comments.append((ticketID, body))
		if let commentError {
			throw commentError
		}
		return commentURL
	}

	func addLabels(ticketID: String, labels: [String]) async throws {
		self.labels.append((ticketID, labels))
	}
}
