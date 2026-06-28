import SwiftUI

struct QueueScreen: View {
	@Environment(AppState.self) private var appState
	@State private var selectedQueueItemIDs = Set<UUID>()
	let project: Project?
	let tickets: [TicketRecord]
	let queueItems: [QueueItemRecord]
	let preflightSummary: RunPreflightSummary?
	let addTickets: (Set<UUID>) -> Void
	let queueNextTickets: () -> Void
	let fillQueueAndRun: () -> Void
	let runQueue: () -> Void
	let dryRun: () -> Void
	let clearQueue: () -> Void
	let removeItem: (QueueItemRecord) -> Void
	let removeItems: (Set<UUID>) -> Void
	let toggleItem: (QueueItemRecord, Bool) -> Void
	let setItemsEnabled: (Set<UUID>, Bool) -> Void
	let moveItems: (IndexSet, Int) -> Void
	@State private var selectedAvailableTicketIDs = Set<UUID>()
	@State private var availableTicketFilter = ""

	private var queuedTicketIDs: Set<UUID> {
		Set(queueItems.map(\.ticketID))
	}

	private var availableTickets: [TicketRecord] {
		tickets
			.filter { queuedTicketIDs.contains($0.id) == false }
			.sorted { first, second in
				if first.priority.sortWeight != second.priority.sortWeight {
					return first.priority.sortWeight > second.priority.sortWeight
				}
				return first.updatedAt > second.updatedAt
			}
	}

	private var filteredAvailableTickets: [TicketRecord] {
		guard availableTicketFilter.isEmpty == false else { return availableTickets }
		return availableTickets.filter {
			$0.title.localizedCaseInsensitiveContains(availableTicketFilter)
				|| $0.externalID.localizedCaseInsensitiveContains(availableTicketFilter)
				|| $0.labels.contains { $0.localizedCaseInsensitiveContains(availableTicketFilter) }
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			toolbar
			if tickets.isEmpty && queueItems.isEmpty {
				EmptyStateView(
					symbol: "ticket",
					title: "No Tickets Imported",
					message: "Import or seed tickets before building an agent queue.",
					recoverySuggestion: "The queue works from project tickets and keeps each ticket tied to its run history.",
					actionTitle: "Open Tickets",
					action: { appState.selectedDestination = .tickets }
				)
			}
			else {
				VStack(alignment: .leading, spacing: 14) {
					if let preflightSummary {
						RunPreflightSummaryView(summary: preflightSummary)
					}
					HSplitView {
						availableTicketsPane
							.frame(minWidth: 280, idealWidth: 340)
						queuedTicketsPane
							.frame(minWidth: 440)
					}
				}
				.padding()
			}
		}
		.navigationTitle("Queue")
		.onChange(of: selectedQueueItemIDs) { _, ids in
			inspectSingleSelection(ids)
		}
		.onChange(of: queueItems.map(\.id)) { _, ids in
			selectedQueueItemIDs.formIntersection(Set(ids))
		}
		.onChange(of: availableTickets.map(\.id)) { _, ids in
			selectedAvailableTicketIDs.formIntersection(Set(ids))
		}
	}

	private var toolbar: some View {
		@Bindable var appState = appState
		return HStack {
			Button(action: runQueue) {
				Label("Run Queue", systemImage: "play.circle.fill")
			}
			.buttonStyle(.borderedProminent)
			.disabled(queueItems.filter { $0.isEnabled }.isEmpty || preflightSummary?.canStartRun == false)
			Button(action: dryRun) {
				Label("Dry Run", systemImage: "checklist")
			}
			.buttonStyle(.bordered)
			Button(action: queueNextTickets) {
				Label("Queue Next 12", systemImage: "tray.and.arrow.down")
			}
			.buttonStyle(.bordered)
			.disabled(project == nil)
			Button(action: fillQueueAndRun) {
				Label("Fill and Run", systemImage: "play.square.stack")
			}
			.buttonStyle(.bordered)
			.disabled(project == nil || preflightSummary?.canStartRun == false)
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
			if let project {
				ProviderBadge(title: project.runtimeProviderKind.title, symbol: project.runtimeProviderKind.symbol)
				ProviderBadge(title: project.agentProviderKind.title, symbol: project.agentProviderKind.symbol)
			}
		}
		.padding()
	}

	private var availableTicketsPane: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Label("Available Tickets", systemImage: "ticket")
					.font(.headline)
				Spacer()
				Button {
					addAvailableSelection()
				} label: {
					Label("Add", systemImage: "plus.circle")
				}
				.buttonStyle(.borderedProminent)
				.disabled(selectedAvailableTicketIDs.isEmpty)
			}
			TextField("Filter tickets", text: $availableTicketFilter)
				.textFieldStyle(.roundedBorder)
			if filteredAvailableTickets.isEmpty {
				QueuePaneEmptyState(
					symbol: availableTickets.isEmpty ? "checkmark.circle" : "magnifyingglass",
					title: availableTickets.isEmpty ? "All Tickets Queued" : "No Matches",
					message: availableTickets.isEmpty
						? "Every imported ticket is already connected to the queue."
						: "Adjust the filter to show more imported tickets."
				)
			}
			else {
				List(selection: $selectedAvailableTicketIDs) {
					ForEach(filteredAvailableTickets) { ticket in
						AvailableTicketRow(
							ticket: ticket,
							add: { addTickets([ticket.id]) },
							inspect: { appState.inspectTicket(ticket.id) }
						)
						.tag(ticket.id)
					}
				}
				.frame(minHeight: 320)
			}
		}
	}

	private var queuedTicketsPane: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Label("Queued Tickets", systemImage: "text.line.first.and.arrowtriangle.forward")
					.font(.headline)
				Spacer()
				Text("\(queueItems.filter(\.isEnabled).count) enabled")
					.font(.caption.weight(.medium))
					.foregroundStyle(.secondary)
			}
			if queueItems.isEmpty {
				QueuePaneEmptyState(
					symbol: "text.line.first.and.arrowtriangle.forward",
					title: "Queue Is Empty",
					message: "Select tickets from the available list, then add them to the run queue."
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
						else {
							MissingQueueRow(item: item, remove: { removeItem(item) })
								.tag(item.id)
						}
					}
					.onMove(perform: moveItems)
				}
				.frame(minHeight: 320)
			}
		}
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

	private func addAvailableSelection() {
		let ids = selectedAvailableTicketIDs
		selectedAvailableTicketIDs.removeAll()
		addTickets(ids)
	}
}

