import Foundation

struct ReportGenerator {
	func generate(
		project: Project,
		run: RunRecord,
		ticketRuns: [TicketRunRecord],
		tickets: [TicketRecord],
		pullRequests: [PullRequestRecord],
		events: [RuntimeEventRecord],
		coordinationMessages: [CoordinationMessageRecord] = []
	) -> String {
		let ended = run.endedAt ?? .now
		let duration = ended.timeIntervalSince(run.startedAt)
		let successRate = run.totalTickets == 0 ? 0 : Double(run.completedTickets) / Double(run.totalTickets)
		let canceled = ticketRuns.filter { $0.status == .canceled }.count
		var markdown = """
			# Auditorium Run Report
			Project: \(project.name)
			Repository: \(project.repositoryName)
			Issue Source: \(project.issueProviderKind.title)
			Run ID: \(run.id.uuidString)
			Run Status: \(run.status.title)
			Started: \(run.startedAt.formatted(date: .abbreviated, time: .standard))
			Ended: \(ended.formatted(date: .abbreviated, time: .standard))
			Duration: \(formatDuration(duration))
			Run Summary: \(valueOrNone(run.summary))

			## Summary
			Queued Tickets: \(run.totalTickets)
			Completed: \(run.completedTickets)
			Failed: \(run.failedTickets)
			Blocked: \(run.blockedTickets)
			Canceled: \(canceled)
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
			markdown +=
				"\n| \(ticket?.externalID ?? "Unknown") | \(pullRequest?.url ?? ticketRun.pullRequestURL ?? "") | \(pullRequest?.status.title ?? "Unknown") | \(pullRequest?.checksStatus.title ?? "Unknown") | \(ticketRun.status.title) | \(Int(ticketRun.confidence * 100))% |"
			pullRequestRows += 1
		}
		if pullRequestRows == 0 {
			markdown += "\n| None | None | None | None | None | 0% |"
		}

		markdown += coordinationSection(messages: coordinationMessages, tickets: tickets)
		markdown += "\n\n## Completed Tickets"
		for ticketRun in ticketRuns where ticketRun.status == .completed || ticketRun.status == .needsReview {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			let pullRequest = pullRequests.first { $0.ticketRunID == ticketRun.id }
			markdown += completedSection(ticketRun: ticketRun, ticket: ticket, pullRequest: pullRequest, events: events)
		}

		markdown += "\n\n## Failed Tickets"
		for ticketRun in ticketRuns where ticketRun.status == .failed {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			markdown += failedSection(ticketRun: ticketRun, ticket: ticket, events: events)
		}

		markdown += "\n\n## Blocked Tickets"
		for ticketRun in ticketRuns where ticketRun.status == .blocked {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			markdown += blockedSection(ticketRun: ticketRun, ticket: ticket, events: events)
		}

		markdown += "\n\n## Canceled Tickets"
		for ticketRun in ticketRuns where ticketRun.status == .canceled {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			markdown += canceledSection(ticketRun: ticketRun, ticket: ticket, events: events)
		}

		markdown += suggestedActionsSection(ticketRuns: ticketRuns, tickets: tickets, pullRequests: pullRequests)

		markdown += "\n\n## Timeline"
		for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
			markdown += "\n- \(event.timestamp.formatted(date: .omitted, time: .shortened)) [\(event.category.rawValue)] \(event.message)"
		}

		if markdown.contains("## Completed Tickets\n\n## Failed Tickets") {
			markdown = markdown.replacingOccurrences(
				of: "## Completed Tickets\n\n## Failed Tickets",
				with: "## Completed Tickets\nNo completed tickets.\n\n## Failed Tickets"
			)
		}
		if markdown.contains("## Failed Tickets\n\n## Blocked Tickets") {
			markdown = markdown.replacingOccurrences(
				of: "## Failed Tickets\n\n## Blocked Tickets",
				with: "## Failed Tickets\nNo failed tickets.\n\n## Blocked Tickets"
			)
		}
		if markdown.contains("## Blocked Tickets\n\n## Canceled Tickets") {
			markdown = markdown.replacingOccurrences(
				of: "## Blocked Tickets\n\n## Canceled Tickets",
				with: "## Blocked Tickets\nNo blocked tickets.\n\n## Canceled Tickets"
			)
		}
		if markdown.contains("## Canceled Tickets\n\n## Suggested Actions") {
			markdown = markdown.replacingOccurrences(
				of: "## Canceled Tickets\n\n## Suggested Actions",
				with: "## Canceled Tickets\nNo canceled tickets.\n\n## Suggested Actions"
			)
		}
		return markdown
	}

	func save(markdown: String, projectID: UUID, runID: UUID, workspace: ApplicationWorkspaceService) throws -> URL {
		try workspace.ensureProjectLayout(projectID: projectID)
		let url = workspace.reportPath(projectID: projectID, runID: runID)
		try markdown.write(to: url, atomically: true, encoding: .utf8)
		return url
	}

	private func completedSection(
		ticketRun: TicketRunRecord,
		ticket: TicketRecord?,
		pullRequest: PullRequestRecord?,
		events: [RuntimeEventRecord]
	) -> String {
		let ticketEvents = eventsForTicketRun(ticketRun, events: events)
		return """

			### \(ticket?.externalID ?? "TICKET"): \(ticket?.title ?? "Unknown")
			Status: \(ticketRun.status.title)
			Summary: \(valueOrNone(ticketRun.summary))
			Branch: \(valueOrNone(ticketRun.branchName))
			Workspace: \(valueOrNone(ticketRun.workspacePath))
			Log: \(valueOrNone(ticketRun.logPath))
			Pull Request: \(ticketRun.pullRequestURL ?? "None")
			PR Status: \(pullRequest?.status.title ?? "None")
			Checks: \(pullRequest?.checksStatus.title ?? "None")
			Retry Count: \(ticketRun.retryCount)
			Duration: \(formatDuration((ticketRun.endedAt ?? .now).timeIntervalSince(ticketRun.startedAt ?? .now)))
			Confidence: \(Int(ticketRun.confidence * 100))%
			#### Evidence
			- Workspace: \(valueOrNone(ticketRun.workspacePath))
			- Log: \(valueOrNone(ticketRun.logPath))
			- Recorded Events: \(ticketEvents.count)
			- Last Event: \(lastEventSummary(ticketEvents))
			#### Validation
			- Pull Request Checks: \(pullRequest?.checksStatus.title ?? "Not recorded")
			- Ticket Run Status: \(ticketRun.status.title)
			#### Notes
			\(valueOrNone(ticketRun.summary))
			"""
	}

	private func failedSection(ticketRun: TicketRunRecord, ticket: TicketRecord?, events: [RuntimeEventRecord]) -> String {
		let ticketEvents = eventsForTicketRun(ticketRun, events: events)
		return """

			### \(ticket?.externalID ?? "TICKET"): \(ticket?.title ?? "Unknown")
			Failure reason: \(ticketRun.failureReason ?? "Unknown failure")
			Where it failed: \(lastEventSummary(ticketEvents))
			Workspace: \(valueOrNone(ticketRun.workspacePath))
			Log: \(valueOrNone(ticketRun.logPath))
			Branch: \(valueOrNone(ticketRun.branchName))
			Summary: \(valueOrNone(ticketRun.summary))
			Retry count: \(ticketRun.retryCount)
			Recorded Events: \(ticketEvents.count)
			Suggested next action: Inspect the failure and retry after addressing the blocker.
			"""
	}

	private func blockedSection(ticketRun: TicketRunRecord, ticket: TicketRecord?, events: [RuntimeEventRecord]) -> String {
		let ticketEvents = eventsForTicketRun(ticketRun, events: events)
		return """

			### \(ticket?.externalID ?? "TICKET"): \(ticket?.title ?? "Unknown")
			Blocked because: \(ticketRun.failureReason ?? "The agent needs more information.")
			Workspace: \(valueOrNone(ticketRun.workspacePath))
			Log: \(valueOrNone(ticketRun.logPath))
			Branch: \(valueOrNone(ticketRun.branchName))
			Summary: \(valueOrNone(ticketRun.summary))
			Recorded Events: \(ticketEvents.count)
			Suggested next action: Resolve the missing decision, then retry this ticket.
			"""
	}

	private func canceledSection(ticketRun: TicketRunRecord, ticket: TicketRecord?, events: [RuntimeEventRecord]) -> String {
		let ticketEvents = eventsForTicketRun(ticketRun, events: events)
		return """

			### \(ticket?.externalID ?? "TICKET"): \(ticket?.title ?? "Unknown")
			Canceled because: \(ticketRun.failureReason ?? "Canceled by user.")
			Workspace: \(valueOrNone(ticketRun.workspacePath))
			Log: \(valueOrNone(ticketRun.logPath))
			Branch: \(valueOrNone(ticketRun.branchName))
			Recorded Events: \(ticketEvents.count)
			Suggested next action: Review any partial workspace changes before retrying.
			"""
	}

	private func suggestedActionsSection(ticketRuns: [TicketRunRecord], tickets: [TicketRecord], pullRequests: [PullRequestRecord]) -> String {
		var actions: [String] = []
		for ticketRun in ticketRuns {
			let ticket = tickets.first { $0.id == ticketRun.ticketID }
			let label = "\(ticket?.externalID ?? "TICKET"): \(ticket?.title ?? "Unknown")"
			switch ticketRun.status {
			case .failed:
				actions.append(
					"- \(label): inspect failure reason `\(ticketRun.failureReason ?? "Unknown failure")`, fix the underlying issue, then retry."
				)
			case .blocked:
				actions.append(
					"- \(label): resolve the blocker `\(ticketRun.failureReason ?? "Needs more information")`, then retry."
				)
			case .completed where ticketRun.pullRequestURL == nil:
				actions.append("- \(label): review the run summary because the agent completed without opening a pull request.")
			case .needsReview:
				if let pullRequest = pullRequests.first(where: { $0.ticketRunID == ticketRun.id }),
					pullRequest.checksStatus == .failed
				{
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

	private func coordinationSection(messages: [CoordinationMessageRecord], tickets: [TicketRecord]) -> String {
		guard messages.isEmpty == false else {
			return "\n\n## Cross-ticket Findings\nNo cross-ticket findings were recorded."
		}
		var markdown = "\n\n## Cross-ticket Findings"
		for message in messages.sorted(by: { $0.createdAt < $1.createdAt }) {
			let sourceTicket = tickets.first { githubIssueNumber(from: $0.externalID) == message.sourceIssueNumber }
			let source = sourceTicket.map { "\($0.externalID): \($0.title)" } ?? "#\(message.sourceIssueNumber)"
			let target = message.targetIssueNumber.map { "#\($0)" } ?? "run"
			let changedFiles = message.changedFiles.isEmpty ? "No changed files recorded." : message.changedFiles.joined(separator: ", ")
			markdown += "\n- [\(message.kindRaw)] \(source) -> \(target): \(message.summary) Changed files: \(changedFiles)"
		}
		return markdown
	}

	private func formatDuration(_ seconds: TimeInterval) -> String {
		let whole = max(0, Int(seconds))
		let minutes = whole / 60
		let remaining = whole % 60
		return "\(minutes)m \(remaining)s"
	}

	private func valueOrNone(_ value: String) -> String {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? "None" : trimmed
	}

	private func eventsForTicketRun(_ ticketRun: TicketRunRecord, events: [RuntimeEventRecord]) -> [RuntimeEventRecord] {
		events
			.filter { $0.ticketRunID == ticketRun.id }
			.sorted { $0.timestamp < $1.timestamp }
	}

	private func lastEventSummary(_ events: [RuntimeEventRecord]) -> String {
		guard let event = events.last else {
			return "No ticket events recorded"
		}
		return "[\(event.category.rawValue)] \(event.message)"
	}

	private func githubIssueNumber(from externalID: String) -> Int? {
		let trimmed = externalID.trimmingCharacters(in: .whitespacesAndNewlines)
		if let number = Int(trimmed) {
			return number
		}
		if trimmed.hasPrefix("#"), let number = Int(trimmed.dropFirst()) {
			return number
		}
		return nil
	}
}
