import Foundation
import SwiftData

@MainActor
final class ProjectRunSupervisor {
	private let orchestrator: Orchestrator
	private let providerRegistry: ProviderRegistry?
	private let reportBackService: TicketReportBackService
	private let reconciliationService: RunReconciliationService
	private let dispatcherService: TicketDispatcherService
	private let dispatcherRecoveryService: DispatcherRecoveryService

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
		containerCodexAgentProvider: (any AgentProvider)? = nil,
		reportBackService: TicketReportBackService? = nil,
		reconciliationService: RunReconciliationService? = nil,
		dispatcherService: TicketDispatcherService? = nil,
		dispatcherRecoveryService: DispatcherRecoveryService? = nil
	) {
		self.providerRegistry = providerRegistry
		let resolvedReportBackService = reportBackService ?? TicketReportBackService()
		self.reportBackService = resolvedReportBackService
		self.reconciliationService = reconciliationService ?? RunReconciliationService()
		self.dispatcherService = dispatcherService ?? TicketDispatcherService()
		self.dispatcherRecoveryService = dispatcherRecoveryService ?? DispatcherRecoveryService()
		orchestrator = Orchestrator(
			workspaceService: workspaceService,
			runtimeDetection: runtimeDetection,
			reportGenerator: reportGenerator,
			reportBackService: resolvedReportBackService,
			symphonyRunner: symphonyRunner,
			providerRegistry: providerRegistry,
			mockSourceProvider: mockSourceProvider,
			mockAgentProvider: mockAgentProvider,
			localWorkspaceSourceProvider: localWorkspaceSourceProvider,
			codexAgentProvider: codexAgentProvider,
			containerCodexAgentProvider: containerCodexAgentProvider,
			usesSymphonyForLocalWorkspaceCodex: true
		)
	}

	func dispatchPlan(project: Project, concurrency: Int, context: ModelContext, now: Date = .now) throws -> TicketDispatchPlan {
		try dispatcherService.makeDispatchPlan(project: project, requestedConcurrency: concurrency, context: context, now: now)
	}

	func startQueuedRun(project: Project, concurrency: Int, context: ModelContext) {
		orchestrator.runQueue(projectID: project.id, concurrency: concurrency, context: context)
	}

	@discardableResult
	func fillQueue(
		project: Project,
		context: ModelContext,
		policy: QueueFillPolicy? = nil
	) async throws -> QueueFillResult {
		guard let providerRegistry else {
			throw ProviderError.unavailable("An issue provider is required to fill the queue.")
		}
		let provider = try await providerRegistry.issueTrackerProvider(for: project, context: context)
		return try await QueueFillService().queueNextTickets(
			for: project,
			policy: policy ?? QueueFillPolicy(),
			context: context,
			provider: provider
		)
	}

	@discardableResult
	func fillQueueAndStart(
		project: Project,
		concurrency: Int,
		context: ModelContext,
		policy: QueueFillPolicy? = nil
	) async throws -> QueueFillResult {
		let result = try await fillQueue(project: project, context: context, policy: policy)
		startQueuedRun(project: project, concurrency: concurrency, context: context)
		return result
	}

	func stopActiveRun() {
		orchestrator.cancel()
	}

	@discardableResult
	func retryHandoffs(projectID: UUID, context: ModelContext, now: Date = .now) async throws -> TicketReportBackSweepResult {
		guard let providerRegistry else {
			throw ProviderError.unavailable("An issue provider is required to retry report-backs.")
		}
		return try await reportBackService.publishPendingReportBacks(
			projectID: projectID,
			context: context,
			providerRegistry: providerRegistry,
			now: now
		)
	}

	@discardableResult
	func reconcileInterruptedRuns(context: ModelContext, now: Date = .now) throws -> RunReconciliationResult {
		try reconciliationService.reconcileInterruptedRuns(context: context, now: now)
	}

	@discardableResult
	func recoverInterruptedWork(projectID: UUID? = nil, context: ModelContext, now: Date = .now) throws -> DispatcherRecoveryResult {
		try dispatcherRecoveryService.recoverReconciledRuns(projectID: projectID, context: context, now: now)
	}

	@discardableResult
	func prepareRecoveredWorkResume(projectID: UUID? = nil, context: ModelContext, now: Date = .now) throws -> DispatcherResumeCommand {
		DispatcherResumeCommand(recoveryResult: try recoverInterruptedWork(projectID: projectID, context: context, now: now))
	}

	func startApprovedRecoveredWork(
		_ command: DispatcherResumeCommand,
		project: Project,
		concurrency: Int,
		context: ModelContext
	) throws {
		guard command.hasWorkToStart else {
			throw ProviderError.unavailable("No recovered dispatcher work is ready to start.")
		}
		guard command.singleProjectID == project.id else {
			throw ProviderError.unavailable("Recovered dispatcher work must target the selected project before it can start.")
		}
		startQueuedRun(project: project, concurrency: concurrency, context: context)
	}

	func resumeAfterLaunch(context: ModelContext, now: Date = .now) async throws -> RunReconciliationResult {
		let result = try reconcileInterruptedRuns(context: context, now: now)
		_ = try recoverInterruptedWork(context: context, now: now)
		let projectIDs = try reportBackProjectIDsForLaunchResume(
			reconciledProjectIDs: result.reconciledProjectIDs,
			context: context,
			now: now
		)
		for projectID in projectIDs {
			_ = try await retryHandoffs(projectID: projectID, context: context, now: now)
		}
		return result
	}

	private func reportBackProjectIDsForLaunchResume(
		reconciledProjectIDs: [UUID],
		context: ModelContext,
		now: Date
	) throws -> [UUID] {
		let dueProjectIDs = try reportBackService.projectIDsNeedingReportBackRetry(context: context, now: now)
		return Array(Set(reconciledProjectIDs + dueProjectIDs)).sorted { $0.uuidString < $1.uuidString }
	}
}
