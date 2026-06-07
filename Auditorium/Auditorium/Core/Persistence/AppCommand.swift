import Foundation

enum AppCommand: String, CaseIterable, Identifiable, Sendable {
	case newProject
	case runQueue
	case dryRun
	case findTickets
	case inspectSelectedTicket

	var id: String { rawValue }

	var title: String {
		switch self {
		case .newProject: "New Project"
		case .runQueue: "Run Queue"
		case .dryRun: "Dry Run"
		case .findTickets: "Find Tickets"
		case .inspectSelectedTicket: "Inspect Selected Ticket"
		}
	}

	var notificationName: Notification.Name? {
		switch self {
		case .newProject:
			nil
		case .runQueue:
			.runQueueCommand
		case .dryRun:
			.dryRunCommand
		case .findTickets:
			.focusTicketSearchCommand
		case .inspectSelectedTicket:
			.inspectTicketCommand
		}
	}
}

extension Notification.Name {
	static let runQueueCommand = Notification.Name("RunQueueCommand")
	static let dryRunCommand = Notification.Name("DryRunCommand")
	static let focusTicketSearchCommand = Notification.Name("FocusTicketSearchCommand")
	static let inspectTicketCommand = Notification.Name("InspectTicketCommand")
}
