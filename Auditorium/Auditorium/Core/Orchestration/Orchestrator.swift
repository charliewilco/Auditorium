import Foundation
import SwiftData

@MainActor
final class Orchestrator {
	private let workspaceService: ApplicationWorkspaceService
	private let runtimeDetection: RuntimeDetectionService
	private let reportGenerator: ReportGenerator
	private let symphonyRunner: SymphonyCLIProcessRunner
	private let mockSourceProvider: any SourceCodeProvider
	private var activeTask: Task<Void, Never>?

	init(
		workspaceService: ApplicationWorkspaceService,
		runtimeDetection: RuntimeDetectionService,
		reportGenerator: ReportGenerator,
		symphonyRunner: SymphonyCLIProcessRunner = SymphonyCLIProcessRunner(),
		mockSourceProvider: (any SourceCodeProvider)? = nil
	) {
		self.workspaceService = workspaceService
		self.runtimeDetection = runtimeDetection
		self.reportGenerator = reportGenerator
		self.symphonyRunner = symphonyRunner
		self.mockSourceProvider = mockSourceProvider ?? MockGitHubRepositoryProvider()
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
		if project.runtimeProviderKind == .localWorkspace, project.agentProviderKind == .codex {
			try await executeWithSymphony(project: project, queueItems: queueItems, concurrency: concurrency, context: context)
			return
		}
		guard project.runtimeProviderKind == .mockRuntime else {
			throw ProviderError.notImplemented("\(project.runtimeProviderKind.title) Runtime Provider")
		}
		guard project.agentProviderKind == .mockAgent else {
			throw ProviderError.notImplemented("\(project.agentProviderKind.title) Agent Provider")
		}
		let plan = OrchestrationRunPlan.make(queueItems: queueItems, requestedConcurrency: concurrency, workflowPolicyMarkdown: project.workflowPolicyMarkdown)
		try workspaceService.ensureProjectLayout(projectID: projectID)

		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		let run = RunRecord(projectID: projectID, status: .running, totalTickets: plan.queueSnapshot.count, summary: "Running \(plan.queueSnapshot.count) queued tickets.")
		context.insert(run)
		context.insert(RuntimeEventRecord(runID: run.id, level: .info, category: .orchestration, message: "Run started with bounded concurrency \(plan.concurrency)."))
		context.insert(RuntimeEventRecord(runID: run.id, level: .info, category: .orchestration, message: "Queue and workflow policy snapshotted for this run."))
		var ticketRuns: [TicketRunRecord] = []
		for item in plan.queueSnapshot {
			let ticketRun = TicketRunRecord(runID: run.id, ticketID: item.ticketID)
			context.insert(ticketRun)
			ticketRuns.append(ticketRun)
		}
		try ModelIntegrityValidator.save(context: context)

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

		for batch in plan.batches {
			context.insert(RuntimeEventRecord(runID: run.id, level: .info, category: .orchestration, message: "Dispatching batch of \(batch.count) ticket runs."))
			try ModelIntegrityValidator.save(context: context)
			for item in batch {
				try Task.checkCancellation()
				guard let ticketRun = ticketRuns.first(where: { $0.ticketID == item.ticketID }),
					  let ticket = tickets.first(where: { $0.id == ticketRun.ticketID }) else {
					continue
				}
				try await processTicket(project: project, repository: repository, ticket: ticket, ticketRun: ticketRun, run: run, runtime: runtime, agent: agent, sourceProvider: mockSourceProvider, context: context, workflowPolicyMarkdown: plan.workflowPolicyMarkdown)
			}
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
		try ModelIntegrityValidator.save(context: context)
	}

	private func executeWithSymphony(project: Project, queueItems: [QueueItemRecord], concurrency: Int, context: ModelContext) async throws {
		let plan = OrchestrationRunPlan.make(queueItems: queueItems, requestedConcurrency: concurrency, workflowPolicyMarkdown: project.workflowPolicyMarkdown)
		try workspaceService.ensureProjectLayout(projectID: project.id)
		let workflowURL = workspaceService.projectDirectory(projectID: project.id).appending(path: "WORKFLOW.md")
		try plan.workflowPolicyMarkdown.write(to: workflowURL, atomically: true, encoding: .utf8)
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		let run = RunRecord(projectID: project.id, status: .running, totalTickets: plan.queueSnapshot.count, summary: "Running \(plan.queueSnapshot.count) queued tickets with symphony.")
		context.insert(run)
		context.insert(RuntimeEventRecord(runID: run.id, level: .info, category: .orchestration, message: "symphony run started."))
		context.insert(RuntimeEventRecord(runID: run.id, level: .info, category: .orchestration, message: "Queue and workflow policy snapshotted for this run."))
		var ticketRuns: [TicketRunRecord] = []
		for item in plan.queueSnapshot {
			let ticketRun = TicketRunRecord(runID: run.id, ticketID: item.ticketID)
			context.insert(ticketRun)
			ticketRuns.append(ticketRun)
		}
		try ModelIntegrityValidator.save(context: context)

		for ticketRun in ticketRuns {
			if Task.isCancelled {
				try cancelSymphonyRun(run: run, ticketRuns: ticketRuns, tickets: tickets, context: context)
				return
			}
			guard let ticket = tickets.first(where: { $0.id == ticketRun.ticketID }) else {
				continue
			}
			ticket.status = .running
			ticketRun.status = .running
			ticketRun.startedAt = .now
			try ModelIntegrityValidator.save(context: context)

			do {
				let issueNumber = try githubIssueNumber(from: ticket.externalID)
				let result = try await symphonyRunner.run(
					repository: project.repositoryName,
					issueNumber: issueNumber,
					workflowPath: workflowURL,
					workspaceRoot: workspaceService.workspacesDirectory(projectID: project.id),
					onEvent: { event in
						context.insert(RuntimeEventRecord(
							runID: run.id,
							ticketRunID: ticketRun.id,
							timestamp: event.timestamp,
							level: EventLevel(rawValue: event.level) ?? .info,
							category: EventCategory(rawValue: event.category) ?? .orchestration,
							message: event.message,
							metadataJSON: event.metadataJSON
						))
						try? ModelIntegrityValidator.save(context: context)
					}
				)
				if result.events.isEmpty {
					context.insert(RuntimeEventRecord(
						runID: run.id,
						ticketRunID: ticketRun.id,
						level: .warning,
						category: .orchestration,
						message: "symphony finished without emitting structured events."
					))
				}
				if let summary = result.summary {
					ticketRun.workspacePath = summary.workspacePath
					ticketRun.branchName = summary.branchName
					ticketRun.pullRequestURL = summary.pullRequestURL
					ticketRun.summary = "symphony finished with status \(summary.status)."
					ticketRun.logPath = summary.reportPath
					if let pullRequestURL = summary.pullRequestURL {
						ticket.status = .needsReview
						ticketRun.status = .needsReview
						context.insert(PullRequestRecord(
							provider: project.repositoryProviderKind,
							ticketRunID: ticketRun.id,
							title: "\(ticket.externalID): \(ticket.title)",
							url: pullRequestURL,
							branchName: summary.branchName,
							targetBranch: project.defaultBranch,
							status: .open,
							checksStatus: .pending
						))
					} else {
						ticket.status = .completed
						ticketRun.status = .completed
					}
					if let markdown = try? String(contentsOf: URL(fileURLWithPath: summary.reportPath), encoding: .utf8) {
						context.insert(ReportRecord(projectID: project.id, runID: run.id, title: "Run \(run.id.uuidString.prefix(8))", markdown: markdown, filePath: summary.reportPath))
					}
				} else {
					ticket.status = .failed
					ticketRun.status = .failed
					ticketRun.failureReason = "symphony did not emit a run summary."
				}
			} catch ProcessCommandError.canceled {
				ticket.status = .canceled
				ticketRun.status = .canceled
				ticketRun.failureReason = "Canceled by user."
				ticket.updatedAt = .now
				ticketRun.endedAt = .now
				context.insert(RuntimeEventRecord(runID: run.id, ticketRunID: ticketRun.id, level: .warning, category: .orchestration, message: "symphony run canceled."))
				try cancelSymphonyRun(run: run, ticketRuns: ticketRuns, tickets: tickets, context: context)
				return
			} catch {
				ticket.status = .failed
				ticketRun.status = .failed
				ticketRun.failureReason = error.localizedDescription
				context.insert(RuntimeEventRecord(runID: run.id, ticketRunID: ticketRun.id, level: .error, category: .orchestration, message: error.localizedDescription))
			}
			ticket.updatedAt = .now
			ticketRun.endedAt = .now
			try ModelIntegrityValidator.save(context: context)
		}

		run.completedTickets = ticketRuns.filter { $0.status == .completed || $0.status == .needsReview }.count
		run.failedTickets = ticketRuns.filter { $0.status == .failed }.count
		run.blockedTickets = ticketRuns.filter { $0.status == .blocked }.count
		run.pullRequestsCreated = ticketRuns.filter { $0.pullRequestURL != nil }.count
		run.endedAt = .now
		run.status = run.failedTickets == 0 ? .completed : .completedWithFailures
		run.summary = "symphony completed \(run.completedTickets) tickets and failed \(run.failedTickets)."
		let finalTickets = try context.fetch(FetchDescriptor<TicketRecord>()).filter { $0.sourceProjectID == project.id }
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>()).filter { $0.runID == run.id }
		let prs = try context.fetch(FetchDescriptor<PullRequestRecord>())
		let markdown = reportGenerator.generate(project: project, run: run, ticketRuns: ticketRuns, tickets: finalTickets, pullRequests: prs, events: events)
		let reportURL = try reportGenerator.save(markdown: markdown, projectID: project.id, runID: run.id, workspace: workspaceService)
		run.reportMarkdown = markdown
		context.insert(ReportRecord(projectID: project.id, runID: run.id, title: "Run \(run.id.uuidString.prefix(8))", markdown: markdown, filePath: reportURL.path()))
		try ModelIntegrityValidator.save(context: context)
	}

