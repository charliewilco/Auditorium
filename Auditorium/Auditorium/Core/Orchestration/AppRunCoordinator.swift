import Foundation
import SwiftData

@MainActor
final class AppRunCoordinator {
	private let workspaceService: ApplicationWorkspaceService
	private let reportGenerator: ReportGenerator
	private let orchestrator: Orchestrator

	init(
		workspaceService: ApplicationWorkspaceService,
		runtimeDetection: RuntimeDetectionService,
		reportGenerator: ReportGenerator,
		symphonyRunner: SymphonyCLIProcessRunner = SymphonyCLIProcessRunner(),
		providerRegistry: ProviderRegistry? = nil,
		mockSourceProvider: (any SourceCodeProvider)? = nil,
		mockAgentProvider: (any AgentProvider)? = nil,
		localWorkspaceSourceProvider: (any SourceCodeProvider)? = nil,
		codexAgentProvider: (any AgentProvider)? = nil
	) {
		self.workspaceService = workspaceService
		self.reportGenerator = reportGenerator
		orchestrator = Orchestrator(
			workspaceService: workspaceService,
			runtimeDetection: runtimeDetection,
			reportGenerator: reportGenerator,
			symphonyRunner: symphonyRunner,
			providerRegistry: providerRegistry,
			mockSourceProvider: mockSourceProvider,
			mockAgentProvider: mockAgentProvider,
			localWorkspaceSourceProvider: localWorkspaceSourceProvider,
			codexAgentProvider: codexAgentProvider
		)
	}

	func startQueue(project: Project, concurrency: Int, context: ModelContext) {
		orchestrator.runQueue(projectID: project.id, concurrency: concurrency, context: context)
	}

	func cancelActiveRun() {
		orchestrator.cancel()
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
