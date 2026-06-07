import SwiftUI

struct RunsView: View {
	@Environment(AppState.self) private var appState
	let runs: [RunRecord]
	let ticketRuns: [TicketRunRecord]
	let tickets: [TicketRecord]
	let events: [RuntimeEventRecord]
	let pullRequests: [PullRequestRecord]

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
				RunDetailView(run: run, ticketRuns: ticketRuns.filter { $0.runID == run.id }, tickets: tickets, events: events.filter { $0.runID == run.id }, pullRequests: pullRequests)
			} else {
				EmptyStateView(symbol: "play.circle.fill", title: "No Run Selected", message: "Start a queue run to see live execution details.")
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
	let pullRequests: [PullRequestRecord]

	var progress: Double {
		guard run.totalTickets > 0 else { return 0 }
		let done = run.completedTickets + run.failedTickets + run.blockedTickets
		return Double(done) / Double(run.totalTickets)
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
				LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
					StatCard(title: "Total Tickets", value: "\(run.totalTickets)", symbol: "ticket", tint: .blue)
					StatCard(title: "Completed", value: "\(run.completedTickets)", symbol: "checkmark.circle.fill", tint: .green)
					StatCard(title: "Failed", value: "\(run.failedTickets)", symbol: "xmark.octagon.fill", tint: .red)
					StatCard(title: "Blocked", value: "\(run.blockedTickets)", symbol: "hand.raised.fill", tint: .yellow)
					StatCard(title: "PRs Created", value: "\(run.pullRequestsCreated)", symbol: "arrow.triangle.pull", tint: .indigo)
				}
				ticketExecutionList
				timeline
				reportPreview
			}
			.padding()
		}
	}

	private var ticketExecutionList: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Ticket Executions")
				.font(.headline)
			ForEach(ticketRuns) { ticketRun in
				let ticket = tickets.first { $0.id == ticketRun.ticketID }
				HStack {
					VStack(alignment: .leading, spacing: 4) {
						Text(ticket?.title ?? "Unknown Ticket")
							.font(.callout.weight(.medium))
						Text("\(ticketRun.branchName.isEmpty ? "No branch yet" : ticketRun.branchName) • \(ticketRun.containerID.isEmpty ? "No runtime yet" : ticketRun.containerID)")
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
}
