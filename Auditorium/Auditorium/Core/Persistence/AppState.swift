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
	var queueConcurrency = 3
	var isRunningQueue = false

	func inspectTicket(_ id: UUID?) {
		selectedTicketID = id
	}

	func selectProject(_ id: UUID) {
		selectedProjectID = id
		isShowingWelcome = false
	}
}
