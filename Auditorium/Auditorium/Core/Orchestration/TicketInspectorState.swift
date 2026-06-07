import Foundation

struct TicketInspectorState: Equatable {
	let queueState: String
	let latestRunState: String
	let workspace: String
	let container: String
	let branch: String
	let pullRequest: String
	let confidence: String
	let failureText: String
	let nextAction: String
	let timelineMessages: [String]
	let canAddToQueue: Bool
	let canRemoveFromQueue: Bool
	let canRunTicket: Bool
	let canRetryTicket: Bool
	let canCancelRun: Bool
	let canOpenIssueTracker: Bool
	let canOpenPullRequest: Bool
	let canRevealWorkspace: Bool

	init(
		ticket: TicketRecord,
		queueItem: QueueItemRecord?,
		latestRun: TicketRunRecord?,
		events: [RuntimeEventRecord]
	) {
		queueState = queueItem.map { "Position \($0.position + 1)" } ?? "Not queued"
		latestRunState = latestRun?.status.title ?? "No run"
		workspace = latestRun?.workspacePath.isEmpty == false ? latestRun?.workspacePath ?? "None" : "None"
		container = latestRun?.containerID.isEmpty == false ? latestRun?.containerID ?? "None" : "None"
		branch = latestRun?.branchName.isEmpty == false ? latestRun?.branchName ?? "None" : "None"
		pullRequest = latestRun?.pullRequestURL ?? "None"
		confidence = latestRun == nil ? "None" : "\(Int((latestRun?.confidence ?? 0) * 100))%"
		failureText = latestRun?.failureReason ?? "No failure recorded."
		nextAction = Self.nextAction(ticket: ticket, queueItem: queueItem, latestRun: latestRun)
		timelineMessages = events.sorted { $0.timestamp < $1.timestamp }.map(\.message)
		canAddToQueue = queueItem == nil
		canRemoveFromQueue = queueItem != nil
		canCancelRun = latestRun.map { Self.isCancelable($0.status) } ?? false
		canRunTicket = canCancelRun == false
		canRetryTicket = latestRun.map { Self.isRetryable($0.status) } ?? false
		canOpenIssueTracker = Self.hasWebURL(ticket.webURL)
		canOpenPullRequest = latestRun?.pullRequestURL.map(Self.hasWebURL) ?? false
		canRevealWorkspace = latestRun?.workspacePath.isEmpty == false
	}

	private static func nextAction(ticket: TicketRecord, queueItem: QueueItemRecord?, latestRun: TicketRunRecord?) -> String {
		if latestRun?.status == .needsReview {
			return "Review the pull request and merge if acceptable."
		}
		if latestRun?.status == .blocked {
			return "Resolve the missing context, then retry."
		}
		if latestRun?.status == .failed {
			return "Inspect validation failure and retry."
		}
		return queueItem == nil ? "Add this ticket to the queue." : "Run the queue when ready."
	}

	private nonisolated static func isCancelable(_ status: TicketRunStatus) -> Bool {
		switch status {
		case .pending, .preparing, .running:
			return true
		case .blocked, .needsReview, .completed, .failed, .canceled:
			return false
		}
	}

	private nonisolated static func isRetryable(_ status: TicketRunStatus) -> Bool {
		switch status {
		case .blocked, .failed, .canceled:
			return true
		case .pending, .preparing, .running, .needsReview, .completed:
			return false
		}
	}

	private nonisolated static func hasWebURL(_ value: String) -> Bool {
		guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
			return false
		}
		return scheme == "http" || scheme == "https"
	}
}
