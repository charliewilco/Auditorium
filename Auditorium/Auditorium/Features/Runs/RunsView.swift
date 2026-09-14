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
	let reportBacks: [TicketReportBackRecord]
	let containerRuns: [ContainerRunRecord]
	let dispatcherRuns: [DispatcherRunRecord]
	let retryReportBacks: () -> Void
	let recoverInterruptedWork: () -> Void
	let recoverInterruptedWorkAndRun: () -> Void

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
					reports: reports.filter { $0.runID == run.id },
					reportBacks: reportBacks,
					containerRuns: containerRuns.filter { $0.runID == run.id },
					dispatcherRun: dispatcherRuns.first { $0.runID == run.id }
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
		.toolbar {
			Button(action: recoverInterruptedWorkAndRun) {
				Label("Recover and Run", systemImage: "play.circle")
			}
			.disabled(runs.isEmpty)
			Button(action: recoverInterruptedWork) {
				Label("Recover Queue", systemImage: "arrow.uturn.backward.circle")
			}
			.disabled(runs.isEmpty)
			Button(action: retryReportBacks) {
				Label("Retry Report-backs", systemImage: "arrow.clockwise")
			}
			.disabled(runs.isEmpty)
		}
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
	let reportBacks: [TicketReportBackRecord]
	let containerRuns: [ContainerRunRecord]
	let dispatcherRun: DispatcherRunRecord?

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

	var workbench: ReviewWorkbenchState {
		ReviewWorkbenchState.make(
			ticketRuns: ticketRuns,
			tickets: tickets,
			events: events,
			coordinationMessages: coordinationMessages,
			pullRequests: pullRequests,
			reportBacks: reportBacks,
			containerRuns: containerRuns
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
				dispatcherSection
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

	private var dispatcherSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Text("Dispatcher")
					.font(.headline)
				Spacer()
				if let dispatcherRun {
					StatusBadge(title: dispatcherRun.status.title, tint: dispatcherTint(dispatcherRun.status))
				}
				else {
					StatusBadge(title: "No State", tint: .secondary)
				}
			}
			if let dispatcherRun {
				LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
					ReviewPacketValue(title: "Selected", value: "\(dispatcherRun.selectedCount)")
					ReviewPacketValue(title: "Pending", value: "\(dispatcherRun.pendingCount)")
					ReviewPacketValue(title: "Running", value: "\(dispatcherRun.runningCount)")
					ReviewPacketValue(title: "Terminal", value: "\(dispatcherRun.terminalCount)")
					ReviewPacketValue(title: "Skipped", value: "\(dispatcherRun.skippedCount)")
					ReviewPacketValue(
						title: "Concurrency",
						value: "\(dispatcherRun.effectiveConcurrency)/\(dispatcherRun.requestedConcurrency)"
					)
				}
				Text(dispatcherRun.resumeAction)
					.font(.caption.weight(.medium))
				if let failureReason = dispatcherRun.failureReason, failureReason.isEmpty == false {
					Text(failureReason)
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(3)
				}
			}
			else {
				Text("This run was created before dispatcher state was recorded.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.padding()
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
			HStack {
				Text("Review Workbench")
					.font(.headline)
				Spacer()
				StatusBadge(title: "\(workbench.rows.count) Tickets", tint: .blue)
				if workbench.skippedItems.isEmpty == false {
					StatusBadge(title: "\(workbench.skippedItems.count) Skipped", tint: .yellow)
				}
			}
			ForEach(workbench.rows) { row in
				VStack(alignment: .leading, spacing: 8) {
					HStack {
						VStack(alignment: .leading, spacing: 4) {
							Text("\(row.ticketExternalID): \(row.ticketTitle)")
								.font(.callout.weight(.medium))
							Text(
								"\(row.branchName.isEmpty ? "No branch yet" : row.branchName) • \(row.runtimeID.isEmpty ? "No runtime yet" : row.runtimeID)"
							)
							.font(.caption)
							.foregroundStyle(.secondary)
							Text(phaseText(for: row))
								.font(.caption)
								.foregroundStyle(.secondary)
							Text(row.reportBackSummary)
								.font(.caption)
								.foregroundStyle(.secondary)
							Text(row.containerSummary)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(1)
							Text(row.nextAction)
								.font(.caption.weight(.medium))
								.foregroundStyle(.primary)
						}
						Spacer()
						if let pullRequestURL = row.pullRequestURL, let link = URL(string: pullRequestURL) {
							Link("PR", destination: link)
						}
						if let reportBackCommentURL = row.reportBackCommentURL, let link = URL(string: reportBackCommentURL) {
							Link("Handoff", destination: link)
						}
						if let reportBackStatus = row.reportBackStatus {
							StatusBadge(title: reportBackStatus.title, tint: reportBackTint(reportBackStatus))
						}
						if let containerStatus = row.containerStatus {
							StatusBadge(title: containerStatus.title, tint: containerTint(containerStatus))
						}
						StatusBadge(title: row.runStatus.title, tint: row.runStatus.tint)
					}
					if row.changedFiles.isEmpty == false || row.logTail.isEmpty == false || row.failureReason?.isEmpty == false {
						LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
							if row.changedFiles.isEmpty == false {
								ReviewPacketValue(
									title: "Changed Files",
									value: row.changedFiles.joined(separator: ", ")
								)
							}
							if let failureReason = row.failureReason, failureReason.isEmpty == false {
								ReviewPacketValue(title: "Failure", value: failureReason)
							}
							if row.logTail.isEmpty == false {
								VStack(alignment: .leading, spacing: 4) {
									Text("Log Tail")
										.font(.caption.weight(.semibold))
										.foregroundStyle(.secondary)
									Text(row.logTail)
										.font(.system(.caption, design: .monospaced))
										.lineLimit(6)
										.textSelection(.enabled)
								}
								.frame(maxWidth: .infinity, alignment: .leading)
							}
						}
					}
				}
				.padding(10)
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
			}
			if workbench.skippedItems.isEmpty == false {
				VStack(alignment: .leading, spacing: 8) {
					Text("Skipped by Dispatcher")
						.font(.caption.weight(.semibold))
						.foregroundStyle(.secondary)
					ForEach(workbench.skippedItems) { item in
						HStack(alignment: .top, spacing: 8) {
							Image(systemName: "forward.end")
								.foregroundStyle(.yellow)
								.frame(width: 18)
							VStack(alignment: .leading, spacing: 2) {
								Text(item.reason.replacingOccurrences(of: "_", with: " ").capitalized)
									.font(.caption)
									.fontWeight(.semibold)
								Text(item.detail)
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							Spacer()
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

	private func ticketForIssue(_ issueNumber: Int) -> TicketRecord? {
		tickets.first { githubIssueNumber(from: $0.externalID) == issueNumber }
	}

	private func phaseText(for row: ReviewWorkbenchState.Row) -> String {
		if let failedPhase = row.failedPhase {
			return "Phase: \(row.lifecyclePhase.title) at \(failedPhase.title)"
		}
		return "Phase: \(row.lifecyclePhase.title)"
	}

	private func reportBackTint(_ status: TicketReportBackStatus) -> Color {
		switch status {
		case .pending: .secondary
		case .inFlight: .blue
		case .succeeded: .green
		case .failed: .red
		}
	}

	private func containerTint(_ status: ContainerRunStatus) -> Color {
		switch status {
		case .starting: .blue
		case .running: .orange
		case .completed: .green
		case .failed, .killed, .orphaned: .red
		}
	}

	private func dispatcherTint(_ status: DispatcherRunStatus) -> Color {
		switch status {
		case .planned: .secondary
		case .running: .orange
		case .completed: .green
		case .completedWithFailures, .reconciled: .yellow
		case .canceled: .gray
		case .failed: .red
		}
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
