import SwiftData
import SwiftUI

struct WelcomeStartWindowView: View {
	@Environment(AppState.self) private var appState
	@Environment(\.openWindow) private var openWindow
	@Environment(\.dismissWindow) private var dismissWindow
	@Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
	@Query(sort: \RunRecord.startedAt, order: .reverse) private var runs: [RunRecord]
	@Query(sort: \TicketRunRecord.startedAt, order: .reverse) private var ticketRuns: [TicketRunRecord]
	@Query(sort: \PullRequestRecord.createdAt, order: .reverse) private var pullRequests: [PullRequestRecord]
	@State private var isShowingPrerequisites = false

	var body: some View {
		WelcomeView(
			rows: projectSummaries,
			version: appVersion,
			createProject: createProject,
			checkPrerequisites: checkPrerequisites,
			seeAllProjects: seeAllProjects,
			selectProject: selectProject,
			close: closeWelcome
		)
		.sheet(isPresented: $isShowingPrerequisites) {
			WelcomePrerequisitesSheet()
		}
	}

	private var appVersion: String {
		let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
		return "v\(version?.isEmpty == false ? version ?? "1.0" : "1.0")"
	}

	private var projectSummaries: [WelcomeProjectSummary] {
		let runsByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
		let ticketRunsByID = Dictionary(uniqueKeysWithValues: ticketRuns.map { ($0.id, $0) })
		let runsByProjectID = Dictionary(grouping: runs, by: \.projectID)
		let pullRequestsByProjectID = pullRequests.reduce(into: [UUID: [PullRequestRecord]]()) { result, pullRequest in
			guard let ticketRun = ticketRunsByID[pullRequest.ticketRunID],
				let run = runsByID[ticketRun.runID]
			else { return }
			result[run.projectID, default: []].append(pullRequest)
		}

		return
			projects
			.map { project in
				let projectRuns = runsByProjectID[project.id] ?? []
				let projectPullRequests = pullRequestsByProjectID[project.id] ?? []
				let latestRun = projectRuns.max { activityDate(for: $0) < activityDate(for: $1) }
				let latestPullRequestDate = projectPullRequests.map(activityDate(for:)).max()
				let latestActivity =
					[project.updatedAt, latestRun.map(activityDate(for:)), latestPullRequestDate]
					.compactMap { $0 }
					.max() ?? project.updatedAt
				return WelcomeProjectSummary(
					id: project.id,
					name: project.name,
					subtitle: latestRun.map {
						"last run \(Self.relativeFormatter.localizedString(for: activityDate(for: $0), relativeTo: .now))"
					}
						?? "updated \(Self.relativeFormatter.localizedString(for: project.updatedAt, relativeTo: .now))",
					pullRequestCount: projectPullRequests.count,
					repositorySymbol: project.repositoryProviderKind.symbol,
					issueSymbol: project.issueProviderKind.symbol,
					latestActivityAt: latestActivity
				)
			}
			.sorted {
				if $0.latestActivityAt == $1.latestActivityAt {
					return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
				}
				return $0.latestActivityAt > $1.latestActivityAt
			}
	}

	private func createProject() {
		appState.isShowingProjectWizard = true
		openMainWindow()
	}

	private func checkPrerequisites() {
		isShowingPrerequisites = true
	}

	private func seeAllProjects() {
		appState.selectedDestination = .dashboard
		openMainWindow()
	}

	private func selectProject(_ id: UUID) {
		appState.selectProject(id)
		appState.selectedDestination = .dashboard
		openMainWindow()
	}

	private func closeWelcome() {
		dismissWindow(id: AppSceneID.welcome)
	}

	private func openMainWindow() {
		openWindow(id: AppSceneID.main)
		dismissWindow(id: AppSceneID.welcome)
	}

	private func activityDate(for run: RunRecord) -> Date {
		run.endedAt ?? run.startedAt
	}

	private func activityDate(for pullRequest: PullRequestRecord) -> Date {
		pullRequest.mergedAt ?? pullRequest.createdAt
	}

	private static let relativeFormatter: RelativeDateTimeFormatter = {
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .full
		return formatter
	}()
}
