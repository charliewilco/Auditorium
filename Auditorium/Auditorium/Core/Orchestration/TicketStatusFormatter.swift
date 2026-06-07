import Foundation

enum TicketStatusFormatter {
	static func markdownStatus(
		ticket: TicketRecord,
		project: Project?,
		queueItem: QueueItemRecord?,
		ticketRun: TicketRunRecord?,
		events: [RuntimeEventRecord]
	) -> String {
		let branch = ticketRun?.branchName.isEmpty == false ? ticketRun?.branchName ?? "None" : "None"
		let pullRequest = ticketRun?.pullRequestURL ?? "None"
		let currentState = currentState(ticket: ticket, ticketRun: ticketRun)
		let timeline =
			events
			.sorted { $0.timestamp < $1.timestamp }
			.suffix(8)
			.map { "- \($0.message) at \($0.timestamp.formatted(date: .omitted, time: .shortened))" }
			.joined(separator: "\n")
		let suggested = suggestedAction(ticket: ticket, ticketRun: ticketRun, queueItem: queueItem)

		return """
			# Ticket Status
			Ticket: \(ticket.externalID) \(ticket.title)
			Status: \(ticket.status.title)
			Repository: \(project?.repositoryName ?? "Unknown")
			Branch: \(branch)
			Pull Request: \(pullRequest)

			## Current State
			\(currentState)

			## Timeline
			\(timeline.isEmpty ? "- No runtime events yet." : timeline)

			## Suggested Action
			\(suggested)
			"""
	}

	private static func currentState(ticket: TicketRecord, ticketRun: TicketRunRecord?) -> String {
		if let ticketRun {
			switch ticketRun.status {
			case .needsReview, .completed:
				return "The agent completed implementation and opened a pull request. Human review is required."
			case .blocked:
				return "The agent is blocked and needs additional human input before it should continue."
			case .failed:
				return "The agent attempted implementation but validation failed."
			case .running, .preparing:
				return "The ticket is actively being processed."
			case .pending:
				return "The ticket has a pending run record."
			case .canceled:
				return "The ticket run was canceled."
			}
		}
		return ticket.status == .queued ? "The ticket is queued and ready to run." : "The ticket is imported but not currently running."
	}

	private static func suggestedAction(ticket: TicketRecord, ticketRun: TicketRunRecord?, queueItem: QueueItemRecord?) -> String {
		if let ticketRun {
			switch ticketRun.status {
			case .needsReview, .completed:
				return "Review the pull request and merge if acceptable."
			case .blocked:
				return "Resolve the missing decision, then retry this ticket."
			case .failed:
				return "Inspect the validation failure and retry after fixing the cause."
			case .running, .preparing:
				return "Watch the run timeline for the next state transition."
			case .pending:
				return "Wait for the orchestrator to start this ticket."
			case .canceled:
				return "Requeue and rerun if the work is still needed."
			}
		}
		return queueItem == nil ? "Add this ticket to the queue." : "Run the queue when ready."
	}
}
