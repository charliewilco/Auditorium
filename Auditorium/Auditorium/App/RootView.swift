import AppKit
import SwiftData
import SwiftUI

struct RootView: View {
	@Environment(\.modelContext) private var modelContext
	@Environment(\.appServices) private var services
	@Environment(AppState.self) private var appState
	@Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
	@Query(sort: \TicketRecord.updatedAt, order: .reverse) private var tickets: [TicketRecord]
	@Query(sort: \QueueItemRecord.position) private var queueItems: [QueueItemRecord]
	@Query(sort: \RunRecord.startedAt, order: .reverse) private var runs: [RunRecord]
	@Query(sort: \TicketRunRecord.startedAt, order: .reverse) private var ticketRuns: [TicketRunRecord]
	@Query(sort: \RuntimeEventRecord.timestamp, order: .reverse) private var events: [RuntimeEventRecord]
	@Query(sort: \PullRequestRecord.createdAt, order: .reverse) private var pullRequests: [PullRequestRecord]
	@Query(sort: \ReportRecord.createdAt, order: .reverse) private var reports: [ReportRecord]
	@State private var runtimeHealth: [RuntimeHealthCheck] = []
	@State private var orchestrator: Orchestrator?
	@AppStorage("requireRunConfirmation") private var requireRunConfirmation = true
	@AppStorage("requirePROpenConfirmation") private var requirePROpenConfirmation = true
	@AppStorage("allowNetworkAccess") private var allowNetworkAccess = false
	@AppStorage("allowFilesystemWrite") private var allowFilesystemWrite = true

	var selectedProject: Project? {
		guard let id = appState.selectedProjectID else { return nil }
		return projects.first { $0.id == id }
	}

	var projectTickets: [TicketRecord] {
		guard let id = appState.selectedProjectID else { return [] }
		return tickets.filter { $0.sourceProjectID == id }
	}

	var projectQueueItems: [QueueItemRecord] {
		guard let id = appState.selectedProjectID else { return [] }
		return queueItems.filter { $0.projectID == id }.sorted { $0.position < $1.position }
	}

	var projectRuns: [RunRecord] {
		guard let id = appState.selectedProjectID else { return [] }
		return runs.filter { $0.projectID == id }
	}

	var body: some View {
		Group {
			if appState.isShowingWelcome || projects.isEmpty {
				WelcomeView(
					createProject: { appState.isShowingProjectWizard = true },
					openDemo: openDemoProject
				)
			} else {
				NavigationSplitView {
					SidebarView(projects: projects)
				} detail: {
					HStack(spacing: 0) {
						detailView
							.frame(minWidth: 620)
						Divider()
						TicketInspectorView(
							project: selectedProject,
							ticket: selectedTicket,
							queueItem: selectedQueueItem,
							latestRun: latestTicketRun,
							events: selectedTicketEvents,
							addToQueue: addSelectedTicketToQueue,
							removeFromQueue: removeSelectedTicketFromQueue,
							runTicket: runSelectedTicket,
							retryTicket: runSelectedTicket
						)
						.frame(width: 340)
					}
				}
			}
		}
		.sheet(isPresented: Binding(get: { appState.isShowingProjectWizard }, set: { appState.isShowingProjectWizard = $0 })) {
			ProjectSetupWizard { projectID in
				appState.selectProject(projectID)
			}
			.frame(minWidth: 760, minHeight: 620)
		}
		.task {
			if orchestrator == nil {
				orchestrator = Orchestrator(workspaceService: services.workspace, runtimeDetection: services.runtimeDetection, reportGenerator: services.reportGenerator)
			}
			runtimeHealth = await services.runtimeDetection.detect()
			if appState.selectedProjectID == nil, let first = projects.first {
				appState.selectProject(first.id)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .runQueueCommand)) { _ in
			runQueue()
		}
	}

	@ViewBuilder
	private var detailView: some View {
		switch appState.selectedDestination {
		case .dashboard:
			ProjectDashboardView(project: selectedProject, tickets: projectTickets, queueItems: projectQueueItems, runs: projectRuns, ticketRuns: ticketRuns, pullRequests: pullRequests, runtimeHealth: runtimeHealth)
		case .tickets:
			TicketBrowserView(project: selectedProject, tickets: projectTickets, queueItems: projectQueueItems, addToQueue: addTicketsToQueue)
		case .queue:
			QueueScreen(project: selectedProject, tickets: projectTickets, queueItems: projectQueueItems, runQueue: runQueue, dryRun: dryRun, clearQueue: clearQueue, removeItem: removeQueueItem, toggleItem: toggleQueueItem, moveItems: moveQueueItems)
		case .runs:
			RunsView(runs: projectRuns, ticketRuns: ticketRuns, tickets: projectTickets, events: events, pullRequests: pullRequests)
		case .reports:
			ReportsView(project: selectedProject, reports: reports.filter { $0.projectID == appState.selectedProjectID }, reveal: revealReport)
		case .settings:
			SettingsContentView(runtimeHealth: runtimeHealth)
		}
	}

