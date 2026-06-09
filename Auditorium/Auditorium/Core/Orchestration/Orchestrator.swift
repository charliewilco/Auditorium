import Foundation
import SwiftData

@MainActor
final class Orchestrator {
	private let workspaceService: ApplicationWorkspaceService
	private let runtimeDetection: RuntimeDetectionService
	private let reportGenerator: ReportGenerator
	private let symphonyRunner: SymphonyCLIProcessRunner
	private let environmentSecretService: ProjectEnvironmentSecretService
	private let providerRegistry: ProviderRegistry?
	private let mockSourceProvider: any SourceCodeProvider
	private let mockAgentProvider: any AgentProvider
	private let localWorkspaceSourceProvider: (any SourceCodeProvider)?
	private let codexAgentProvider: any AgentProvider
	private let usesSymphonyForLocalWorkspaceCodex: Bool
	private var activeTask: Task<Void, Never>?

	private struct RunLifecycle {
		let plan: OrchestrationRunPlan
		let tickets: [TicketRecord]
		let run: RunRecord
		let ticketRuns: [TicketRunRecord]
	}

	init(
		workspaceService: ApplicationWorkspaceService,
		runtimeDetection: RuntimeDetectionService,
		reportGenerator: ReportGenerator,
		symphonyRunner: SymphonyCLIProcessRunner = SymphonyCLIProcessRunner(),
		environmentSecretService: ProjectEnvironmentSecretService? = nil,
		providerRegistry: ProviderRegistry? = nil,
		mockSourceProvider: (any SourceCodeProvider)? = nil,
		mockAgentProvider: (any AgentProvider)? = nil,
		localWorkspaceSourceProvider: (any SourceCodeProvider)? = nil,
		codexAgentProvider: (any AgentProvider)? = nil,
		usesSymphonyForLocalWorkspaceCodex: Bool = false
	) {
		self.workspaceService = workspaceService
		self.runtimeDetection = runtimeDetection
		self.reportGenerator = reportGenerator
		self.symphonyRunner = symphonyRunner
		self.environmentSecretService = environmentSecretService ?? ProjectEnvironmentSecretService()
		self.providerRegistry = providerRegistry
		self.mockSourceProvider = mockSourceProvider ?? MockGitHubRepositoryProvider()
		self.mockAgentProvider = mockAgentProvider ?? MockCodexAgentProvider()
		self.localWorkspaceSourceProvider = localWorkspaceSourceProvider
		self.codexAgentProvider = codexAgentProvider ?? CodexCLIProcessAgentProvider()
		self.usesSymphonyForLocalWorkspaceCodex = usesSymphonyForLocalWorkspaceCodex
	}

