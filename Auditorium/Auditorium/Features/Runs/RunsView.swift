import SwiftUI

struct RunsView: View {
	@Environment(AppState.self) private var appState
	let runs: [RunRecord]
	let ticketRuns: [TicketRunRecord]
	let tickets: [TicketRecord]
	let events: [RuntimeEventRecord]
	let coordinationMessages: [CoordinationMessageRecord]
	let pullRequests: [PullRequestRecord]
	let reports: [ReportRecord]

	var body: some View {
		NavigationSplitView {
			List(runs, selection: Binding(get: { appState.selectedRunID }, set: { appState.selectedRunID = $0 })) { run in
				VStack(alignment: .leading, spacing: 4) {
					HStack {
						Text(run.startedAt, format: .dateTime.month().day().hour().minute())
						Spacer()
						StatusBadge(title: run.status.title, tint: run.status.tint)
					}
					Text(run.summary.isEmpty ? "\(run.totalTickets) tickets" : run.summary)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				.tag(run.id)
			}
			.frame(minWidth: 260)
		} detail: {
			if let run = selectedRun {
				RunDetailView(
					run: run,
					ticketRuns: ticketRuns.filter { $0.runID == run.id },
					tickets: tickets,
					events: events.filter { $0.runID == run.id },
					coordinationMessages: coordinationMessages.filter { $0.runID == run.id },
					pullRequests: pullRequests,
					reports: reports.filter { $0.runID == run.id }
				)
			}
			else {
				EmptyStateView(
					symbol: "play.circle.fill",
					title: "No Run Selected",
					message: "Start a queue run to see live execution details.",
					recoverySuggestion:
						"Runs stream ticket progress, workspace paths, PR links, and report previews as events arrive.",
					actionTitle: "Open Queue",
					action: { appState.selectedDestination = .queue }
				)
			}
		}
		.navigationTitle("Runs")
		.onAppear {
			if appState.selectedRunID == nil {
				appState.selectedRunID = runs.first?.id
			}
		}
	}

	private var selectedRun: RunRecord? {
		guard let id = appState.selectedRunID else { return runs.first }
		return runs.first { $0.id == id }
	}
}

struct RunDetailView: View {
	let run: RunRecord
	let ticketRuns: [TicketRunRecord]
	let tickets: [TicketRecord]
	let events: [RuntimeEventRecord]
	let coordinationMessages: [CoordinationMessageRecord]
	let pullRequests: [PullRequestRecord]
	let reports: [ReportRecord]

	var progress: Double {
		guard run.totalTickets > 0 else { return 0 }
		let done = run.completedTickets + run.failedTickets + run.blockedTickets
		return Double(done) / Double(run.totalTickets)
	}

	var state: RunDetailState {
		RunDetailState(ticketRuns: ticketRuns, tickets: tickets, pullRequests: pullRequests)
	}

