import Foundation
import SwiftData

@MainActor
final class Orchestrator {
	private let workspaceService: ApplicationWorkspaceService
	private let runtimeDetection: RuntimeDetectionService
	private let reportGenerator: ReportGenerator
	private var activeTask: Task<Void, Never>?

	init(
		workspaceService: ApplicationWorkspaceService,
		runtimeDetection: RuntimeDetectionService,
		reportGenerator: ReportGenerator
	) {
		self.workspaceService = workspaceService
		self.runtimeDetection = runtimeDetection
		self.reportGenerator = reportGenerator
	}

	func runQueue(projectID: UUID, concurrency: Int, context: ModelContext) {
		activeTask?.cancel()
		activeTask = Task {
			do {
				try await execute(projectID: projectID, concurrency: concurrency, context: context)
			} catch {
				try? insertRunFailure(projectID: projectID, message: error.localizedDescription, context: context)
			}
		}
	}

	func cancel() {
		activeTask?.cancel()
		activeTask = nil
	}

	func execute(projectID: UUID, concurrency: Int, context: ModelContext) async throws {
		let projects = try context.fetch(FetchDescriptor<Project>())
		guard let project = projects.first(where: { $0.id == projectID }) else {
			throw ProviderError.unavailable("Project was not found.")
		}
		let queueItems = try context.fetch(FetchDescriptor<QueueItemRecord>())
			.filter { $0.projectID == projectID && $0.isEnabled }
			.sorted { $0.position < $1.position }
		guard !queueItems.isEmpty else {
			throw ProviderError.unavailable("No enabled queue items to run.")
		}
		try await runtimeDetection.requireAvailableRuntime(for: project.runtimeProviderKind)
		try await runtimeDetection.requireAvailableAgent(for: project.agentProviderKind)
		guard project.runtimeProviderKind == .mockRuntime else {
			throw ProviderError.notImplemented("\(project.runtimeProviderKind.title) Runtime Provider")
		}
		guard project.agentProviderKind == .mockAgent else {
			throw ProviderError.notImplemented("\(project.agentProviderKind.title) Agent Provider")
		}
		try workspaceService.ensureProjectLayout(projectID: projectID)

		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		let run = RunRecord(projectID: projectID, status: .running, totalTickets: queueItems.count, summary: "Running \(queueItems.count) queued tickets.")
		context.insert(run)
		context.insert(RuntimeEventRecord(runID: run.id, level: .info, category: .orchestration, message: "Run started with concurrency \(max(1, concurrency))."))
		var ticketRuns: [TicketRunRecord] = []
		for item in queueItems {
			let ticketRun = TicketRunRecord(runID: run.id, ticketID: item.ticketID)
			context.insert(ticketRun)
			ticketRuns.append(ticketRun)
		}
		try context.save()

		let repository = RepositoryDescriptor(
			provider: project.repositoryProviderKind,
			owner: String(project.repositoryName.split(separator: "/").first ?? "charlie"),
			name: String(project.repositoryName.split(separator: "/").last ?? project.repositoryName[...]),
			fullName: project.repositoryName,
			cloneURL: URL(string: project.repositoryURL.hasSuffix(".git") ? project.repositoryURL : "\(project.repositoryURL).git") ?? URL(fileURLWithPath: project.repositoryURL),
			webURL: URL(string: project.repositoryURL) ?? URL(fileURLWithPath: project.repositoryURL),
			defaultBranch: project.defaultBranch
		)
		let runtime = MockRuntimeProvider(workspaceService: workspaceService, projectID: projectID)
		let agent = MockCodexAgentProvider()

		for ticketRun in ticketRuns {
			try Task.checkCancellation()
			guard let ticket = tickets.first(where: { $0.id == ticketRun.ticketID }) else {
				continue
			}
			try await processTicket(project: project, repository: repository, ticket: ticket, ticketRun: ticketRun, run: run, runtime: runtime, agent: agent, context: context)
		}

		let completed = ticketRuns.filter { $0.status == .completed || $0.status == .needsReview }.count
		let failed = ticketRuns.filter { $0.status == .failed }.count
		let blocked = ticketRuns.filter { $0.status == .blocked }.count
		run.completedTickets = completed
		run.failedTickets = failed
		run.blockedTickets = blocked
		run.pullRequestsCreated = ticketRuns.filter { $0.pullRequestURL != nil }.count
		run.endedAt = .now
		run.status = failed == 0 && blocked == 0 ? .completed : .completedWithFailures
		run.summary = "Completed \(completed), failed \(failed), blocked \(blocked)."
		context.insert(RuntimeEventRecord(runID: run.id, level: .success, category: .report, message: "Generating markdown report."))

		let finalTickets = try context.fetch(FetchDescriptor<TicketRecord>()).filter { $0.sourceProjectID == projectID }
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>()).filter { $0.runID == run.id }
		let prs = try context.fetch(FetchDescriptor<PullRequestRecord>())
		let markdown = reportGenerator.generate(project: project, run: run, ticketRuns: ticketRuns, tickets: finalTickets, pullRequests: prs, events: events)
		let reportURL = try reportGenerator.save(markdown: markdown, projectID: projectID, runID: run.id, workspace: workspaceService)
		run.reportMarkdown = markdown
		context.insert(ReportRecord(projectID: projectID, runID: run.id, title: "Run \(run.id.uuidString.prefix(8))", markdown: markdown, filePath: reportURL.path()))
		try context.save()
	}

	private func processTicket(
		project: Project,
		repository: RepositoryDescriptor,
		ticket: TicketRecord,
		ticketRun: TicketRunRecord,
		run: RunRecord,
		runtime: MockRuntimeProvider,
		agent: MockCodexAgentProvider,
		context: ModelContext
	) async throws {
		ticket.status = .running
		ticket.updatedAt = .now
		ticketRun.status = .preparing
		ticketRun.startedAt = .now
		context.insert(RuntimeEventRecord(runID: run.id, ticketRunID: ticketRun.id, level: .info, category: .orchestration, message: "\(ticket.externalID) queued for execution."))
		try context.save()

		let descriptor = ticket.descriptor
		let workspace = try await runtime.prepareWorkspace(for: descriptor, repository: repository)
		ticketRun.workspacePath = workspace.path.path()
		ticketRun.containerID = workspace.containerID
		ticketRun.branchName = workspace.branchName
		ticketRun.logPath = workspaceService.logsDirectory(projectID: project.id).appending(path: "\(ticket.externalID).log").path()
		ticketRun.status = .running
		let handle = try await runtime.startExecution(RuntimeExecutionRequest(ticket: descriptor, workspace: workspace, policyMarkdown: project.workflowPolicyMarkdown))
		context.insert(RuntimeEventRecord(runID: run.id, ticketRunID: ticketRun.id, level: .info, category: .runtime, message: "Runtime handle \(handle.id) started."))
		try context.save()

		let stream = try await agent.runAgent(AgentRunRequest(ticket: descriptor, repository: repository, workspace: workspace, policyMarkdown: project.workflowPolicyMarkdown))
		var finalOutcome: MockTicketOutcome?
		var finalSummary = ""
		for try await event in stream {
			context.insert(RuntimeEventRecord(runID: run.id, ticketRunID: ticketRun.id, level: event.level, category: event.category, message: event.message))
			if let summary = event.summary {
				finalSummary = summary
			}
			if let outcome = event.outcome {
				finalOutcome = outcome
			}
			try context.save()
		}

		switch finalOutcome ?? .completed {
		case .completed:
			let provider = MockGitHubRepositoryProvider()
			let pr = try await provider.createPullRequest(PullRequestRequest(
				title: "\(ticket.externalID): \(ticket.title)",
				body: finalSummary,
				branchName: workspace.branchName,
				targetBranch: project.defaultBranch,
				repository: repository
			))
			ticket.status = .needsReview
			ticketRun.status = .needsReview
			ticketRun.pullRequestURL = pr.url.absoluteString
			ticketRun.summary = finalSummary
			ticketRun.confidence = 0.86
			context.insert(PullRequestRecord(provider: repository.provider, ticketRunID: ticketRun.id, title: pr.title, url: pr.url.absoluteString, branchName: pr.branchName, targetBranch: pr.targetBranch, status: pr.status, checksStatus: pr.checksStatus))
		case .blocked:
			ticket.status = .blocked
			ticketRun.status = .blocked
			ticketRun.summary = finalSummary
			ticketRun.failureReason = "Missing product or runtime context."
			ticketRun.confidence = 0.41
		case .failed:
			ticket.status = .failed
			ticketRun.status = .failed
			ticketRun.summary = finalSummary
			ticketRun.failureReason = "Mock validation failed."
			ticketRun.retryCount += 1
			ticketRun.confidence = 0.32
		}
		ticket.updatedAt = .now
		ticketRun.endedAt = .now
		try context.save()
	}

	private func insertRunFailure(projectID: UUID, message: String, context: ModelContext) throws {
		let run = RunRecord(projectID: projectID, status: .failed, totalTickets: 0, summary: message)
		run.endedAt = .now
		context.insert(run)
		context.insert(RuntimeEventRecord(runID: run.id, level: .error, category: .orchestration, message: message))
		try context.save()
	}
}

extension TicketRecord {
	var descriptor: TicketDescriptor {
		TicketDescriptor(
			provider: provider,
			externalID: externalID,
			title: title,
			body: body,
			status: status,
			labels: labels,
			assignee: assignee,
			priority: priority,
			webURL: URL(string: webURL),
			createdAt: createdAt,
			updatedAt: updatedAt,
			estimatedComplexity: estimatedComplexity,
			blockedBy: blockedBy
		)
	}
}
