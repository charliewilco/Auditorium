import SwiftUI

struct ProjectDashboardView: View {
	let project: Project?
	let tickets: [TicketRecord]
	let queueItems: [QueueItemRecord]
	let runs: [RunRecord]
	let ticketRuns: [TicketRunRecord]
	let pullRequests: [PullRequestRecord]
	let reports: [ReportRecord]
	let events: [RuntimeEventRecord]
	let runtimeHealth: [RuntimeHealthCheck]
	let symphonyDoctorStatus: SymphonyDoctorStatus?
	let preflightSummary: RunPreflightSummary?
	let demoModeState: DemoModeState?
	let workspaceLocations: WorkspaceLocationState?
	let selectedTicketID: UUID?
	let runQueue: () -> Void
	let dryRun: () -> Void
	let openTickets: () -> Void
	let openQueue: () -> Void
	let openRuns: () -> Void
	let openReports: () -> Void
	let openSettings: () -> Void
	let inspectTicket: (UUID) -> Void
	let revealLocation: (URL) -> Void
	let resetDemoProject: () -> Void

	private var dashboardState: ProjectDashboardState {
		ProjectDashboardState(
			project: project,
			tickets: tickets,
			queueItems: queueItems,
			runs: runs,
			ticketRuns: ticketRuns,
			pullRequests: pullRequests,
			reports: reports,
			events: events,
			preflightSummary: preflightSummary
		)
	}

	var body: some View {
		let state = dashboardState
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				header(state)
				if let demoModeState, demoModeState.isDemoProject {
					DemoModePanelView(state: demoModeState, resetDemoProject: resetDemoProject)
				}
				metricsStrip(state)
				ProjectDashboardReadinessPanel(state: state, openQueue: openQueue, openSettings: openSettings)
				ProjectDashboardActiveWorkPanel(
					state: state,
					selectedTicketID: selectedTicketID,
					inspectTicket: inspectTicket,
					openRuns: openRuns,
					openTickets: openTickets
				)
				HStack(alignment: .top, spacing: 16) {
					ProjectDashboardReviewPanel(state: state, inspectTicket: inspectTicket, openRuns: openRuns)
					ProjectDashboardOutputPanel(state: state, openReports: openReports)
				}
				utilitySection
			}
			.padding()
		}
		.navigationTitle("Dashboard")
	}

	private func header(_ state: ProjectDashboardState) -> some View {
		HStack(alignment: .center, spacing: 18) {
			VStack(alignment: .leading, spacing: 6) {
				Text(state.projectTitle)
					.font(.largeTitle.weight(.semibold))
				Text(state.repositorySubtitle)
					.foregroundStyle(.secondary)
				HStack(spacing: 8) {
					StatusBadge(title: state.runtimeTitle, tint: project == nil ? .secondary : .green)
					StatusBadge(title: state.agentTitle, tint: project == nil ? .secondary : .blue)
				}
			}
			Spacer()
			Button {
				dryRun()
			} label: {
				Label("Dry Run", systemImage: "checklist")
			}
			.buttonStyle(.bordered)
			.disabled(project == nil)
			Button {
				runQueue()
			} label: {
				Label("Run Queue", systemImage: "play.circle.fill")
			}
			.buttonStyle(.borderedProminent)
			.disabled(state.canRunQueue == false)
		}
	}

	private func metricsStrip(_ state: ProjectDashboardState) -> some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
			StatCard(title: "Open Tickets", value: "\(state.openTicketCount)", symbol: "ticket", tint: .blue)
			StatCard(
				title: "Queued",
				value: "\(state.queuedTicketCount)",
				symbol: "text.line.first.and.arrowtriangle.forward",
				tint: .purple
			)
			StatCard(title: "Running", value: "\(state.runningAgentCount)", symbol: "cpu", tint: .orange)
			StatCard(title: "Completed Today", value: "\(state.completedTodayCount)", symbol: "checkmark.circle.fill", tint: .green)
			StatCard(title: "Success Rate", value: state.successRateText, symbol: "chart.line.uptrend.xyaxis", tint: .teal)
		}
	}

	private var utilitySection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label("Project Utilities", systemImage: "wrench.and.screwdriver")
				.font(.headline)
			HStack(alignment: .top, spacing: 16) {
				summaryPanel(
					"Repository",
					symbol: "shippingbox",
					rows: [
						("Name", project?.repositoryName ?? "No project"),
						("Provider", project?.repositoryProviderKind.title ?? "Unknown"),
						("Default Branch", project?.defaultBranch ?? "Unknown"),
					]
				)
				summaryPanel(
					"Issue Source",
					symbol: "ticket",
					rows: [
						("Provider", project?.issueProviderKind.title ?? "Unknown"),
						("Open Tickets", "\(tickets.filter { $0.status != .completed }.count)"),
						("Queued", "\(queueItems.count)"),
					]
				)
			}
			HStack(alignment: .top, spacing: 16) {
				runtimePanel
				workspaceLocationsPanel
			}
		}
	}

	private func summaryPanel(_ title: String, symbol: String, rows: [(String, String)]) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Label(title, systemImage: symbol)
				.font(.headline)
			ForEach(rows, id: \.0) { row in
				LabeledContent(row.0, value: row.1)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private var workspaceLocationsPanel: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label("Local Paths", systemImage: "folder")
				.font(.headline)
			if let workspaceLocations {
				ForEach(workspaceLocations.items) { item in
					HStack(alignment: .firstTextBaseline, spacing: 12) {
						VStack(alignment: .leading, spacing: 4) {
							Text(item.title)
								.font(.callout.weight(.medium))
							Text(item.path)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(1)
								.truncationMode(.middle)
								.textSelection(.enabled)
						}
						Spacer()
						Button {
							revealLocation(item.url)
						} label: {
							Label("Reveal", systemImage: "folder")
						}
					}
				}
			}
			else {
				Text("No project selected.")
					.foregroundStyle(.secondary)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private var runtimePanel: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label("Runtime Health", systemImage: "cpu")
				.font(.headline)
			SymphonyDoctorStatusView(status: symphonyDoctorStatus)
			ForEach(runtimeHealth) { health in
				HStack {
					VStack(alignment: .leading) {
						Text(health.name)
						Text(health.detail)
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
					Spacer()
					StatusBadge(title: health.state.title, tint: health.state.tint)
				}
			}
			if runtimeHealth.isEmpty {
				Text("Runtime checks have not reported yet.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}
}

#Preview("Dashboard") {
	ProjectDashboardView(
		project: ProjectDashboardPreviewData.project,
		tickets: ProjectDashboardPreviewData.tickets,
		queueItems: ProjectDashboardPreviewData.queueItems,
		runs: [ProjectDashboardPreviewData.run],
		ticketRuns: ProjectDashboardPreviewData.ticketRuns,
		pullRequests: ProjectDashboardPreviewData.pullRequests,
		reports: ProjectDashboardPreviewData.reports,
		events: ProjectDashboardPreviewData.events,
		runtimeHealth: [],
		symphonyDoctorStatus: nil,
		preflightSummary: ProjectDashboardPreviewData.preflightSummary,
		demoModeState: nil,
		workspaceLocations: nil,
		selectedTicketID: ProjectDashboardPreviewData.firstTicketID,
		runQueue: {},
		dryRun: {},
		openTickets: {},
		openQueue: {},
		openRuns: {},
		openReports: {},
		openSettings: {},
		inspectTicket: { _ in },
		revealLocation: { _ in },
		resetDemoProject: {}
	)
	.frame(width: 900, height: 760)
}