	private func cancelSymphonyRun(run: RunRecord, ticketRuns: [TicketRunRecord], tickets: [TicketRecord], context: ModelContext) throws {
		for ticketRun in ticketRuns where ticketRun.status == .pending || ticketRun.status == .preparing || ticketRun.status == .running {
			ticketRun.status = .canceled
			ticketRun.endedAt = .now
			ticketRun.failureReason = "Canceled by user."
			if let ticket = tickets.first(where: { $0.id == ticketRun.ticketID }) {
				ticket.status = .canceled
				ticket.updatedAt = .now
			}
		}
		run.status = .canceled
		run.endedAt = .now
		run.summary = "Run canceled by user."
		context.insert(RuntimeEventRecord(runID: run.id, level: .warning, category: .orchestration, message: "Run canceled by user."))
		try ModelIntegrityValidator.save(context: context)
	}

	private func githubIssueNumber(from externalID: String) throws -> Int {
		let digits = externalID.filter(\.isNumber)
		guard let issueNumber = Int(digits) else {
			throw ProviderError.unavailable("GitHub issue external ID must contain an issue number.")
		}
		return issueNumber
	}

	private func processTicket(
		project: Project,
		repository: RepositoryDescriptor,
		ticket: TicketRecord,
		ticketRun: TicketRunRecord,
		run: RunRecord,
		runtime: MockRuntimeProvider,
		agent: MockCodexAgentProvider,
		sourceProvider: any SourceCodeProvider,
		context: ModelContext,
		workflowPolicyMarkdown: String
	) async throws {
		ticket.status = .running
		ticket.updatedAt = .now
		ticketRun.status = .preparing
		ticketRun.startedAt = .now
		context.insert(RuntimeEventRecord(runID: run.id, ticketRunID: ticketRun.id, level: .info, category: .orchestration, message: "\(ticket.externalID) queued for execution."))
		try ModelIntegrityValidator.save(context: context)

		let descriptor = ticket.descriptor
		let workspace = try await runtime.prepareWorkspace(for: descriptor, repository: repository)
		ticketRun.workspacePath = workspace.path.path()
		ticketRun.containerID = workspace.containerID
		ticketRun.branchName = workspace.branchName
		ticketRun.logPath = workspaceService.logsDirectory(projectID: project.id).appending(path: "\(ticket.externalID).log").path()
		let manifestURL = try workspaceService.writeWorkspaceManifest(
			WorkspaceManifest(
				projectID: project.id,
				runID: run.id,
				ticketRunID: ticketRun.id,
				ticketID: ticket.id,
				ticketExternalID: ticket.externalID,
				repository: repository.fullName,
				workspacePath: workspace.path.path(),
				branchName: workspace.branchName,
				runtimeProvider: project.runtimeProviderKind.rawValue,
				agentProvider: project.agentProviderKind.rawValue,
				createdAt: .now
			),
			workspace: workspace.path
		)
		context.insert(RuntimeEventRecord(runID: run.id, ticketRunID: ticketRun.id, level: .info, category: .runtime, message: "Workspace manifest written to \(manifestURL.path())."))
		ticketRun.status = .running
		let handle = try await runtime.startExecution(RuntimeExecutionRequest(ticket: descriptor, workspace: workspace, policyMarkdown: workflowPolicyMarkdown))
		context.insert(RuntimeEventRecord(runID: run.id, ticketRunID: ticketRun.id, level: .info, category: .runtime, message: "Runtime handle \(handle.id) started."))
		try ModelIntegrityValidator.save(context: context)

		let stream = try await agent.runAgent(AgentRunRequest(ticket: descriptor, repository: repository, workspace: workspace, policyMarkdown: workflowPolicyMarkdown))
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
			try ModelIntegrityValidator.save(context: context)
		}

		switch finalOutcome ?? .completed {
		case .completed:
			let pr = try await sourceProvider.createPullRequest(PullRequestRequest(
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
			context.insert(PullRequestRecord(provider: sourceProvider.kind, ticketRunID: ticketRun.id, title: pr.title, url: pr.url.absoluteString, branchName: pr.branchName, targetBranch: pr.targetBranch, status: pr.status, checksStatus: pr.checksStatus))
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
		try ModelIntegrityValidator.save(context: context)
	}

	private func insertRunFailure(projectID: UUID, message: String, context: ModelContext) throws {
		let run = RunRecord(projectID: projectID, status: .failed, totalTickets: 0, summary: message)
		run.endedAt = .now
		context.insert(run)
		context.insert(RuntimeEventRecord(runID: run.id, level: .error, category: .orchestration, message: message))
		try ModelIntegrityValidator.save(context: context)
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
