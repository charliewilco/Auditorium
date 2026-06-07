import SwiftUI

struct TicketBrowserView: View {
	@Environment(AppState.self) private var appState
	let project: Project?
	let tickets: [TicketRecord]
	let queueItems: [QueueItemRecord]
	let addToQueue: (Set<UUID>) -> Void
	@State private var selectedTickets = Set<UUID>()
	@State private var statusFilter: TicketStatus?
	@State private var priorityFilter: PriorityLevel?
	@State private var sortMode = TicketSortMode.updated

	var filteredTickets: [TicketRecord] {
		var result = tickets
		if appState.ticketSearchText.isEmpty == false {
			result = result.filter {
				$0.title.localizedCaseInsensitiveContains(appState.ticketSearchText) ||
				$0.externalID.localizedCaseInsensitiveContains(appState.ticketSearchText) ||
				$0.labels.contains { $0.localizedCaseInsensitiveContains(appState.ticketSearchText) }
			}
		}
		if let statusFilter {
			result = result.filter { $0.status == statusFilter }
		}
		if let priorityFilter {
			result = result.filter { $0.priority == priorityFilter }
		}
		switch sortMode {
		case .updated:
			result.sort { $0.updatedAt > $1.updatedAt }
		case .priority:
			result.sort { $0.priority.sortWeight > $1.priority.sortWeight }
		case .complexity:
			result.sort { $0.estimatedComplexity > $1.estimatedComplexity }
		}
		return result
	}

	var body: some View {
		VStack(spacing: 0) {
			toolbar
			if filteredTickets.isEmpty {
				EmptyStateView(symbol: "ticket", title: "No Tickets", message: "Open the demo project or adjust filters to see imported issue work.")
			} else {
				Table(filteredTickets, selection: $selectedTickets) {
					TableColumn("Ticket") { ticket in
						HStack {
							Image(systemName: ticket.provider.symbol)
								.foregroundStyle(.secondary)
							VStack(alignment: .leading) {
								Text("\(ticket.externalID) \(ticket.title)")
									.font(.callout.weight(.medium))
								Text(ticket.labels.joined(separator: ", "))
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						.onTapGesture {
							appState.inspectTicket(ticket.id)
						}
					}
					TableColumn("Status") { ticket in
						StatusBadge(title: ticket.status.title, tint: ticket.status.tint)
					}
					TableColumn("Priority") { ticket in
						Text(ticket.priority.title)
					}
					TableColumn("Complexity") { ticket in
						Text("\(ticket.estimatedComplexity)")
					}
					TableColumn("Updated") { ticket in
						Text(ticket.updatedAt, format: .dateTime.month().day().hour().minute())
					}
				}
			}
		}
		.navigationTitle("Tickets")
		.searchable(text: Binding(get: { appState.ticketSearchText }, set: { appState.ticketSearchText = $0 }), prompt: "Search tickets")
	}

	private var toolbar: some View {
		HStack {
			Picker("Status", selection: $statusFilter) {
				Text("All Statuses").tag(nil as TicketStatus?)
				ForEach(TicketStatus.allCases) { status in
					Text(status.title).tag(status as TicketStatus?)
				}
			}
			.frame(width: 160)
			Picker("Priority", selection: $priorityFilter) {
				Text("All Priorities").tag(nil as PriorityLevel?)
				ForEach(PriorityLevel.allCases) { priority in
					Text(priority.title).tag(priority as PriorityLevel?)
				}
			}
			.frame(width: 150)
			Picker("Sort", selection: $sortMode) {
				ForEach(TicketSortMode.allCases) { mode in
					Text(mode.title).tag(mode)
				}
			}
			.frame(width: 150)
			Spacer()
			Button {
				let ids = selectedTickets.isEmpty ? Set(filteredTickets.prefix(1).map(\.id)) : selectedTickets
				addToQueue(ids)
			} label: {
				Label("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
			}
			.buttonStyle(.borderedProminent)
			.disabled(tickets.isEmpty)
		}
		.padding()
	}
}

enum TicketSortMode: String, CaseIterable, Identifiable {
	case updated
	case priority
	case complexity

	var id: String { rawValue }

	var title: String {
		switch self {
		case .updated: "Updated"
		case .priority: "Priority"
		case .complexity: "Complexity"
		}
	}
}