	var reviewPacket: RunReviewPacket {
		RunReviewPacket.make(
			run: run,
			ticketRuns: ticketRuns,
			tickets: tickets,
			events: events,
			coordinationMessages: coordinationMessages,
			pullRequests: pullRequests,
			reports: reports
		)
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				HStack {
					VStack(alignment: .leading) {
						Text("Run \(run.id.uuidString.prefix(8))")
							.font(.largeTitle.weight(.semibold))
						Text(run.summary)
							.foregroundStyle(.secondary)
					}
					Spacer()
					StatusBadge(title: run.status.title, tint: run.status.tint)
				}
				ProgressView(value: progress)
				reviewPacketSection
				LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
					StatCard(title: "Total Tickets", value: "\(run.totalTickets)", symbol: "ticket", tint: .blue)
					StatCard(title: "Completed", value: "\(run.completedTickets)", symbol: "checkmark.circle.fill", tint: .green)
					StatCard(title: "Failed", value: "\(run.failedTickets)", symbol: "xmark.octagon.fill", tint: .red)
					StatCard(title: "Blocked", value: "\(run.blockedTickets)", symbol: "hand.raised.fill", tint: .yellow)
					StatCard(
						title: "PRs Created",
						value: "\(run.pullRequestsCreated)",
						symbol: "arrow.triangle.pull",
						tint: .indigo
					)
				}
				crossTicketFindings
				pullRequestsSection
				ticketExecutionList
				timeline
				reportPreview
			}
			.padding()
		}
	}

	private var crossTicketFindings: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Cross-ticket Findings")
				.font(.headline)
			if coordinationMessages.isEmpty {
				Text("No coordination notes have been recorded for this run.")
					.foregroundStyle(.secondary)
			}
			else {
				ForEach(coordinationMessages.sorted { $0.createdAt < $1.createdAt }) { message in
					CoordinationMessageRow(message: message, ticket: ticketForIssue(message.sourceIssueNumber))
				}
			}
		}
		.padding()
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private var reviewPacketSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Text("Review Packet")
					.font(.headline)
				Spacer()
				StatusBadge(
					title: reviewPacket.pullRequests.isEmpty ? "Report" : "\(reviewPacket.pullRequests.count) PRs",
					tint: .indigo
				)
			}
			Text(reviewPacket.nextAction)
				.font(.callout.weight(.medium))
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
				ReviewPacketValue(title: "Validation", value: reviewPacket.validationSummary)
				ReviewPacketValue(
					title: "Changed Files",
					value: reviewPacket.changedFiles.isEmpty
						? "No changed files recorded." : reviewPacket.changedFiles.joined(separator: ", ")
				)
				ReviewPacketValue(title: "Failed Tickets", value: "\(reviewPacket.failedTickets.count)")
				ReviewPacketValue(title: "Blocked Tickets", value: "\(reviewPacket.blockedTickets.count)")
				ReviewPacketValue(title: "Report", value: reviewPacket.reportTitle ?? "No report saved yet.")
			}
			if reviewPacket.failedTickets.isEmpty == false || reviewPacket.blockedTickets.isEmpty == false {
				VStack(alignment: .leading, spacing: 6) {
					ForEach(reviewPacket.failedTickets + reviewPacket.blockedTickets) { ticket in
						HStack(alignment: .top) {
							StatusBadge(title: ticket.status.title, tint: ticket.status.tint)
							VStack(alignment: .leading, spacing: 2) {
								Text("\(ticket.externalID): \(ticket.title)")
									.font(.caption.weight(.semibold))
								if let failureReason = ticket.failureReason, failureReason.isEmpty == false {
									Text(failureReason)
										.font(.caption)
										.foregroundStyle(.secondary)
										.lineLimit(3)
								}
							}
						}
					}
				}
			}
		}
		.padding()
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private var pullRequestsSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Pull Requests")
				.font(.headline)
			if state.pullRequestRows.isEmpty {
				Text("No pull requests have been recorded for this run.")
					.foregroundStyle(.secondary)
			}
			else {
				ForEach(state.pullRequestRows) { row in
					HStack(alignment: .top, spacing: 12) {
						Image(systemName: "arrow.triangle.pull")
							.foregroundStyle(.indigo)
							.frame(width: 20)
						VStack(alignment: .leading, spacing: 4) {
							Text("\(row.ticketExternalID): \(row.pullRequestTitle)")
								.font(.callout.weight(.medium))
							Text(row.ticketTitle)
								.font(.caption)
								.foregroundStyle(.secondary)
							Text(row.routeText)
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
						VStack(alignment: .trailing, spacing: 6) {
							Text(row.statusText)
								.font(.caption.weight(.medium))
							Text("Checks: \(row.checksStatusText)")
								.font(.caption)
								.foregroundStyle(.secondary)
							if let url = URL(string: row.url) {
								Link("Open PR", destination: url)
							}
						}
					}
					.padding(10)
					.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
				}
			}
		}
	}

	private var ticketExecutionList: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Ticket Executions")
				.font(.headline)
			ForEach(ticketRuns) { ticketRun in
				let ticket = tickets.first { $0.id == ticketRun.ticketID }
				let related = relatedMessages(for: ticketRun, ticket: ticket)
				VStack(alignment: .leading, spacing: 8) {
					HStack {
						VStack(alignment: .leading, spacing: 4) {
							Text(ticket?.title ?? "Unknown Ticket")
								.font(.callout.weight(.medium))
							Text(
								"\(ticketRun.branchName.isEmpty ? "No branch yet" : ticketRun.branchName) • \(ticketRun.runtimeID.isEmpty ? "No runtime yet" : ticketRun.runtimeID)"
							)
							.font(.caption)
							.foregroundStyle(.secondary)
							Text(phaseText(for: ticketRun))
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
						if let url = ticketRun.pullRequestURL, let link = URL(string: url) {
							Link("PR", destination: link)
						}
						Text("Retry \(ticketRun.retryCount)")
							.foregroundStyle(.secondary)
						Text("\(Int(ticketRun.confidence * 100))%")
							.frame(width: 44, alignment: .trailing)
						StatusBadge(title: ticketRun.status.title, tint: ticketRun.status.tint)
					}
					if related.isEmpty == false {
						VStack(alignment: .leading, spacing: 6) {
							Text("Related Notes")
								.font(.caption.weight(.semibold))
								.foregroundStyle(.secondary)
							ForEach(related) { message in
								CoordinationMessageRow(
									message: message,
									ticket: ticketForIssue(message.sourceIssueNumber)
								)
							}
						}
					}
				}
				.padding(10)
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
			}
		}
	}

	private var timeline: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Timeline")
				.font(.headline)
			ForEach(events.sorted { $0.timestamp < $1.timestamp }) { event in
				TimelineRow(event: event)
			}
		}
		.padding()
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private var reportPreview: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Generated Report Preview")
				.font(.headline)
			ScrollView {
				Text(run.reportMarkdown.isEmpty ? "Report will appear when the run completes." : run.reportMarkdown)
					.font(.system(.body, design: .monospaced))
					.frame(maxWidth: .infinity, alignment: .leading)
					.textSelection(.enabled)
			}
			.frame(minHeight: 180)
		}
		.padding()
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private func relatedMessages(for ticketRun: TicketRunRecord, ticket: TicketRecord?) -> [CoordinationMessageRecord] {
		let issueNumber = ticket.flatMap { githubIssueNumber(from: $0.externalID) }
		return
			coordinationMessages
			.filter { message in
				message.ticketRunID == ticketRun.id || (issueNumber != nil && message.targetIssueNumber == issueNumber)
			}
			.sorted { $0.createdAt < $1.createdAt }
	}

	private func ticketForIssue(_ issueNumber: Int) -> TicketRecord? {
		tickets.first { githubIssueNumber(from: $0.externalID) == issueNumber }
	}

	private func phaseText(for ticketRun: TicketRunRecord) -> String {
		let ticketEvents = events.filter { $0.ticketRunID == ticketRun.id }
		if ticketRun.pullRequestURL != nil || ticketEvents.contains(where: { $0.category == .pullRequest }) {
			return "Phase: pull request ready"
		}
		if ticketEvents.contains(where: { $0.category == .git && $0.message.localizedCaseInsensitiveContains("push") }) {
			return "Phase: branch pushed"
		}
		if ticketEvents.contains(where: { $0.category == .tests || $0.message.localizedCaseInsensitiveContains("validation") }) {
			return "Phase: validation"
		}
		if ticketEvents.contains(where: { $0.category == .agent }) {
			return "Phase: agent running"
		}
		if ticketRun.workspacePath.isEmpty == false || ticketEvents.contains(where: { $0.category == .runtime }) {
			return "Phase: workspace prepared"
		}
		return "Phase: pending"
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

private struct ReviewPacketValue: View {
	let title: String
	let value: String

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title)
				.font(.caption.weight(.semibold))
				.foregroundStyle(.secondary)
			Text(value)
				.font(.caption)
				.lineLimit(3)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

private struct CoordinationMessageRow: View {
	let message: CoordinationMessageRecord
	let ticket: TicketRecord?

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: symbol)
				.foregroundStyle(.teal)
				.frame(width: 18)
			VStack(alignment: .leading, spacing: 3) {
				Text("\(message.kindRaw.replacingOccurrences(of: "_", with: " ").capitalized) from \(sourceTitle)")
					.font(.caption.weight(.semibold))
				Text(message.summary)
					.font(.caption)
				if message.changedFiles.isEmpty == false {
					Text(message.changedFiles.joined(separator: ", "))
						.font(.caption2)
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}
			}
			Spacer()
			if let targetIssueNumber = message.targetIssueNumber {
				Text("-> #\(targetIssueNumber)")
					.font(.caption2.weight(.medium))
					.foregroundStyle(.secondary)
			}
		}
	}

	private var sourceTitle: String {
		if let ticket {
			"\(ticket.externalID): \(ticket.title)"
		}
		else {
			"#\(message.sourceIssueNumber)"
		}
	}

	private var symbol: String {
		switch message.kindRaw {
		case "changed_files": "doc.on.doc"
		case "blocked_on": "hand.raised"
		case "risk": "exclamationmark.triangle"
		case "handoff": "arrow.triangle.branch"
		case "summary": "text.badge.checkmark"
		default: "lightbulb"
		}
	}
}
