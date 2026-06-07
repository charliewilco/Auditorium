import Foundation
import Observation

@Observable
@MainActor
final class AppState {
	var selectedProjectID: UUID?
	var selectedDestination: SidebarDestination = .dashboard
	var selectedTicketID: UUID?
	var selectedRunID: UUID?
	var selectedReportID: UUID?
	var isShowingProjectWizard = false
	var isShowingWelcome = true
	var ticketSearchText = ""
	var isTicketSearchPresented = false
	var queueConcurrency = 3
	var isRunningQueue = false

	func inspectTicket(_ id: UUID?) {
		selectedTicketID = id
	}

	func selectProject(_ id: UUID) {
		selectedProjectID = id
		isShowingWelcome = false
	}

	func showTicketSearch() {
		selectedDestination = .tickets
		isTicketSearchPresented = true
	}

	func inspectSelectedOrFirstTicket(_ firstTicketID: UUID?) {
		if selectedTicketID == nil {
			selectedTicketID = firstTicketID
		}
	}

	func handle(_ command: AppCommand, firstTicketID: UUID? = nil) {
		switch command {
		case .newProject:
			isShowingProjectWizard = true
		case .findTickets:
			showTicketSearch()
		case .inspectSelectedTicket:
			inspectSelectedOrFirstTicket(firstTicketID)
		case .runQueue, .dryRun:
			break
		}
	}
}
