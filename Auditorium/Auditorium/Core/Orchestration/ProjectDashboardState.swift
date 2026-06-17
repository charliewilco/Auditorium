import Foundation

struct ProjectDashboardState: Equatable {
	enum ReadinessKind: Equatable {
		case noProject
		case checking
		case ready
		case blocked
	}

	struct QueuePreviewItem: Identifiable, Equatable {
		let id: UUID
		let ticketID: UUID
		let externalID: String
		let title: String
		let status: TicketStatus
		let priority: PriorityLevel
		let isEnabled: Bool
		let position: Int
	}

	struct ReviewItem: Identifiable, Equatable {
		let id: UUID
		let ticketID: UUID
		let externalID: String
		let title: String
		let status: TicketRunStatus?
		let ticketStatus: TicketStatus
		let reason: String
		let nextAction: String
		let pullRequestURL: String?
	}

	struct RecentOutput: Identifiable, Equatable {
		enum Kind: Equatable {
			case pullRequest
			case report
		}

		let id: UUID
		let kind: Kind
		let title: String
		let detail: String
		let url: String?
		let timestamp: Date
	}

	struct ActiveRun: Identifiable, Equatable {
		let id: UUID
		let title: String
		let summary: String
		let status: RunStatus
		let progress: Double
		let progressText: String
		let runningTicketCount: Int
		let reviewTicketCount: Int
	}

	struct EventSummary: Identifiable, Equatable {
		let id: UUID
		let message: String
		let category: EventCategory
		let level: EventLevel
		let timestamp: Date
	}

	let projectTitle: String
	let repositorySubtitle: String
	let runtimeTitle: String
	let agentTitle: String
	let readinessKind: ReadinessKind
	let readinessTitle: String
	let readinessDetail: String
	let topBlocker: String?
	let validationCommand: String
	let pullRequestPolicy: String
	let openTicketCount: Int
	let queuedTicketCount: Int
	let enabledQueueCount: Int
	let disabledQueueCount: Int
	let runningAgentCount: Int
	let completedTodayCount: Int
	let successRateText: String
	let canRunQueue: Bool
	let activeRun: ActiveRun?
	let activeRunEvents: [EventSummary]
	let queuePreview: [QueuePreviewItem]
	let reviewItems: [ReviewItem]
	let recentOutputs: [RecentOutput]

	init(
		project: Project?,
		tickets: [TicketRecord],
		queueItems: [QueueItemRecord],
		runs: [RunRecord],
		ticketRuns: [TicketRunRecord],
		pullRequests: [PullRequestRecord],
		reports: [ReportRecord],
		events: [RuntimeEventRecord],
		preflightSummary: RunPreflightSummary?,
		now: Date = .now
	) {
		projectTitle = project?.name ?? "No Project"
		repositorySubtitle = project.map { "Orchestrating \($0.repositoryName)" } ?? "Create or select a project to start."
		runtimeTitle = project?.runtimeProviderKind.title ?? "No Runtime"
		agentTitle = project?.agentProviderKind.title ?? "No Agent"
		openTicketCount = tickets.filter { $0.status != .completed && $0.status != .canceled }.count
		queuedTicketCount = queueItems.count
		enabledQueueCount = queueItems.filter(\.isEnabled).count
		disabledQueueCount = queueItems.filter { $0.isEnabled == false }.count
		runningAgentCount = ticketRuns.filter { $0.status == .running || $0.status == .preparing }.count
		completedTodayCount =
			runs.filter { run in
				Calendar.current.isDate(run.startedAt, inSameDayAs: now)
					&& (run.status == .completed || run.status == .completedWithFailures)
			}.count
		successRateText = Self.successRateText(runs: runs)
		canRunQueue = preflightSummary?.canStartRun == true && enabledQueueCount > 0
		validationCommand = preflightSummary?.validationCommand ?? "No validation command available yet."
		pullRequestPolicy =
			preflightSummary.map { $0.opensPullRequests ? "Will open PRs" : "PR creation disabled" }
			?? "Pull request policy unavailable."

		if project == nil {
			readinessKind = .noProject
			readinessTitle = "No Project Selected"
			readinessDetail = "Create or select a project before preparing agent work."
			topBlocker = nil
		}
		else if let blockingCheck = preflightSummary?.blockingChecks.first {
			readinessKind = .blocked
			readinessTitle = "Blocked"
			readinessDetail = blockingCheck.detail
			topBlocker = blockingCheck.title
		}
		else if preflightSummary == nil {
			readinessKind = .checking
			readinessTitle = "Checking Project"
			readinessDetail = "Auditorium is checking workflow, credentials, and local tooling."
			topBlocker = nil
		}
		else if enabledQueueCount == 0 {
			readinessKind = .blocked
			readinessTitle = "Queue Empty"
			readinessDetail = "Add at least one enabled ticket before starting a run."
			topBlocker = "Enabled Tickets"
		}
		else {
			readinessKind = .ready
			readinessTitle = "Ready To Run"
			readinessDetail = "\(enabledQueueCount) enabled ticket\(enabledQueueCount == 1 ? "" : "s") can start now."
			topBlocker = nil
		}

		let ticketsByID = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
		queuePreview =
			queueItems
			.sorted { $0.position < $1.position }
			.compactMap { item in
				guard let ticket = ticketsByID[item.ticketID] else { return nil }
				return QueuePreviewItem(
					id: item.id,
					ticketID: ticket.id,
					externalID: ticket.externalID,
					title: ticket.title,
					status: ticket.status,
					priority: ticket.priority,
					isEnabled: item.isEnabled,
					position: item.position
				)
			}

		let sortedRuns = runs.sorted { $0.startedAt > $1.startedAt }
		if let run = sortedRuns.first(where: { Self.isActiveRun($0.status) }) {
			let relatedTicketRuns = ticketRuns.filter { $0.runID == run.id }
			activeRun = Self.activeRun(from: run, ticketRuns: relatedTicketRuns)
			activeRunEvents =
				events
				.filter { $0.runID == run.id }
				.sorted { $0.timestamp > $1.timestamp }
				.prefix(5)
				.map { event in
					EventSummary(
						id: event.id,
						message: event.message,
						category: event.category,
						level: event.level,
						timestamp: event.timestamp
					)
				}
		}
		else {
			activeRun = nil
			activeRunEvents = []
		}

		reviewItems = Self.reviewItems(tickets: tickets, ticketRuns: ticketRuns, ticketsByID: ticketsByID)
		recentOutputs = Self.recentOutputs(pullRequests: pullRequests, reports: reports)
	}

