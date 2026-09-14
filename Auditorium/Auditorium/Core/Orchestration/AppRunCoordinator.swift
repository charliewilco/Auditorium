import Foundation
import SwiftData

@MainActor
final class AppRunCoordinator {
	private let workspaceService: ApplicationWorkspaceService
	private let reportGenerator: ReportGenerator
	private let supervisor: ProjectRunSupervisor

	init(
		workspaceService: ApplicationWorkspaceService,
		runtimeDetection: RuntimeDetectionService,
		reportGenerator: ReportGenerator,
		symphonyRunner: SymphonyCLIProcessRunner = SymphonyCLIProcessRunner(),
		providerRegistry: ProviderRegistry? = nil,
		mockSourceProvider: (any SourceCodeProvider)? = nil,
		mockAgentProvider: (any AgentProvider)? = nil,
		localWorkspaceSourceProvider: (any SourceCodeProvider)? = nil,
		codexAgentProvider: (any AgentProvider)? = nil,
		containerCodexAgentProvider: (any AgentProvider)? = nil
	) {
		self.workspaceService = workspaceService
		self.reportGenerator = reportGenerator
		supervisor = ProjectRunSupervisor(
			workspaceService: workspaceService,
			runtimeDetection: runtimeDetection,
			reportGenerator: reportGenerator,
			symphonyRunner: symphonyRunner,
			providerRegistry: providerRegistry,
			mockSourceProvider: mockSourceProvider,
			mockAgentProvider: mockAgentProvider,
			localWorkspaceSourceProvider: localWorkspaceSourceProvider,
			codexAgentProvider: codexAgentProvider,
			containerCodexAgentProvider: containerCodexAgentProvider
		)
	}

	func startQueue(project: Project, concurrency: Int, context: ModelContext) {
		supervisor.startQueuedRun(project: project, concurrency: concurrency, context: context)
	}

	@discardableResult
	func fillQueue(
		project: Project,
		context: ModelContext,
		limit: Int = 12
	) async throws -> QueueFillResult {
		try await supervisor.fillQueue(
			project: project,
			context: context,
			policy: QueueFillPolicy(limit: limit)
		)
	}

	@discardableResult
	func fillQueueAndStart(
		project: Project,
		concurrency: Int,
		context: ModelContext,
		limit: Int = 12
	) async throws -> QueueFillResult {
		try await supervisor.fillQueueAndStart(
			project: project,
			concurrency: concurrency,
			context: context,
			policy: QueueFillPolicy(limit: limit)
		)
	}

	func cancelActiveRun() {
		supervisor.stopActiveRun()
	}

	@discardableResult
	func resumeAfterLaunch(context: ModelContext, now: Date = .now) async throws -> RunReconciliationResult {
		try await supervisor.resumeAfterLaunch(context: context, now: now)
	}

	@discardableResult
	func recoverInterruptedWork(projectID: UUID? = nil, context: ModelContext, now: Date = .now) throws -> DispatcherRecoveryResult {
		try supervisor.recoverInterruptedWork(projectID: projectID, context: context, now: now)
	}

	@discardableResult
	func prepareRecoveredWorkResume(projectID: UUID? = nil, context: ModelContext, now: Date = .now) throws -> DispatcherResumeCommand {
		try supervisor.prepareRecoveredWorkResume(projectID: projectID, context: context, now: now)
	}

	func startApprovedRecoveredWork(
		_ command: DispatcherResumeCommand,
		project: Project,
		concurrency: Int,
		context: ModelContext
	) throws {
		try supervisor.startApprovedRecoveredWork(command, project: project, concurrency: concurrency, context: context)
	}

	@discardableResult
	func retryHandoffs(projectID: UUID, context: ModelContext, now: Date = .now) async throws -> TicketReportBackSweepResult {
		try await supervisor.retryHandoffs(projectID: projectID, context: context, now: now)
	}

	@discardableResult
	func createDryRun(
		project: Project,
		queueItems: [QueueItemRecord],
		tickets: [TicketRecord],
		context: ModelContext
	) throws -> RunRecord {
		let enabledCount = queueItems.filter(\.isEnabled).count
		let run = RunRecord(
			projectID: project.id,
			status: .completed,
			totalTickets: enabledCount,
			workflowPolicySnapshotMarkdown: project.workflowPolicyMarkdown,
			summary: "Dry run completed. No workspaces or agents were started."
		)
		run.endedAt = .now
		context.insert(run)
		let event = RuntimeEventRecord(
			runID: run.id,
			level: .success,
			category: .orchestration,
			message: "Dry run validated \(enabledCount) enabled queue items."
		)
		context.insert(event)
		let markdown = reportGenerator.generate(
			project: project,
			run: run,
			ticketRuns: [],
			tickets: tickets,
			pullRequests: [],
			events: [event]
		)
		let reportURL = try reportGenerator.save(
			markdown: markdown,
			projectID: project.id,
			runID: run.id,
			workspace: workspaceService
		)
		run.reportMarkdown = markdown
		context.insert(
			ReportRecord(
				projectID: project.id,
				runID: run.id,
				title: "Dry Run \(run.id.uuidString.prefix(8))",
				markdown: markdown,
				filePath: reportURL.path()
			)
		)
		try ModelIntegrityValidator.save(context: context)
		return run
	}
}
