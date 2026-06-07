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
}