	func runQueue(projectID: UUID, concurrency: Int, context: ModelContext) {
		activeTask?.cancel()
		activeTask = Task {
			do {
				try await execute(projectID: projectID, concurrency: concurrency, context: context)
			}
			catch is CancellationError {
			}
			catch ProcessCommandError.canceled {
			}
			catch {
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
			if usesSymphonyForLocalWorkspaceCodex == false, providerRegistry != nil || localWorkspaceSourceProvider != nil {
				try await executeWithLocalWorkspaceCodex(
					project: project,
					queueItems: queueItems,
					concurrency: concurrency,
					context: context
				)
				return
			}
			try await executeWithSymphony(project: project, queueItems: queueItems, concurrency: concurrency, context: context)
			return
		}
		guard project.runtimeProviderKind == .mockRuntime else {
			throw ProviderError.notImplemented("\(project.runtimeProviderKind.title) Runtime Provider")
		}
		guard project.agentProviderKind == .mockAgent else {
			throw ProviderError.notImplemented("\(project.agentProviderKind.title) Agent Provider")
		}
		let plan = OrchestrationRunPlan.make(
			queueItems: queueItems,
			requestedConcurrency: concurrency,
			workflowPolicyMarkdown: project.workflowPolicyMarkdown
		)
		try workspaceService.ensureProjectLayout(projectID: projectID)
		let runtime = MockRuntimeProvider(workspaceService: workspaceService, projectID: projectID)
		try await executeProviderBatches(
			project: project,
			plan: plan,
			context: context,
			repository: repositoryDescriptor(for: project),
			runtime: runtime,
			agent: mockAgentProvider,
			sourceProvider: mockSourceProvider,
			runSummary: "Running \(plan.queueSnapshot.count) queued tickets.",
			startEventMessage: "Run started with bounded concurrency \(plan.concurrency).",
			batchEvent: { "Dispatching batch of \($0.count) ticket runs." },
			commitAndPush: false
		)
	}

	private func executeWithLocalWorkspaceCodex(project: Project, queueItems: [QueueItemRecord], concurrency: Int, context: ModelContext)
		async throws
	{
		let plan = OrchestrationRunPlan.make(
			queueItems: queueItems,
			requestedConcurrency: concurrency,
			workflowPolicyMarkdown: project.workflowPolicyMarkdown
		)
		let sourceProvider = try await resolveLocalWorkspaceSourceProvider(project: project, context: context)
		let repository = repositoryDescriptor(for: project)
		let policy = try WorkflowPolicyParser().parse(plan.workflowPolicyMarkdown)
		try workspaceService.ensureProjectLayout(projectID: project.id)
		let runtime = LocalProcessRuntimeProvider(
			workspaceService: workspaceService,
			projectID: project.id,
			sourceProvider: sourceProvider,
			branchPrefix: policy.branchPrefix
		)
		try await executeProviderBatches(
			project: project,
			plan: plan,
			context: context,
			repository: repository,
			runtime: runtime,
			agent: codexAgentProvider,
			sourceProvider: sourceProvider,
			runSummary: "Running \(plan.queueSnapshot.count) queued tickets with Local Workspace and Codex.",
			startEventMessage: "Local Workspace Codex run started with bounded concurrency \(plan.concurrency).",
			batchEvent: { "Dispatching batch of \($0.count) local ticket runs." },
			commitAndPush: true
		)
	}

	private func executeWithSymphony(project: Project, queueItems: [QueueItemRecord], concurrency: Int, context: ModelContext) async throws {
		let plan = OrchestrationRunPlan.make(
			queueItems: queueItems,
			requestedConcurrency: concurrency,
			workflowPolicyMarkdown: project.workflowPolicyMarkdown
		)
		try workspaceService.ensureProjectLayout(projectID: project.id)
		let workflowURL = workspaceService.projectDirectory(projectID: project.id).appending(path: "WORKFLOW.md")
		try plan.workflowPolicyMarkdown.write(to: workflowURL, atomically: true, encoding: .utf8)
		let lifecycle = try prepareRunLifecycle(
			project: project,
			plan: plan,
			context: context,
			summary: "Running \(plan.queueSnapshot.count) queued tickets with symphony.",
			startEventMessage: "symphony run started."
		)
		let tickets = lifecycle.tickets
		let run = lifecycle.run
		let ticketRuns = lifecycle.ticketRuns

		var ticketsByIssueNumber: [Int: TicketRecord] = [:]
		var ticketRunsByIssueNumber: [Int: TicketRunRecord] = [:]
		for ticketRun in ticketRuns {
			guard let ticket = tickets.first(where: { $0.id == ticketRun.ticketID }) else {
				continue
			}
			let issueNumber = try githubIssueNumber(from: ticket.externalID)
			ticketsByIssueNumber[issueNumber] = ticket
			ticketRunsByIssueNumber[issueNumber] = ticketRun
			ticket.status = .running
			ticketRun.status = .running
			ticketRun.startedAt = .now
		}
		try ModelIntegrityValidator.save(context: context)

		do {
			let environment = try await symphonyEnvironment(project: project, context: context)
			let result = try await symphonyRunner.runQueue(
				repository: project.repositoryName,
				issueNumbers: Array(ticketRunsByIssueNumber.keys).sorted(),
				workflowPath: workflowURL,
				workspaceRoot: workspaceService.workspacesDirectory(projectID: project.id),
				environment: environment,
				onEvent: { event in
					let issueNumber = Self.issueNumber(from: event)
					context.insert(
						RuntimeEventRecord(
							runID: run.id,
							ticketRunID: issueNumber.flatMap { ticketRunsByIssueNumber[$0]?.id },
							timestamp: event.timestamp,
							level: EventLevel(rawValue: event.level) ?? .info,
							category: EventCategory(rawValue: event.category) ?? .orchestration,
							message: event.message,
							metadataJSON: event.metadataJSON
						)
					)
					try? ModelIntegrityValidator.save(context: context)
				},
				onCoordinationMessage: { message in
					context.insert(
						CoordinationMessageRecord(
							runID: run.id,
							ticketRunID: ticketRunsByIssueNumber[message.sourceIssue]?.id,
							externalMessageID: message.coordinationMessageID,
							sourceIssueNumber: message.sourceIssue,
							targetIssueNumber: message.targetIssue,
							kind: message.kind,
							summary: message.summary,
							changedFiles: message.changedFiles,
							labels: message.labels,
							keywords: message.keywords,
							workspacePath: message.workspacePath ?? "",
							branchName: message.branchName ?? "",
							createdAt: message.createdAt
						)
					)
					try? ModelIntegrityValidator.save(context: context)
				}
			)
			if result.events.isEmpty {
				context.insert(
					RuntimeEventRecord(
						runID: run.id,
						level: .warning,
						category: .orchestration,
						message: "symphony finished without emitting structured events."
					)
				)
			}
			for summary in result.summaries {
				guard let issueNumber = summary.issueNumber,
					let ticketRun = ticketRunsByIssueNumber[issueNumber],
					let ticket = ticketsByIssueNumber[issueNumber]
				else {
					continue
				}
				ticketRun.workspacePath = summary.workspacePath
				ticketRun.branchName = summary.branchName
				ticketRun.pullRequestURL = summary.pullRequestURL
				ticketRun.summary = "symphony finished with status \(summary.status)."
				ticketRun.logPath = summary.reportPath
				ticketRun.endedAt = .now
				if let pullRequestURL = summary.pullRequestURL {
					ticket.status = .needsReview
					ticketRun.status = .needsReview
					context.insert(
						PullRequestRecord(
							provider: project.repositoryProviderKind,
							ticketRunID: ticketRun.id,
							title: "\(ticket.externalID): \(ticket.title)",
							url: pullRequestURL,
							branchName: summary.branchName,
							targetBranch: project.defaultBranch,
							status: .open,
							checksStatus: .pending
						)
					)
				}
				else {
					ticket.status = .completed
					ticketRun.status = .completed
				}
				if let markdown = try? String(contentsOf: URL(fileURLWithPath: summary.reportPath), encoding: .utf8) {
					context.insert(
						ReportRecord(
							projectID: project.id,
							runID: run.id,
							title: "Run \(run.id.uuidString.prefix(8))",
							markdown: markdown,
							filePath: summary.reportPath
						)
					)
				}
			}
			let summarizedIssueNumbers = Set(result.summaries.compactMap(\.issueNumber))
			for issueNumber in ticketRunsByIssueNumber.keys where summarizedIssueNumbers.contains(issueNumber) == false {
				ticketRunsByIssueNumber[issueNumber]?.status = .failed
				ticketRunsByIssueNumber[issueNumber]?.failureReason = "symphony did not emit a run summary."
				ticketRunsByIssueNumber[issueNumber]?.endedAt = .now
				ticketsByIssueNumber[issueNumber]?.status = .failed
			}
			for ticket in ticketsByIssueNumber.values {
				ticket.updatedAt = .now
			}
			try ModelIntegrityValidator.save(context: context)
		}
		catch ProcessCommandError.canceled {
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					level: .warning,
					category: .orchestration,
					message: "symphony queue run canceled."
				)
			)
			try cancelRun(run: run, ticketRuns: ticketRuns, tickets: tickets, context: context)
			return
		}
		catch {
			let failureReason = symphonyFailureReason(error: error, runID: run.id, context: context)
			for ticketRun in ticketRuns where ticketRun.status == .running || ticketRun.status == .pending {
				ticketRun.status = .failed
				ticketRun.failureReason = failureReason
				ticketRun.endedAt = .now
				tickets.first { $0.id == ticketRun.ticketID }?.status = .failed
			}
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					level: .error,
					category: .orchestration,
					message: failureReason
				)
			)
			try ModelIntegrityValidator.save(context: context)
		}

		try finalizeRun(
			project: project,
			run: run,
			ticketRuns: ticketRuns,
			context: context,
			insertReportEvent: false,
			summary: { "symphony completed \($0.completedTickets) tickets and failed \($0.failedTickets)." }
		)
	}

	private func symphonyFailureReason(error: Error, runID: UUID, context: ModelContext) -> String {
		let base = error.localizedDescription
		let events = (try? context.fetch(FetchDescriptor<RuntimeEventRecord>())) ?? []
		let failureEvents = events.filter {
			$0.runID == runID && $0.message == "queue_ticket_failed" && $0.metadataJSON != "{}"
		}
		guard let metadata = failureEvents.last?.metadataJSON else {
			return base
		}
		return "\(base)\nLatest symphony failure metadata: \(metadata)"
	}

	private func executeProviderBatches(
		project: Project,
		plan: OrchestrationRunPlan,
		context: ModelContext,
		repository: RepositoryDescriptor,
		runtime: any RuntimeProvider,
		agent: any AgentProvider,
		sourceProvider: any SourceCodeProvider,
		runSummary: String,
		startEventMessage: String,
		batchEvent: ([QueueRunSnapshot]) -> String,
		commitAndPush: Bool
	) async throws {
		let lifecycle = try prepareRunLifecycle(
			project: project,
			plan: plan,
			context: context,
			summary: runSummary,
			startEventMessage: startEventMessage
		)

		do {
			for batch in plan.batches {
				context.insert(
					RuntimeEventRecord(
						runID: lifecycle.run.id,
						level: .info,
						category: .orchestration,
						message: batchEvent(batch)
					)
				)
				try ModelIntegrityValidator.save(context: context)
				try await processBatchWithRecovery(
					batch,
					project: project,
					repository: repository,
					tickets: lifecycle.tickets,
					ticketRuns: lifecycle.ticketRuns,
					run: lifecycle.run,
					runtime: runtime,
					agent: agent,
					sourceProvider: sourceProvider,
					context: context,
					workflowPolicyMarkdown: plan.workflowPolicyMarkdown,
					retryPolicy: plan.retryPolicy,
					commitAndPush: commitAndPush
				)
			}
		}
		catch is CancellationError {
			try cancelRun(run: lifecycle.run, ticketRuns: lifecycle.ticketRuns, tickets: lifecycle.tickets, context: context)
			return
		}
		catch ProcessCommandError.canceled {
			try cancelRun(run: lifecycle.run, ticketRuns: lifecycle.ticketRuns, tickets: lifecycle.tickets, context: context)
			return
		}

		try finalizeRun(
			project: project,
			run: lifecycle.run,
			ticketRuns: lifecycle.ticketRuns,
			context: context,
			insertReportEvent: true,
			summary: { "Completed \($0.completedTickets), failed \($0.failedTickets), blocked \($0.blockedTickets)." }
		)
	}

	private func prepareRunLifecycle(
		project: Project,
		plan: OrchestrationRunPlan,
		context: ModelContext,
		summary: String,
		startEventMessage: String
	) throws -> RunLifecycle {
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		let run = RunRecord(
			projectID: project.id,
			status: .running,
			totalTickets: plan.queueSnapshot.count,
			workflowPolicySnapshotMarkdown: plan.workflowPolicyMarkdown,
			summary: summary
		)
		run.queueSnapshot = plan.queueSnapshot
		context.insert(run)
		context.insert(RuntimeEventRecord(runID: run.id, level: .info, category: .orchestration, message: startEventMessage))
		context.insert(
			RuntimeEventRecord(
				runID: run.id,
				level: .info,
				category: .orchestration,
				message: "Queue and workflow policy snapshotted for this run."
			)
		)
		var ticketRuns: [TicketRunRecord] = []
		for item in plan.queueSnapshot {
			let ticketRun = TicketRunRecord(runID: run.id, ticketID: item.ticketID)
			context.insert(ticketRun)
			ticketRuns.append(ticketRun)
		}
		try ModelIntegrityValidator.save(context: context)
		return RunLifecycle(plan: plan, tickets: tickets, run: run, ticketRuns: ticketRuns)
	}

	private func finalizeRun(
		project: Project,
		run: RunRecord,
		ticketRuns: [TicketRunRecord],
		context: ModelContext,
		insertReportEvent: Bool,
		summary: (RunRecord) -> String
	) throws {
		run.completedTickets = ticketRuns.filter { $0.status == .completed || $0.status == .needsReview }.count
		run.failedTickets = ticketRuns.filter { $0.status == .failed }.count
		run.blockedTickets = ticketRuns.filter { $0.status == .blocked }.count
		run.pullRequestsCreated = ticketRuns.filter { $0.pullRequestURL != nil }.count
		run.endedAt = .now
		run.status = aggregateRunStatus(completed: run.completedTickets, failed: run.failedTickets, blocked: run.blockedTickets)
		run.summary = summary(run)
		if insertReportEvent {
			context.insert(RuntimeEventRecord(runID: run.id, level: .success, category: .report, message: "Generating markdown report."))
		}

		let finalTickets = try context.fetch(FetchDescriptor<TicketRecord>()).filter { $0.sourceProjectID == project.id }
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>()).filter { $0.runID == run.id }
		let coordinationMessages = try context.fetch(FetchDescriptor<CoordinationMessageRecord>()).filter { $0.runID == run.id }
		let prs = try context.fetch(FetchDescriptor<PullRequestRecord>())
		let markdown = reportGenerator.generate(
			project: project,
			run: run,
			ticketRuns: ticketRuns,
			tickets: finalTickets,
			pullRequests: prs,
			events: events,
			coordinationMessages: coordinationMessages
		)
		let reportURL = try reportGenerator.save(markdown: markdown, projectID: project.id, runID: run.id, workspace: workspaceService)
		run.reportMarkdown = markdown
		context.insert(
			ReportRecord(
				projectID: project.id,
				runID: run.id,
				title: "Run \(run.id.uuidString.prefix(8))",
				markdown: markdown,
				filePath: reportURL.path()
			)
		)
		try ModelIntegrityValidator.save(context: context)
	}

	private func symphonyEnvironment(project: Project, context: ModelContext) async throws -> [String: String] {
		guard let providerRegistry else { return [:] }
		let token = try await providerRegistry.requireGitHubToken(
			for: project,
			context: context,
			operation: "running GitHub source-code operations"
		)
		return [
			"GH_TOKEN": token,
			"GITHUB_TOKEN": token,
		]
	}

	private func cancelRun(run: RunRecord, ticketRuns: [TicketRunRecord], tickets: [TicketRecord], context: ModelContext) throws {
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
		run.completedTickets = ticketRuns.filter { $0.status == .completed || $0.status == .needsReview }.count
		run.failedTickets = ticketRuns.filter { $0.status == .failed }.count
		run.blockedTickets = ticketRuns.filter { $0.status == .blocked }.count
		run.pullRequestsCreated = ticketRuns.filter { $0.pullRequestURL != nil }.count
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

	private static func issueNumber(from event: SymphonyCLIEvent) -> Int? {
		if let issue = event.issue {
			return issue
		}
		guard let data = event.metadataJSON.data(using: .utf8),
			let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let value = metadata["issue"]
		else {
			return nil
		}
		if let number = value as? Int {
			return number
		}
		if let string = value as? String {
			let digits = string.filter(\.isNumber)
			return Int(digits)
		}
		return nil
	}

	private func resolveLocalWorkspaceSourceProvider(project: Project, context: ModelContext) async throws -> any SourceCodeProvider {
		if let localWorkspaceSourceProvider {
			return localWorkspaceSourceProvider
		}
		guard let providerRegistry else {
			throw ProviderError.unavailable("A source-code provider is required for Local Workspace runs.")
		}
		return try await providerRegistry.sourceCodeProvider(for: project, context: context)
	}

	private func repositoryDescriptor(for project: Project) -> RepositoryDescriptor {
		RepositoryDescriptor(
			provider: project.repositoryProviderKind,
			owner: String(project.repositoryName.split(separator: "/").first ?? "charlie"),
			name: String(project.repositoryName.split(separator: "/").last ?? project.repositoryName[...]),
			fullName: project.repositoryName,
			cloneURL: URL(string: project.repositoryURL.hasSuffix(".git") ? project.repositoryURL : "\(project.repositoryURL).git")
				?? URL(fileURLWithPath: project.repositoryURL),
			webURL: URL(string: project.repositoryURL) ?? URL(fileURLWithPath: project.repositoryURL),
			defaultBranch: project.defaultBranch
		)
	}

	private func processTicket(
		project: Project,
		repository: RepositoryDescriptor,
		ticket: TicketRecord,
		ticketRun: TicketRunRecord,
		run: RunRecord,
		runtime: any RuntimeProvider,
		agent: any AgentProvider,
		sourceProvider: any SourceCodeProvider,
		context: ModelContext,
		workflowPolicyMarkdown: String,
		commitAndPush: Bool = false
	) async throws {
		let policy = try WorkflowPolicyParser().parse(workflowPolicyMarkdown)
		ticket.status = .running
		ticket.updatedAt = .now
		ticketRun.status = .preparing
		ticketRun.startedAt = .now
		ticketRun.endedAt = nil
		ticketRun.failureReason = nil
		context.insert(
			RuntimeEventRecord(
				runID: run.id,
				ticketRunID: ticketRun.id,
				level: .info,
				category: .orchestration,
				message: "\(ticket.externalID) queued for execution."
			)
		)
		try ModelIntegrityValidator.save(context: context)

		let descriptor = ticket.descriptor
		let workspace = try await runtime.prepareWorkspace(for: descriptor, repository: repository)
		ticketRun.workspacePath = workspace.path.path()
		ticketRun.runtimeID = workspace.runtimeID
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
		context.insert(
			RuntimeEventRecord(
				runID: run.id,
				ticketRunID: ticketRun.id,
				level: .info,
				category: .runtime,
				message: "Workspace manifest written to \(manifestURL.path())."
			)
		)
		ticketRun.status = .running
		let runtimeEnvironment = try nonRetryableSync {
			try environmentSecretService.resolveEnabledEnvironment(projectID: project.id, context: context)
		}
		let handle = try await runtime.startExecution(
			RuntimeExecutionRequest(
				ticket: descriptor,
				workspace: workspace,
				policyMarkdown: workflowPolicyMarkdown,
				environment: runtimeEnvironment
			)
		)
		context.insert(
			RuntimeEventRecord(
				runID: run.id,
				ticketRunID: ticketRun.id,
				level: .info,
				category: .runtime,
				message: "Runtime handle \(handle.id) started."
			)
		)
		try ModelIntegrityValidator.save(context: context)

		let stream = try await agent.runAgent(
			AgentRunRequest(ticket: descriptor, repository: repository, workspace: workspace, policyMarkdown: workflowPolicyMarkdown)
		)
		var finalOutcome: MockTicketOutcome?
		var finalSummary = ""
		for try await event in stream {
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					level: event.level,
					category: event.category,
					message: event.message,
					metadataJSON: event.metadataJSON ?? "{}"
				)
			)
			if let logPath = event.logPath {
				ticketRun.logPath = logPath
			}
			if let summary = event.summary {
				finalSummary = summary
			}
			if let outcome = event.outcome {
				finalOutcome = outcome
			}
			try ModelIntegrityValidator.save(context: context)
		}
		try Task.checkCancellation()

		switch finalOutcome ?? .completed {
		case .completed:
			try await runWorkflowValidationIfNeeded(
				policy: policy,
				workspace: workspace,
				ticketRun: ticketRun,
				run: run,
				context: context
			)
			if commitAndPush {
				let didCommit = try await nonRetryableAsync {
					try await sourceProvider.commitChanges(
						in: workspace.path,
						message: "\(ticket.externalID): \(ticket.title)"
					)
				}
				if didCommit == false {
					ticket.status = .completed
					ticketRun.status = .completed
					ticketRun.summary = finalSummary.isEmpty ? "Agent completed without file changes." : finalSummary
					ticketRun.confidence = 0.72
					context.insert(
						RuntimeEventRecord(
							runID: run.id,
							ticketRunID: ticketRun.id,
							level: .warning,
							category: .git,
							message: "Agent completed without file changes; no pull request was opened."
						)
					)
					break
				}
				context.insert(
					RuntimeEventRecord(
						runID: run.id,
						ticketRunID: ticketRun.id,
						level: .info,
						category: .git,
						message: "Committed agent changes on \(workspace.branchName)."
					)
				)
				try await nonRetryableAsync {
					try await sourceProvider.pushBranch(named: workspace.branchName, from: workspace.path)
				}
				context.insert(
					RuntimeEventRecord(
						runID: run.id,
						ticketRunID: ticketRun.id,
						level: .info,
						category: .git,
						message: "Pushed \(workspace.branchName)."
					)
				)
			}
			if policy.openPullRequest == false {
				ticket.status = .completed
				ticketRun.status = .completed
				ticketRun.summary =
					finalSummary.isEmpty ? "Agent completed; pull request creation disabled by workflow policy." : finalSummary
				ticketRun.confidence = 0.78
				context.insert(
					RuntimeEventRecord(
						runID: run.id,
						ticketRunID: ticketRun.id,
						level: .info,
						category: .orchestration,
						message: "Workflow policy disabled pull request creation for \(ticket.externalID)."
					)
				)
				break
			}
			let pullRequestRequest = PullRequestRequest(
				title: "\(ticket.externalID): \(ticket.title)",
				body: finalSummary,
				branchName: workspace.branchName,
				targetBranch: project.defaultBranch,
				repository: repository
			)
			try nonRetryableSync {
				try PullRequestReviewPolicy().validate(pullRequestRequest)
			}
			let pr = try await nonRetryableAsync {
				try await sourceProvider.createPullRequest(pullRequestRequest)
			}
			ticket.status = .needsReview
			ticketRun.status = .needsReview
			ticketRun.pullRequestURL = pr.url.absoluteString
			ticketRun.summary = finalSummary
			ticketRun.confidence = 0.86
			context.insert(
				PullRequestRecord(
					provider: sourceProvider.kind,
					ticketRunID: ticketRun.id,
					title: pr.title,
					url: pr.url.absoluteString,
					branchName: pr.branchName,
					targetBranch: pr.targetBranch,
					status: pr.status,
					checksStatus: pr.checksStatus
				)
			)
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

	private func runWorkflowValidationIfNeeded(
		policy: ParsedWorkflowPolicy,
		workspace: WorkspaceDescriptor,
		ticketRun: TicketRunRecord,
		run: RunRecord,
		context: ModelContext
	) async throws {
		guard policy.runTests else {
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					level: .info,
					category: .tests,
					message: "Workflow policy disabled validation."
				)
			)
			try ModelIntegrityValidator.save(context: context)
			return
		}
		guard let command = policy.validationCommand else {
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					level: .warning,
					category: .tests,
					message: "Workflow policy requested validation but no validation.command was configured."
				)
			)
			try ModelIntegrityValidator.save(context: context)
			return
		}
		context.insert(
			RuntimeEventRecord(
				runID: run.id,
				ticketRunID: ticketRun.id,
				level: .info,
				category: .tests,
				message: "Running workflow validation command."
			)
		)
		try ModelIntegrityValidator.save(context: context)
		let result = try await ProcessCommand.runStreaming(
			executable: "/bin/sh",
			arguments: ["-lc", command],
			workingDirectory: workspace.path,
			allowsNonZeroExit: true
		)
		if result.standardOutput.isEmpty == false {
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					level: .info,
					category: .tests,
					message: "validation_stdout: \(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
				)
			)
		}
		if result.standardError.isEmpty == false {
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					level: .warning,
					category: .tests,
					message: "validation_stderr: \(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))"
				)
			)
		}
		guard result.exitCode == 0 else {
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					level: .error,
					category: .tests,
					message: "Workflow validation failed with exit code \(result.exitCode)."
				)
			)
			try ModelIntegrityValidator.save(context: context)
			throw ProcessCommandError.failed(
				executable: "/bin/sh",
				arguments: ["-lc", command],
				exitCode: result.exitCode,
				stderr: result.standardError
			)
		}
		context.insert(
			RuntimeEventRecord(
				runID: run.id,
				ticketRunID: ticketRun.id,
				level: .success,
				category: .tests,
				message: "Workflow validation passed."
			)
		)
		try ModelIntegrityValidator.save(context: context)
	}

	private func processTicketWithRecovery(
		project: Project,
		repository: RepositoryDescriptor,
		ticket: TicketRecord,
		ticketRun: TicketRunRecord,
		run: RunRecord,
		runtime: any RuntimeProvider,
		agent: any AgentProvider,
		sourceProvider: any SourceCodeProvider,
		context: ModelContext,
		workflowPolicyMarkdown: String,
		retryPolicy: RetryPolicy,
		commitAndPush: Bool = false
	) async throws {
		while true {
			try Task.checkCancellation()
			do {
				try await processTicket(
					project: project,
					repository: repository,
					ticket: ticket,
					ticketRun: ticketRun,
					run: run,
					runtime: runtime,
					agent: agent,
					sourceProvider: sourceProvider,
					context: context,
					workflowPolicyMarkdown: workflowPolicyMarkdown,
					commitAndPush: commitAndPush
				)
			}
			catch is CancellationError {
				throw CancellationError()
			}
			catch ProcessCommandError.canceled(let executable, let arguments) {
				throw ProcessCommandError.canceled(executable: executable, arguments: arguments)
			}
			catch let error as NonRetryableTicketFailure {
				markTicketRunFailed(ticket: ticket, ticketRun: ticketRun, run: run, error: error, context: context)
				try ModelIntegrityValidator.save(context: context)
				return
			}
			catch {
				markTicketRunFailed(ticket: ticket, ticketRun: ticketRun, run: run, error: error, context: context)
				try ModelIntegrityValidator.save(context: context)
			}
			guard retryPolicy.shouldRetry(status: ticketRun.status, retryCount: ticketRun.retryCount) else {
				return
			}
			let retryAttempt = ticketRun.retryCount
			let backoffMilliseconds = retryPolicy.backoffMilliseconds(for: max(0, retryAttempt - 1))
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					level: .warning,
					category: .orchestration,
					message: "Retrying \(ticket.externalID) after failed attempt \(retryAttempt) of \(retryPolicy.maxRetries).",
					metadataJSON: #"{"retryAttempt":\#(retryAttempt),"backoffMilliseconds":\#(backoffMilliseconds)}"#
				)
			)
			try ModelIntegrityValidator.save(context: context)
			if backoffMilliseconds > 0 {
				try await Task.sleep(nanoseconds: UInt64(backoffMilliseconds) * 1_000_000)
			}
		}
	}

	private func processBatchWithRecovery(
		_ batch: [QueueRunSnapshot],
		project: Project,
		repository: RepositoryDescriptor,
		tickets: [TicketRecord],
		ticketRuns: [TicketRunRecord],
		run: RunRecord,
		runtime: any RuntimeProvider,
		agent: any AgentProvider,
		sourceProvider: any SourceCodeProvider,
		context: ModelContext,
		workflowPolicyMarkdown: String,
		retryPolicy: RetryPolicy,
		commitAndPush: Bool = false
	) async throws {
		try await withThrowingTaskGroup(of: Void.self) { group in
			for item in batch {
				guard let ticketRun = ticketRuns.first(where: { $0.ticketID == item.ticketID }),
					let ticket = tickets.first(where: { $0.id == ticketRun.ticketID })
				else {
					continue
				}
				group.addTask { @MainActor in
					try Task.checkCancellation()
					try await self.processTicketWithRecovery(
						project: project,
						repository: repository,
						ticket: ticket,
						ticketRun: ticketRun,
						run: run,
						runtime: runtime,
						agent: agent,
						sourceProvider: sourceProvider,
						context: context,
						workflowPolicyMarkdown: workflowPolicyMarkdown,
						retryPolicy: retryPolicy,
						commitAndPush: commitAndPush
					)
				}
			}

			do {
				try await group.waitForAll()
			}
			catch {
				group.cancelAll()
				throw error
			}
		}
	}

	private func markTicketRunFailed(ticket: TicketRecord, ticketRun: TicketRunRecord, run: RunRecord, error: Error, context: ModelContext) {
		let message = error.localizedDescription
		ticket.status = .failed
		ticket.updatedAt = .now
		ticketRun.status = .failed
		ticketRun.failureReason = message
		ticketRun.retryCount += 1
		ticketRun.endedAt = .now
		ticketRun.confidence = 0
		context.insert(
			RuntimeEventRecord(
				runID: run.id,
				ticketRunID: ticketRun.id,
				level: .error,
				category: .orchestration,
				message: "Ticket \(ticket.externalID) failed: \(message)"
			)
		)
	}

	private func aggregateRunStatus(completed: Int, failed: Int, blocked: Int) -> RunStatus {
		if failed == 0 && blocked == 0 {
			return .completed
		}
		if completed == 0 {
			return .failed
		}
		return .completedWithFailures
	}

	private func nonRetryableSync<T>(_ operation: () throws -> T) throws -> T {
		do {
			return try operation()
		}
		catch {
			throw NonRetryableTicketFailure(underlying: error)
		}
	}

	private func nonRetryableAsync<T>(_ operation: () async throws -> T) async throws -> T {
		do {
			return try await operation()
		}
		catch {
			throw NonRetryableTicketFailure(underlying: error)
		}
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

private struct NonRetryableTicketFailure: LocalizedError {
	let underlying: Error

	var errorDescription: String? {
		underlying.localizedDescription
	}
}