	private static func successRateText(runs: [RunRecord]) -> String {
		guard runs.isEmpty == false else { return "0%" }
		let completed = runs.filter { $0.status == .completed }.count
		return "\(Int((Double(completed) / Double(runs.count)) * 100))%"
	}

	private static func isActiveRun(_ status: RunStatus) -> Bool {
		switch status {
		case .pending, .running, .paused:
			return true
		case .completed, .completedWithFailures, .canceled, .failed:
			return false
		}
	}

	private static func activeRun(from run: RunRecord, ticketRuns: [TicketRunRecord]) -> ActiveRun {
		let terminalCount = run.completedTickets + run.failedTickets + run.blockedTickets
		let total = max(run.totalTickets, ticketRuns.count)
		let progress = total == 0 ? 0 : Double(terminalCount) / Double(total)
		let reviewCount = ticketRuns.filter { $0.status == .failed || $0.status == .blocked || $0.status == .needsReview }.count
		return ActiveRun(
			id: run.id,
			title: "Run \(run.id.uuidString.prefix(8))",
			summary: run.summary.isEmpty ? "\(total) tickets in flight" : run.summary,
			status: run.status,
			progress: progress,
			progressText: "\(terminalCount) of \(total) finished",
			runningTicketCount: ticketRuns.filter { $0.status == .running || $0.status == .preparing }.count,
			reviewTicketCount: reviewCount
		)
	}

	private static func reviewItems(
		tickets: [TicketRecord],
		ticketRuns: [TicketRunRecord],
		ticketsByID: [UUID: TicketRecord]
	) -> [ReviewItem] {
		var rows: [ReviewItem] = []
		var seenTicketIDs = Set<UUID>()
		let latestRuns = ticketRuns.sorted {
			($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
		}
		for ticketRun in latestRuns where seenTicketIDs.contains(ticketRun.ticketID) == false {
			guard ticketRun.status == .failed || ticketRun.status == .blocked || ticketRun.status == .needsReview,
				let ticket = ticketsByID[ticketRun.ticketID]
			else {
				continue
			}
			seenTicketIDs.insert(ticket.id)
			rows.append(
				ReviewItem(
					id: ticketRun.id,
					ticketID: ticket.id,
					externalID: ticket.externalID,
					title: ticket.title,
					status: ticketRun.status,
					ticketStatus: ticket.status,
					reason: ticketRun.failureReason ?? ticketRun.status.title,
					nextAction: nextAction(for: ticketRun.status),
					pullRequestURL: ticketRun.pullRequestURL
				)
			)
		}

		for ticket in tickets where seenTicketIDs.contains(ticket.id) == false {
			guard ticket.status == .failed || ticket.status == .blocked || ticket.status == .needsReview else {
				continue
			}
			rows.append(
				ReviewItem(
					id: ticket.id,
					ticketID: ticket.id,
					externalID: ticket.externalID,
					title: ticket.title,
					status: nil,
					ticketStatus: ticket.status,
					reason: ticket.status.title,
					nextAction: nextAction(for: ticket.status),
					pullRequestURL: nil
				)
			)
		}
		return Array(rows.prefix(5))
	}

	private static func nextAction(for status: TicketRunStatus) -> String {
		switch status {
		case .failed:
			return "Inspect failure, then retry."
		case .blocked:
			return "Resolve blocker before rerun."
		case .needsReview:
			return "Review PR or report."
		case .pending, .preparing, .running, .completed, .canceled:
			return "Inspect ticket."
		}
	}

	private static func nextAction(for status: TicketStatus) -> String {
		switch status {
		case .failed:
			return "Inspect failure, then retry."
		case .blocked:
			return "Resolve blocker before rerun."
		case .needsReview:
			return "Review output."
		case .backlog, .ready, .queued, .running, .completed, .canceled:
			return "Inspect ticket."
		}
	}

	private static func recentOutputs(pullRequests: [PullRequestRecord], reports: [ReportRecord]) -> [RecentOutput] {
		let pullRequestRows = pullRequests.map { pr in
			RecentOutput(
				id: pr.id,
				kind: .pullRequest,
				title: pr.title,
				detail: "\(pr.status.title) - Checks \(pr.checksStatus.title)",
				url: pr.url,
				timestamp: pr.createdAt
			)
		}
		let reportRows = reports.map { report in
			RecentOutput(
				id: report.id,
				kind: .report,
				title: report.title,
				detail: report.filePath,
				url: nil,
				timestamp: report.createdAt
			)
		}
		return (pullRequestRows + reportRows).sorted { $0.timestamp > $1.timestamp }.prefix(5).map(\.self)
	}
}
