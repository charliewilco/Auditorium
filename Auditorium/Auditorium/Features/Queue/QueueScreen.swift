import SwiftUI

struct QueueScreen: View {
	@Environment(AppState.self) private var appState
	@State private var selectedQueueItemIDs = Set<UUID>()
	let project: Project?
	let tickets: [TicketRecord]
	let queueItems: [QueueItemRecord]
	let preflightSummary: RunPreflightSummary?
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
					message: "Add tickets from the Ticket Browser to build an agent run.",
					recoverySuggestion:
						"Queued tickets keep their order, enabled state, and per-run snapshot before Codex starts.",
					actionTitle: "Open Tickets",
					action: { appState.selectedDestination = .tickets }
				)
			}
			else {
				ScrollView {
					VStack(alignment: .leading, spacing: 16) {
						if let preflightSummary {
							RunPreflightSummaryView(summary: preflightSummary)
						}
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
						.frame(minHeight: 320)
					}
					.padding()
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
			.disabled(queueItems.filter { $0.isEnabled }.isEmpty || preflightSummary?.canStartRun == false)
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
			if let project {
				ProviderBadge(title: project.runtimeProviderKind.title, symbol: project.runtimeProviderKind.symbol)
				ProviderBadge(title: project.agentProviderKind.title, symbol: project.agentProviderKind.symbol)
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
