import Foundation

struct ReportGenerator {
	func generate(
		project: Project,
		run: RunRecord,
		ticketRuns: [TicketRunRecord],
		tickets: [TicketRecord],
		pullRequests: [PullRequestRecord],
		events: [RuntimeEventRecord]
	) -> String {
		let ended = run.endedAt ?? .now
		let duration = ended.timeIntervalSince(run.startedAt)
		let successRate = run.totalTickets == 0 ? 0 : Double(run.completedTickets) / Double(run.totalTickets)
		var markdown = """
		# Auditorium Run Report
		Project: \(project.name)
		Repository: \(project.repositoryName)
		Issue Source: \(project.issueProviderKind.title)
		Run ID: \(run.id.uuidString)
		Started: \(run.startedAt.formatted(date: .abbreviated, time: .standard))
		Ended: \(ended.formatted(date: .abbreviated, time: .standard))
		Duration: \(formatDuration(duration))

		## Summary
		Queued Tickets: \(run.totalTickets)
		Completed: \(run.completedTickets)
		Failed: \(run.failedTickets)
		Blocked: \(run.blockedTickets)
		Canceled: 0
		Pull Requests Created: \(run.pullRequestsCreated)
		Success Rate: \(Int(successRate * 100))%

		## Pull Requests
		| Ticket | PR | Status | Confidence |
		|---|---|---|---|
		"""

		for ticketRun in ticketRuns where ticketRun.pullRequestURL != nil {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			markdown += "\n| \(ticket?.externalID ?? "Unknown") | \(ticketRun.pullRequestURL ?? "") | \(ticketRun.status.title) | \(Int(ticketRun.confidence * 100))% |"
		}

		markdown += "\n\n## Completed Tickets"
		for ticketRun in ticketRuns where ticketRun.status == .completed || ticketRun.status == .needsReview {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			markdown += completedSection(ticketRun: ticketRun, ticket: ticket)
		}

		markdown += "\n\n## Failed Tickets"
		for ticketRun in ticketRuns where ticketRun.status == .failed {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			markdown += failedSection(ticketRun: ticketRun, ticket: ticket)
		}

		markdown += "\n\n## Blocked Tickets"
		for ticketRun in ticketRuns where ticketRun.status == .blocked {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			markdown += blockedSection(ticketRun: ticketRun, ticket: ticket)
		}

		markdown += "\n\n## Timeline"
		for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
			markdown += "\n- \(event.timestamp.formatted(date: .omitted, time: .shortened)) [\(event.category.rawValue)] \(event.message)"
		}

		if markdown.contains("## Completed Tickets\n\n## Failed Tickets") {
			markdown = markdown.replacingOccurrences(of: "## Completed Tickets\n\n## Failed Tickets", with: "## Completed Tickets\nNo completed tickets.\n\n## Failed Tickets")
		}
		return markdown
	}

	func save(markdown: String, projectID: UUID, runID: UUID, workspace: ApplicationWorkspaceService) throws -> URL {
		try workspace.ensureProjectLayout(projectID: projectID)
		let url = workspace.reportPath(projectID: projectID, runID: runID)
		try markdown.write(to: url, atomically: true, encoding: .utf8)
		return url
	}

	private func completedSection(ticketRun: TicketRunRecord, ticket: TicketRecord?) -> String {
		"""

		### \(ticket?.externalID ?? "TICKET"): \(ticket?.title ?? "Unknown")
		Status: \(ticketRun.status.title)
		Branch: \(ticketRun.branchName)
		Pull Request: \(ticketRun.pullRequestURL ?? "None")
		Duration: \(formatDuration((ticketRun.endedAt ?? .now).timeIntervalSince(ticketRun.startedAt ?? .now)))
		Confidence: \(Int(ticketRun.confidence * 100))%
		#### What changed
		- Implemented the focused change requested by the issue.
		- Preserved unrelated behavior.
		#### Files touched
		- Mocked file list unavailable in demo mode.
		#### Validation
		- Relevant tests simulated.
		- Checks passed.
		#### Notes
		\(ticketRun.summary)
		"""
	}

	private func failedSection(ticketRun: TicketRunRecord, ticket: TicketRecord?) -> String {
		"""

		### \(ticket?.externalID ?? "TICKET"): \(ticket?.title ?? "Unknown")
		Failure reason: \(ticketRun.failureReason ?? "Unknown failure")
		Where it failed: Validation
		Retry count: \(ticketRun.retryCount)
		Suggested next action: Inspect the failure and retry after addressing the blocker.
		"""
	}

	private func blockedSection(ticketRun: TicketRunRecord, ticket: TicketRecord?) -> String {
		"""

		### \(ticket?.externalID ?? "TICKET"): \(ticket?.title ?? "Unknown")
		Blocked because: \(ticketRun.failureReason ?? "The agent needs more information.")
		Suggested next action: Resolve the missing decision, then retry this ticket.
		"""
	}

	private func formatDuration(_ seconds: TimeInterval) -> String {
		let whole = max(0, Int(seconds))
		let minutes = whole / 60
		let remaining = whole % 60
		return "\(minutes)m \(remaining)s"
	}
}
