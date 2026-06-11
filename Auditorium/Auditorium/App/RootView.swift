import AppKit
import SwiftData
import SwiftUI

struct RootView: View {
	@Environment(\.modelContext) private var modelContext
	@Environment(\.appServices) private var services
	@Environment(AppState.self) private var appState
	@Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
	@Query(sort: \RepositoryRecord.fullName) private var repositories: [RepositoryRecord]
	@Query(sort: \IssueTrackerRecord.displayName) private var issueTrackers: [IssueTrackerRecord]
	@Query(sort: \TicketRecord.updatedAt, order: .reverse) private var tickets: [TicketRecord]
	@Query(sort: \QueueItemRecord.position) private var queueItems: [QueueItemRecord]
	@Query(sort: \RunRecord.startedAt, order: .reverse) private var runs: [RunRecord]
	@Query(sort: \TicketRunRecord.startedAt, order: .reverse) private var ticketRuns: [TicketRunRecord]
	@Query(sort: \RuntimeEventRecord.timestamp, order: .reverse) private var events: [RuntimeEventRecord]
	@Query(sort: \CoordinationMessageRecord.createdAt, order: .reverse) private var coordinationMessages: [CoordinationMessageRecord]
	@Query(sort: \PullRequestRecord.createdAt, order: .reverse) private var pullRequests: [PullRequestRecord]
	@Query(sort: \ReportRecord.createdAt, order: .reverse) private var reports: [ReportRecord]
	@Query(sort: \ProviderAccountRecord.updatedAt, order: .reverse) private var providerAccounts: [ProviderAccountRecord]
	@State private var runtimeHealth: [RuntimeHealthCheck] = []
	@State private var symphonyDoctorStatus: SymphonyDoctorStatus?
	@State private var runCoordinator: AppRunCoordinator?
	@State private var didReconcileInterruptedRuns = false
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

	var selectedRepository: RepositoryRecord? {
		guard let id = appState.selectedProjectID else { return nil }
		return repositories.first { $0.projectID == id }
	}

	var selectedIssueTracker: IssueTrackerRecord? {
		guard let id = appState.selectedProjectID else { return nil }
		return issueTrackers.first { $0.projectID == id }
	}

	var demoModeState: DemoModeState? {
		DemoModeState(project: selectedProject, repository: selectedRepository, issueTracker: selectedIssueTracker)
	}

	var workspaceLocations: WorkspaceLocationState? {
		guard let project = selectedProject else { return nil }
		return WorkspaceLocationState(project: project, repository: selectedRepository, workspaceService: services.workspace)
	}

