import AppKit
import SwiftUI

struct TicketInspectorView: View {
	let project: Project?
	let ticket: TicketRecord?
	let queueItem: QueueItemRecord?
	let latestRun: TicketRunRecord?
	let events: [RuntimeEventRecord]
	let addToQueue: () -> Void
	let removeFromQueue: () -> Void
	let runTicket: () -> Void
	let retryTicket: () -> Void

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				if let ticket {
					header(ticket)
					section("Ticket Metadata") {
						LabeledContent("External ID", value: ticket.externalID)
						LabeledContent("Provider", value: ticket.provider.title)
						LabeledContent("Priority", value: ticket.priority.title)
						LabeledContent("Complexity", value: "\(ticket.estimatedComplexity)")
						LabeledContent("Assignee", value: ticket.assignee ?? "Unassigned")
					}
					section("Current Orchestration State") {
						LabeledContent("Queue", value: queueItem.map { "Position \($0.position + 1)" } ?? "Not queued")
						LabeledContent("Latest Run", value: latestRun?.status.title ?? "No run")
						LabeledContent("Workspace", value: latestRun?.workspacePath.isEmpty == false ? latestRun?.workspacePath ?? "None" : "None")
						LabeledContent("Container", value: latestRun?.containerID.isEmpty == false ? latestRun?.containerID ?? "None" : "None")
						LabeledContent("Branch", value: latestRun?.branchName.isEmpty == false ? latestRun?.branchName ?? "None" : "None")
						LabeledContent("Pull Request", value: latestRun?.pullRequestURL ?? "None")
						LabeledContent("Confidence", value: latestRun == nil ? "None" : "\(Int((latestRun?.confidence ?? 0) * 100))%")
					}
					section("Failure and Next Action") {
						Text(latestRun?.failureReason ?? "No failure recorded.")
							.foregroundStyle(latestRun?.failureReason == nil ? .secondary : .primary)
						Text(nextAction(ticket: ticket))
							.font(.callout.weight(.medium))
					}
					section("Timeline Events") {
						if events.isEmpty {
							Text("No events yet.")
								.foregroundStyle(.secondary)
						} else {
							ForEach(events.prefix(10)) { event in
								TimelineRow(event: event)
							}
						}
					}
					actions(ticket: ticket)
				} else {
					EmptyStateView(symbol: "sidebar.right", title: "No Ticket Selected", message: "Select a ticket to inspect orchestration state.")
						.frame(height: 360)
				}
			}
			.padding()
		}
		.background(.bar)
	}

	private func header(_ ticket: TicketRecord) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Label(ticket.externalID, systemImage: "ticket")
					.font(.headline)
				Spacer()
				StatusBadge(title: ticket.status.title, tint: ticket.status.tint)
			}
			Text(ticket.title)
				.font(.title3.weight(.semibold))
			Text(ticket.body)
				.font(.callout)
				.foregroundStyle(.secondary)
		}
	}

	private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title)
				.font(.headline)
			content()
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func actions(ticket: TicketRecord) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Actions")
				.font(.headline)
			LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
				Button("Add to Queue", action: addToQueue)
					.disabled(queueItem != nil)
				Button("Remove", action: removeFromQueue)
					.disabled(queueItem == nil)
				Button("Run Ticket", action: runTicket)
				Button("Retry", action: retryTicket)
					.disabled(latestRun == nil)
				Button("Cancel") {}
					.disabled(true)
				Button("Issue Tracker") {
					open(ticket.webURL)
				}
				Button("Pull Request") {
					open(latestRun?.pullRequestURL)
				}
				.disabled(latestRun?.pullRequestURL == nil)
				Button("Workspace") {
					if let path = latestRun?.workspacePath, path.isEmpty == false {
						NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
					}
				}
				.disabled(latestRun?.workspacePath.isEmpty != false)
				Button("Copy Debug Summary") {
					copy("\(ticket.externalID) \(ticket.status.title) \(latestRun?.summary ?? "")")
				}
				Button("Copy Markdown Status") {
					copy(TicketStatusFormatter.markdownStatus(ticket: ticket, project: project, queueItem: queueItem, ticketRun: latestRun, events: events))
				}
			}
			.buttonStyle(.bordered)
		}
	}

	private func nextAction(ticket: TicketRecord) -> String {
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

	private func open(_ value: String?) {
		guard let value, let url = URL(string: value) else { return }
		NSWorkspace.shared.open(url)
	}

	private func copy(_ value: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)
	}
}