private struct ProviderBadge: View {
	let title: String
	let symbol: String

	var body: some View {
		Label(title, systemImage: symbol)
			.font(.caption.weight(.medium))
			.foregroundStyle(.secondary)
			.help("Configured in Project Settings")
	}
}

private struct RunPreflightSummaryView: View {
	let summary: RunPreflightSummary

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				VStack(alignment: .leading, spacing: 3) {
					Text("Run Plan")
						.font(.headline)
					Text("\(summary.enabledIssueCount) enabled of \(summary.issueCount) imported tickets")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer()
				StatusBadge(title: summary.canStartRun ? "Ready" : "Blocked", tint: summary.canStartRun ? .green : .red)
			}
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
				RunPlanValue(title: "Repository", value: summary.repositoryName)
				RunPlanValue(title: "Branch Prefix", value: summary.branchPrefix)
				RunPlanValue(title: "Validation", value: summary.validationCommand)
				RunPlanValue(title: "Pull Requests", value: summary.opensPullRequests ? "Will open PRs" : "Disabled by workflow")
				RunPlanValue(title: "GitHub Account", value: summary.accountTitle)
				RunPlanValue(title: "Scopes", value: summary.scopeSummary)
				RunPlanValue(title: "Workspace Root", value: summary.workspaceRoot)
			}
			VStack(alignment: .leading, spacing: 8) {
				ForEach(summary.checks) { check in
					HStack(alignment: .top, spacing: 10) {
						Image(systemName: symbol(for: check.state))
							.foregroundStyle(tint(for: check.state))
							.frame(width: 18)
						VStack(alignment: .leading, spacing: 2) {
							Text(check.title)
								.font(.caption.weight(.semibold))
							Text(check.detail)
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
						StatusBadge(title: check.state.title, tint: tint(for: check.state))
					}
				}
			}
		}
		.padding(12)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private func symbol(for state: RunPreflightSummary.CheckState) -> String {
		switch state {
		case .passed: "checkmark.circle.fill"
		case .warning: "exclamationmark.triangle.fill"
		case .blocked: "xmark.octagon.fill"
		}
	}

	private func tint(for state: RunPreflightSummary.CheckState) -> Color {
		switch state {
		case .passed: .green
		case .warning: .orange
		case .blocked: .red
		}
	}
}

private struct RunPlanValue: View {
	let title: String
	let value: String

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(title)
				.font(.caption.weight(.semibold))
				.foregroundStyle(.secondary)
			Text(value)
				.font(.caption)
				.lineLimit(2)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

private struct QueuePaneEmptyState: View {
	let symbol: String
	let title: String
	let message: String

	var body: some View {
		VStack(spacing: 10) {
			Image(systemName: symbol)
				.font(.system(size: 28))
				.foregroundStyle(.secondary)
			Text(title)
				.font(.headline)
			Text(message)
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 300)
		}
		.frame(maxWidth: .infinity, minHeight: 320)
	}
}

private struct AvailableTicketRow: View {
	let ticket: TicketRecord
	let add: () -> Void
	let inspect: () -> Void

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: ticket.provider.symbol)
				.foregroundStyle(.secondary)
				.frame(width: 18)
			VStack(alignment: .leading, spacing: 3) {
				Text("\(ticket.externalID) \(ticket.title)")
					.font(.callout.weight(.medium))
					.lineLimit(2)
				Text(ticket.labels.joined(separator: ", "))
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			Spacer()
			StatusBadge(title: ticket.priority.title, tint: priorityTint)
			Button(action: add) {
				Image(systemName: "plus.circle")
			}
			.buttonStyle(.borderless)
			.help("Add ticket to queue")
		}
		.contentShape(Rectangle())
		.onTapGesture(perform: inspect)
		.padding(.vertical, 4)
	}

	private var priorityTint: Color {
		switch ticket.priority {
		case .low: .secondary
		case .medium: .blue
		case .high: .orange
		case .urgent: .red
		}
	}
}

private struct MissingQueueRow: View {
	let item: QueueItemRecord
	let remove: () -> Void

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundStyle(.orange)
			VStack(alignment: .leading, spacing: 3) {
				Text("Missing ticket")
					.font(.headline)
				Text("Queue position \(item.position + 1)")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Button(action: remove) {
				Image(systemName: "xmark")
			}
			.buttonStyle(.borderless)
			.help("Remove missing queue item")
		}
		.padding(.vertical, 5)
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
