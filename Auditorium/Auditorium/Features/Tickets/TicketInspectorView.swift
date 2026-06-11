import AppKit
import SwiftUI

struct TicketInspectorView: View {
	@Environment(AppState.self) private var appState
	let project: Project?
	let ticket: TicketRecord?
	let queueItem: QueueItemRecord?
	let latestRun: TicketRunRecord?
	let events: [RuntimeEventRecord]
	let addToQueue: () -> Void
	let removeFromQueue: () -> Void
	let runTicket: () -> Void
	let retryTicket: () -> Void
	let cancelRun: () -> Void

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 14) {
				if let ticket {
					let inspectorState = TicketInspectorState(
						ticket: ticket,
						queueItem: queueItem,
						latestRun: latestRun,
						events: events
					)
					header(ticket, inspectorState: inspectorState)
					primaryAction(inspectorState)
					section("Execution", symbol: "play.circle") {
						LabeledContent("Queue", value: inspectorState.queueState)
						LabeledContent("Latest Run", value: inspectorState.latestRunState)
						if inspectorState.runtime != "None" {
							LabeledContent("Runtime", value: inspectorState.runtime)
						}
						if inspectorState.branch != "None" {
							LabeledContent("Branch", value: inspectorState.branch)
						}
						if inspectorState.confidence != "None" {
							LabeledContent("Confidence", value: inspectorState.confidence)
						}
					}
					if latestRun?.failureReason?.isEmpty == false || inspectorState.canRetryTicket {
						section("Attention", symbol: "exclamationmark.triangle") {
							Text(inspectorState.failureText)
								.font(.callout)
							Text(inspectorState.nextAction)
								.font(.callout.weight(.medium))
								.foregroundStyle(.secondary)
						}
					}
					section("Links", symbol: "link") {
						linkActions(ticket: ticket, inspectorState: inspectorState)
					}
					section("Metadata", symbol: "tag") {
						LabeledContent("External ID", value: ticket.externalID)
						LabeledContent("Provider", value: ticket.provider.title)
						LabeledContent("Priority", value: ticket.priority.title)
						LabeledContent("Complexity", value: "\(ticket.estimatedComplexity)")
						LabeledContent("Assignee", value: ticket.assignee ?? "Unassigned")
					}
					section("Timeline", symbol: "clock") {
						if events.isEmpty {
							Text("No events yet.")
								.foregroundStyle(.secondary)
						}
						else {
							ForEach(events.prefix(8)) { event in
								TimelineRow(event: event)
							}
						}
					}
					section("Copy", symbol: "doc.on.doc") {
						copyActions(ticket: ticket)
					}
				}
				else {
					EmptyStateView(
						symbol: "sidebar.right",
						title: "No Ticket Selected",
						message: "Select a queued, running, or review-ready ticket.",
						recoverySuggestion: "The inspector will show the next action, execution state, links, and timeline.",
						actionTitle: "Open Tickets",
						action: { appState.selectedDestination = .tickets }
					)
					.frame(height: 360)
				}
			}
			.padding()
		}
		.background(.bar)
	}

	private func header(_ ticket: TicketRecord, inspectorState: TicketInspectorState) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Label(ticket.externalID, systemImage: "ticket")
					.font(.headline)
				Spacer()
				StatusBadge(title: ticket.status.title, tint: ticket.status.tint)
			}
			Text(ticket.title)
				.font(.title3.weight(.semibold))
				.fixedSize(horizontal: false, vertical: true)
			Text(inspectorState.nextAction)
				.font(.callout.weight(.medium))
				.foregroundStyle(.secondary)
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	@ViewBuilder
	private func primaryAction(_ inspectorState: TicketInspectorState) -> some View {
		if inspectorState.canCancelRun {
			Button(role: .destructive, action: cancelRun) {
				Label("Cancel Run", systemImage: "xmark.circle")
			}
			.buttonStyle(.borderedProminent)
		}
		else if inspectorState.canRetryTicket {
			Button(action: retryTicket) {
				Label("Retry Ticket", systemImage: "arrow.clockwise")
			}
			.buttonStyle(.borderedProminent)
		}
		else if inspectorState.canRunTicket {
			Button(action: runTicket) {
				Label("Run Ticket", systemImage: "play.circle.fill")
			}
			.buttonStyle(.borderedProminent)
		}
		else if inspectorState.canAddToQueue {
			Button(action: addToQueue) {
				Label("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
			}
			.buttonStyle(.borderedProminent)
		}
	}

	private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 9) {
			Label(title, systemImage: symbol)
				.font(.headline)
			content()
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private func linkActions(ticket: TicketRecord, inspectorState: TicketInspectorState) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			if inspectorState.canOpenIssueTracker {
				Button {
					open(ticket.webURL)
				} label: {
					Label("Issue Tracker", systemImage: "safari")
				}
			}
			if inspectorState.canOpenPullRequest {
				Button {
					open(latestRun?.pullRequestURL)
				} label: {
					Label("Pull Request", systemImage: "arrow.triangle.pull")
				}
			}
			if inspectorState.canRevealWorkspace {
				Button {
					if let path = latestRun?.workspacePath, path.isEmpty == false {
						NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
					}
				} label: {
					Label("Workspace", systemImage: "folder")
				}
			}
			if inspectorState.canRemoveFromQueue {
				Button(role: .destructive, action: removeFromQueue) {
					Label("Remove from Queue", systemImage: "minus.circle")
				}
			}
			if inspectorState.canOpenIssueTracker == false && inspectorState.canOpenPullRequest == false
				&& inspectorState.canRevealWorkspace == false && inspectorState.canRemoveFromQueue == false
			{
				Text("No links are available yet.")
					.foregroundStyle(.secondary)
			}
		}
		.buttonStyle(.bordered)
	}

	private func copyActions(ticket: TicketRecord) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Button {
				copy("\(ticket.externalID) \(ticket.status.title) \(latestRun?.summary ?? "")")
			} label: {
				Label("Copy Debug Summary", systemImage: "doc.on.doc")
			}
			Button {
				copy(
					TicketStatusFormatter.markdownStatus(
						ticket: ticket,
						project: project,
						queueItem: queueItem,
						ticketRun: latestRun,
						events: events
					)
				)
			} label: {
				Label("Copy Markdown Status", systemImage: "markdown")
			}
		}
		.buttonStyle(.bordered)
	}

	private func open(_ value: String?) {
		guard let value, let url = URL(string: value) else { return }
		NSWorkspace.shared.open(url)
	}

	private func copy(_ value: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)
	}
}

#Preview("Ticket Inspector") {
	TicketInspectorView(
		project: ProjectDashboardPreviewData.project,
		ticket: ProjectDashboardPreviewData.tickets[0],
		queueItem: ProjectDashboardPreviewData.queueItems[0],
		latestRun: ProjectDashboardPreviewData.ticketRuns[0],
		events: ProjectDashboardPreviewData.events,
		addToQueue: {},
		removeFromQueue: {},
		runTicket: {},
		retryTicket: {},
		cancelRun: {}
	)
	.environment(AppState())
	.frame(width: 340, height: 760)
}
