import SwiftUI

struct QueueScreen: View {
	@Environment(AppState.self) private var appState
	let project: Project?
	let tickets: [TicketRecord]
	let queueItems: [QueueItemRecord]
	let runQueue: () -> Void
	let dryRun: () -> Void
	let clearQueue: () -> Void
	let removeItem: (QueueItemRecord) -> Void
	let moveItems: (IndexSet, Int) -> Void

	var body: some View {
		VStack(spacing: 0) {
			toolbar
			if queueItems.isEmpty {
				EmptyStateView(symbol: "text.line.first.and.arrowtriangle.forward", title: "Queue Is Empty", message: "Add tickets from the Ticket Browser to build an agent run.")
			} else {
				List {
					ForEach(queueItems) { item in
						if let ticket = tickets.first(where: { $0.id == item.ticketID }) {
							QueueRow(ticket: ticket, item: item, remove: { removeItem(item) })
								.onTapGesture {
									appState.inspectTicket(ticket.id)
								}
						}
					}
					.onMove(perform: moveItems)
				}
			}
		}
		.navigationTitle("Queue")
	}

	private var toolbar: some View {
		@Bindable var appState = appState
		return HStack {
			Button(action: runQueue) {
				Label("Run Queue", systemImage: "play.circle.fill")
			}
			.buttonStyle(.borderedProminent)
			.disabled(queueItems.filter { $0.isEnabled }.isEmpty)
			Button(action: dryRun) {
				Label("Dry Run", systemImage: "checklist")
			}
			.buttonStyle(.bordered)
			Button(action: clearQueue) {
				Label("Clear Queue", systemImage: "trash")
			}
			.buttonStyle(.bordered)
			.disabled(queueItems.isEmpty)
			Spacer()
			Stepper("Concurrency \(appState.queueConcurrency)", value: $appState.queueConcurrency, in: 1...8)
				.frame(width: 170)
			Menu(project?.runtimeProviderKind.title ?? "Runtime") {
				ForEach(RuntimeProviderKind.allCases) { runtime in
					Text(runtime.title)
				}
			}
			Menu(project?.agentProviderKind.title ?? "Agent") {
				ForEach(AgentProviderKind.allCases) { agent in
					Text(agent.title)
				}
			}
		}
		.padding()
	}
}

struct QueueRow: View {
	let ticket: TicketRecord
	let item: QueueItemRecord
	let remove: () -> Void

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: item.isEnabled ? "checkmark.circle.fill" : "circle")
				.foregroundStyle(item.isEnabled ? .green : .secondary)
			VStack(alignment: .leading, spacing: 4) {
				Text("\(ticket.externalID) \(ticket.title)")
					.font(.headline)
				Text(ticket.labels.joined(separator: ", "))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			StatusBadge(title: ticket.status.title, tint: ticket.status.tint)
			Text(ticket.priority.title)
				.frame(width: 70, alignment: .leading)
			Button(action: remove) {
				Image(systemName: "xmark")
			}
			.buttonStyle(.borderless)
		}
		.padding(.vertical, 5)
	}
}