	var body: some View {
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
					retryTicket: runSelectedTicket,
					cancelRun: cancelActiveRun
				)
				.frame(width: 340)
			}
		}
		.sheet(isPresented: Binding(get: { appState.isShowingProjectWizard }, set: { appState.isShowingProjectWizard = $0 })) {
			ProjectSetupWizard { projectID in
				appState.selectProject(projectID)
			}
			.frame(minWidth: 760, minHeight: 620)
		}
		.task(id: appState.selectedProjectID) {
			_ = ensureRunCoordinator()
			reconcileInterruptedRunsIfNeeded()
			let activeProject = selectedProject ?? projects.first
			runtimeHealth = await services.runtimeDetection.detect()
			await refreshSymphonyDoctorStatus(for: activeProject)
			if appState.selectedProjectID == nil, let first = activeProject {
				appState.selectProject(first.id)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .runQueueCommand)) { _ in
			runQueue()
		}
		.onReceive(NotificationCenter.default.publisher(for: .dryRunCommand)) { _ in
			dryRun()
		}
		.onReceive(NotificationCenter.default.publisher(for: .focusTicketSearchCommand)) { _ in
			appState.handle(.findTickets)
		}
		.onReceive(NotificationCenter.default.publisher(for: .inspectTicketCommand)) { _ in
			appState.handle(.inspectSelectedTicket, firstTicketID: projectTickets.first?.id)
		}
	}

	private func reconcileInterruptedRunsIfNeeded() {
		guard didReconcileInterruptedRuns == false else { return }
		didReconcileInterruptedRuns = true
		do {
			_ = try RunReconciliationService().reconcileInterruptedRuns(context: modelContext)
		}
		catch {
			NSAlert(error: error).runModal()
		}
	}

	@ViewBuilder
	private var detailView: some View {
		switch appState.selectedDestination {
		case .dashboard:
			ProjectDashboardView(
				project: selectedProject,
				tickets: projectTickets,
				queueItems: projectQueueItems,
				runs: projectRuns,
				ticketRuns: ticketRuns,
				pullRequests: pullRequests,
				reports: reports.filter { $0.projectID == appState.selectedProjectID },
				events: events,
				runtimeHealth: runtimeHealth,
				symphonyDoctorStatus: symphonyDoctorStatus,
				preflightSummary: runPreflightSummary,
				demoModeState: demoModeState,
				workspaceLocations: workspaceLocations,
				selectedTicketID: appState.selectedTicketID,
				runQueue: runQueue,
				dryRun: dryRun,
				openTickets: { appState.selectedDestination = .tickets },
				openQueue: { appState.selectedDestination = .queue },
				openRuns: { appState.selectedDestination = .runs },
				openReports: { appState.selectedDestination = .reports },
				openSettings: { appState.selectedDestination = .settings },
				inspectTicket: { appState.inspectTicket($0) },
				revealLocation: revealLocation,
				resetDemoProject: resetDemoProject
			)
		case .tickets:
			TicketBrowserView(
				project: selectedProject,
				tickets: projectTickets,
				queueItems: projectQueueItems,
				addToQueue: addTicketsToQueue
			)
		case .queue:
			QueueScreen(
				project: selectedProject,
				tickets: projectTickets,
				queueItems: projectQueueItems,
				preflightSummary: runPreflightSummary,
				runQueue: runQueue,
				dryRun: dryRun,
				clearQueue: clearQueue,
				removeItem: removeQueueItem,
				removeItems: removeQueueItems,
				toggleItem: toggleQueueItem,
				setItemsEnabled: setQueueItemsEnabled,
				moveItems: moveQueueItems
			)
		case .runs:
			RunsView(
				runs: projectRuns,
				ticketRuns: ticketRuns,
				tickets: projectTickets,
				events: events,
				coordinationMessages: coordinationMessages,
				pullRequests: pullRequests,
				reports: reports
			)
		case .reports:
			ReportsView(
				project: selectedProject,
				reports: reports.filter { $0.projectID == appState.selectedProjectID },
				reveal: revealReport
			)
		case .settings:
			SettingsContentView(project: selectedProject, runtimeHealth: runtimeHealth, symphonyDoctorStatus: symphonyDoctorStatus)
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

	private var runSecurityPreferences: RunSecurityPreferences {
		RunSecurityPreferences(
			allowNetworkAccess: allowNetworkAccess,
			allowFilesystemWrite: allowFilesystemWrite,
			requireRunConfirmation: requireRunConfirmation,
			requirePullRequestConfirmation: requirePROpenConfirmation
		)
	}

	private var runPreflightSummary: RunPreflightSummary? {
		guard let project = selectedProject else { return nil }
		return RunPreflightSummary.make(
			project: project,
			queueItems: projectQueueItems,
			tickets: projectTickets,
			runtimeHealth: runtimeHealth,
			providerAccounts: providerAccounts,
			preferences: runSecurityPreferences,
			workspaceRoot: services.workspace.workspacesDirectory(projectID: project.id).path()
		) { account in
			try services.keychain.readSecret(account: account)
		}
	}

	private func openDemoProject() {
		do {
			let id = try DemoDataSeeder(workspaceService: services.workspace).openDemoProject(in: modelContext)
			appState.selectProject(id)
		}
		catch {
			NSAlert(error: error).runModal()
		}
	}

	private func resetDemoProject() {
		do {
			let id = try DemoDataSeeder(workspaceService: services.workspace).resetDemoProject(in: modelContext)
			appState.selectProject(id)
			appState.selectedDestination = .dashboard
		}
		catch {
			NSAlert(error: error).runModal()
		}
	}

	private func refreshSymphonyDoctorStatus(for project: Project?) async {
		guard let project else {
			symphonyDoctorStatus = await services.symphony.doctor()
			return
		}
		do {
			try services.workspace.ensureProjectLayout(projectID: project.id)
			let workflowURL = services.workspace.projectDirectory(projectID: project.id).appending(path: "WORKFLOW.md")
			try project.workflowPolicyMarkdown.write(to: workflowURL, atomically: true, encoding: .utf8)
			symphonyDoctorStatus = await services.symphony.doctor(workflowPath: workflowURL)
		}
		catch {
			symphonyDoctorStatus = SymphonyDoctorStatus(
				state: .error,
				detail: "Unable to prepare workflow for symphony doctor: \(error.localizedDescription)",
				workflowDetail: "Workflow validation did not run.",
				checks: []
			)
		}
	}

	private func addTicketsToQueue(_ ids: Set<UUID>) {
		guard let projectID = appState.selectedProjectID else { return }
		do {
			try QueueService().addTickets(ids, projectID: projectID, context: modelContext)
		}
		catch {
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
		}
		catch {
			NSAlert(error: error).runModal()
		}
	}

	private func runQueue() {
		guard let project = selectedProject else { return }
		let preferences = runSecurityPreferences
		if let runPreflightSummary, runPreflightSummary.canStartRun == false {
			NSAlert(error: ProviderError.unavailable(runPreflightSummary.blockingChecks.map(\.detail).joined(separator: "\n"))).runModal()
			return
		}
		let policy = RunSecurityPolicy()
		do {
			try policy.validate(project: project, preferences: preferences)
		}
		catch {
			NSAlert(error: error).runModal()
			return
		}
		if preferences.requireRunConfirmation,
			confirm(
				title: "Start Run?",
				message: "Auditorium will start \(projectQueueItems.filter(\.isEnabled).count) enabled queue items."
			) == false
		{
			return
		}
		if preferences.requirePullRequestConfirmation, policy.wouldOpenPullRequest(project: project),
			confirm(title: "Allow Pull Requests?", message: "This workflow may push branches and open GitHub pull requests.") == false
		{
			return
		}
		appState.selectedDestination = .runs
		ensureRunCoordinator().startQueue(project: project, concurrency: appState.queueConcurrency, context: modelContext)
	}

	private func cancelActiveRun() {
		ensureRunCoordinator().cancelActiveRun()
	}

	private func dryRun() {
		guard let project = selectedProject else { return }
		do {
			try ensureRunCoordinator().createDryRun(
				project: project,
				queueItems: projectQueueItems,
				tickets: projectTickets,
				context: modelContext
			)
		}
		catch {
			NSAlert(error: error).runModal()
			return
		}
		appState.selectedDestination = .runs
	}

	private func ensureRunCoordinator() -> AppRunCoordinator {
		if let runCoordinator {
			return runCoordinator
		}
		let coordinator = AppRunCoordinator(
			workspaceService: services.workspace,
			runtimeDetection: services.runtimeDetection,
			reportGenerator: services.reportGenerator,
			symphonyRunner: services.symphony,
			providerRegistry: services.providerRegistry
		)
		runCoordinator = coordinator
		return coordinator
	}

	private func clearQueue() {
		guard let projectID = appState.selectedProjectID else { return }
		try? QueueService().clearQueue(projectID: projectID, context: modelContext)
	}

	private func removeQueueItem(_ item: QueueItemRecord) {
		try? QueueService().removeQueueItem(item, context: modelContext)
	}

	private func removeQueueItems(_ itemIDs: Set<UUID>) {
		guard let projectID = appState.selectedProjectID else { return }
		try? QueueService().removeQueueItems(itemIDs, projectID: projectID, context: modelContext)
	}

	private func toggleQueueItem(_ item: QueueItemRecord, isEnabled: Bool) {
		try? QueueService().setQueueItem(item, isEnabled: isEnabled, context: modelContext)
	}

	private func setQueueItemsEnabled(_ itemIDs: Set<UUID>, isEnabled: Bool) {
		guard let projectID = appState.selectedProjectID else { return }
		try? QueueService().setQueueItems(itemIDs, isEnabled: isEnabled, projectID: projectID, context: modelContext)
	}

	private func moveQueueItems(_ offsets: IndexSet, _ destination: Int) {
		guard let projectID = appState.selectedProjectID else { return }
		try? QueueService().moveQueueItems(from: offsets, to: destination, projectID: projectID, context: modelContext)
	}

	private func revealReport(_ report: ReportRecord) {
		NSWorkspace.shared.activateFileViewerSelecting([ReportActions.revealURL(for: report)])
	}

	private func revealLocation(_ url: URL) {
		try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		NSWorkspace.shared.activateFileViewerSelecting([url])
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
