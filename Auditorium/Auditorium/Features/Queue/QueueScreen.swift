import SwiftUI

struct QueueScreen: View {
	@Environment(AppState.self) private var appState
	@State private var selectedQueueItemIDs = Set<UUID>()
	let project: Project?
	let tickets: [TicketRecord]
	let queueItems: [QueueItemRecord]
	let runQueue: () -> Void
	let dryRun: () -> Void
	let clearQueue: () -> Void
	let removeItem: (QueueItemRecord) -> Void
	let removeItems: (Set<UUID>) -> Void
	let toggleItem: (QueueItemRecord, Bool) -> Void
	let setItemsEnabled: (Set<UUID>, Bool) -> Void
	let moveItems: (IndexSet, Int) -> Void

	var body: some View {
		VStack(spacing: 0) {
			toolbar
			if queueItems.isEmpty {
				EmptyStateView(
					symbol: "text.line.first.and.arrowtriangle.forward",
					title: "Queue Is Empty",
					message: "Add tickets from the Ticket Browser to build an agent run."
				)
			}
			else {
				List(selection: $selectedQueueItemIDs) {
					ForEach(queueItems) { item in
						if let ticket = tickets.first(where: { $0.id == item.ticketID }) {
							QueueRow(
								ticket: ticket,
								item: item,
								toggle: { toggleItem(item, $0) },
								remove: { removeItem(item) }
							)
							.tag(item.id)
						}
					}
					.onMove(perform: moveItems)
				}
			}
		}
		.navigationTitle("Queue")
		.onChange(of: selectedQueueItemIDs) { _, ids in
			inspectSingleSelection(ids)
		}
		.onChange(of: queueItems.map(\.id)) { _, ids in
			selectedQueueItemIDs.formIntersection(Set(ids))
		}
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
			Menu {
				Button {
					setSelectedItemsEnabled(true)
				} label: {
					Label("Enable Selected", systemImage: "checkmark.circle")
				}
				Button {
					setSelectedItemsEnabled(false)
				} label: {
					Label("Disable Selected", systemImage: "pause.circle")
				}
				Divider()
				Button(role: .destructive) {
					removeSelectedItems()
				} label: {
					Label("Remove Selected", systemImage: "xmark.circle")
				}
			} label: {
				Label("Selected \(selectedQueueItemIDs.count)", systemImage: "checklist.checked")
			}
			.menuStyle(.borderlessButton)
			.disabled(selectedQueueItemIDs.isEmpty)
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

	private func inspectSingleSelection(_ ids: Set<UUID>) {
		guard ids.count == 1,
			let itemID = ids.first,
			let item = queueItems.first(where: { $0.id == itemID }),
			let ticket = tickets.first(where: { $0.id == item.ticketID })
		else {
			return
		}
		appState.inspectTicket(ticket.id)
	}

	private func setSelectedItemsEnabled(_ isEnabled: Bool) {
		setItemsEnabled(selectedQueueItemIDs, isEnabled)
	}

	private func removeSelectedItems() {
		let ids = selectedQueueItemIDs
		selectedQueueItemIDs.removeAll()
		removeItems(ids)
	}
}

struct QueueRow: View {
	let ticket: TicketRecord
	let item: QueueItemRecord
	let toggle: (Bool) -> Void
	let remove: () -> Void

	var body: some View {
		HStack(spacing: 12) {
			Toggle("Enabled", isOn: Binding(get: { item.isEnabled }, set: toggle))
				.labelsHidden()
				.toggleStyle(.checkbox)
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
