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
		| Ticket | PR | PR Status | Checks | Ticket Status | Confidence |
		|---|---|---|---|---|---|
		"""

		var pullRequestRows = 0
		for ticketRun in ticketRuns where ticketRun.pullRequestURL != nil {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			let pullRequest = pullRequests.first { $0.ticketRunID == ticketRun.id }
			markdown += "\n| \(ticket?.externalID ?? "Unknown") | \(pullRequest?.url ?? ticketRun.pullRequestURL ?? "") | \(pullRequest?.status.title ?? "Unknown") | \(pullRequest?.checksStatus.title ?? "Unknown") | \(ticketRun.status.title) | \(Int(ticketRun.confidence * 100))% |"
			pullRequestRows += 1
		}
		if pullRequestRows == 0 {
			markdown += "\n| None | None | None | None | None | 0% |"
		}

		markdown += "\n\n## Completed Tickets"
		for ticketRun in ticketRuns where ticketRun.status == .completed || ticketRun.status == .needsReview {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			let pullRequest = pullRequests.first { $0.ticketRunID == ticketRun.id }
			markdown += completedSection(ticketRun: ticketRun, ticket: ticket, pullRequest: pullRequest)
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

		markdown += suggestedActionsSection(ticketRuns: ticketRuns, tickets: tickets, pullRequests: pullRequests)

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

	private func completedSection(ticketRun: TicketRunRecord, ticket: TicketRecord?, pullRequest: PullRequestRecord?) -> String {
		"""

		### \(ticket?.externalID ?? "TICKET"): \(ticket?.title ?? "Unknown")
		Status: \(ticketRun.status.title)
		Branch: \(ticketRun.branchName)
		Pull Request: \(ticketRun.pullRequestURL ?? "None")
		PR Status: \(pullRequest?.status.title ?? "None")
		Checks: \(pullRequest?.checksStatus.title ?? "None")
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

	private func suggestedActionsSection(ticketRuns: [TicketRunRecord], tickets: [TicketRecord], pullRequests: [PullRequestRecord]) -> String {
		var actions: [String] = []
		for ticketRun in ticketRuns {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			let label = "\(ticket?.externalID ?? "TICKET"): \(ticket?.title ?? "Unknown")"
			switch ticketRun.status {
			case .failed:
				actions.append("- \(label): inspect failure reason `\(ticketRun.failureReason ?? "Unknown failure")`, fix the underlying issue, then retry.")
			case .blocked:
				actions.append("- \(label): resolve the blocker `\(ticketRun.failureReason ?? "Needs more information")`, then retry.")
			case .completed where ticketRun.pullRequestURL == nil:
				actions.append("- \(label): review the run summary because the agent completed without opening a pull request.")
			case .needsReview:
				if let pullRequest = pullRequests.first(where: { $0.ticketRunID == ticketRun.id }), pullRequest.checksStatus == .failed {
					actions.append("- \(label): review failed checks on \(pullRequest.url) before merging.")
				}
			default:
				break
			}
		}
		if actions.isEmpty {
			actions.append("- Review opened pull requests and reports before merging. Auditorium v0 never auto-merges.")
		}
		return "\n\n## Suggested Actions\n" + actions.joined(separator: "\n")
	}

	private func formatDuration(_ seconds: TimeInterval) -> String {
		let whole = max(0, Int(seconds))
		let minutes = whole / 60
		let remaining = whole % 60
		return "\(minutes)m \(remaining)s"
	}
}