	private var selectedTicket: TicketRecord? {
		guard let selectedTicketID = appState.selectedTicketID else {
			return projectTickets.first
		}
		return projectTickets.first { $0.id == selectedTicketID }
	}

	private var selectedQueueItem: QueueItemRecord? {
		guard let ticketID = selectedTicket?.id else { return nil }
		return projectQueueItems.first { $0.ticketID == ticketID }
	}

	private var latestTicketRun: TicketRunRecord? {
		guard let ticketID = selectedTicket?.id else { return nil }
		return ticketRuns.filter { $0.ticketID == ticketID }.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }.first
	}

	private var selectedTicketEvents: [RuntimeEventRecord] {
		guard let ticketRunID = latestTicketRun?.id else { return [] }
		return events.filter { $0.ticketRunID == ticketRunID }.sorted { $0.timestamp < $1.timestamp }
	}

	private func openDemoProject() {
		do {
			let id = try DemoDataSeeder(workspaceService: services.workspace).openDemoProject(in: modelContext)
			appState.selectProject(id)
		} catch {
			NSAlert(error: error).runModal()
		}
	}

	private func addTicketsToQueue(_ ids: Set<UUID>) {
		guard let projectID = appState.selectedProjectID else { return }
		do {
			try QueueService().addTickets(ids, projectID: projectID, context: modelContext)
		} catch {
			NSAlert(error: error).runModal()
		}
	}

	private func addSelectedTicketToQueue() {
		guard let ticket = selectedTicket else { return }
		addTicketsToQueue([ticket.id])
	}

	private func removeSelectedTicketFromQueue() {
		guard let item = selectedQueueItem else { return }
		removeQueueItem(item)
	}

	private func runSelectedTicket() {
		guard let ticket = selectedTicket, let projectID = appState.selectedProjectID else { return }
		do {
			try QueueService().clearQueue(projectID: projectID, context: modelContext)
			try QueueService().addTickets([ticket.id], projectID: projectID, context: modelContext)
			runQueue()
		} catch {
			NSAlert(error: error).runModal()
		}
	}

	private func runQueue() {
		guard let project = selectedProject else { return }
		let preferences = RunSecurityPreferences(
			allowNetworkAccess: allowNetworkAccess,
			allowFilesystemWrite: allowFilesystemWrite,
			requireRunConfirmation: requireRunConfirmation,
			requirePullRequestConfirmation: requirePROpenConfirmation
		)
		let policy = RunSecurityPolicy()
		do {
			try policy.validate(project: project, preferences: preferences)
		} catch {
			NSAlert(error: error).runModal()
			return
		}
		if preferences.requireRunConfirmation, confirm(title: "Start Run?", message: "Auditorium will start \(projectQueueItems.filter(\.isEnabled).count) enabled queue items.") == false {
			return
		}
		if preferences.requirePullRequestConfirmation, policy.wouldOpenPullRequest(project: project), confirm(title: "Allow Pull Requests?", message: "This workflow may push branches and open GitHub pull requests.") == false {
			return
		}
		appState.selectedDestination = .runs
		orchestrator?.runQueue(projectID: project.id, concurrency: appState.queueConcurrency, context: modelContext)
	}

	private func dryRun() {
		guard let projectID = appState.selectedProjectID else { return }
		let run = RunRecord(projectID: projectID, status: .completed, totalTickets: projectQueueItems.filter { $0.isEnabled }.count, summary: "Dry run completed. No workspaces or agents were started.")
		run.endedAt = .now
		modelContext.insert(run)
		modelContext.insert(RuntimeEventRecord(runID: run.id, level: .success, category: .orchestration, message: "Dry run validated \(run.totalTickets) enabled queue items."))
		try? modelContext.save()
		appState.selectedDestination = .runs
	}

	private func clearQueue() {
		guard let projectID = appState.selectedProjectID else { return }
		try? QueueService().clearQueue(projectID: projectID, context: modelContext)
	}

	private func removeQueueItem(_ item: QueueItemRecord) {
		try? QueueService().removeQueueItem(item, context: modelContext)
	}

	private func toggleQueueItem(_ item: QueueItemRecord, isEnabled: Bool) {
		try? QueueService().setQueueItem(item, isEnabled: isEnabled, context: modelContext)
	}

	private func moveQueueItems(_ offsets: IndexSet, _ destination: Int) {
		guard let projectID = appState.selectedProjectID else { return }
		try? QueueService().moveQueueItems(from: offsets, to: destination, projectID: projectID, context: modelContext)
	}

	private func revealReport(_ report: ReportRecord) {
		NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report.filePath)])
	}

	private func confirm(title: String, message: String) -> Bool {
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = message
		alert.addButton(withTitle: "Continue")
		alert.addButton(withTitle: "Cancel")
		return alert.runModal() == .alertFirstButtonReturn
	}
}
