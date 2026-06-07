import Foundation
import SwiftData

@MainActor
struct DemoDataSeeder {
	static let projectName = "Burton Demo"
	static let repositoryFullName = "charlie/burton-ios"
	static let repositoryURL = "https://github.com/charlie/burton-ios"
	static let defaultBranch = "next"

	let workspaceService: ApplicationWorkspaceService

	func openDemoProject(in context: ModelContext) throws -> UUID {
		let projects = try context.fetch(FetchDescriptor<Project>())
		if let existing = projects.first(where: { Self.isDemoProject($0) }) {
			try workspaceService.ensureProjectLayout(projectID: existing.id)
			return existing.id
		}

		let project = Project(
			name: Self.projectName,
			repositoryProviderKind: .github,
			repositoryName: Self.repositoryFullName,
			repositoryURL: Self.repositoryURL,
			defaultBranch: Self.defaultBranch,
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
		context.insert(project)

		let repository = RepositoryRecord(
			provider: .github,
			owner: "charlie",
			name: "burton-ios",
			fullName: Self.repositoryFullName,
			cloneURL: "\(Self.repositoryURL).git",
			webURL: Self.repositoryURL,
			defaultBranch: Self.defaultBranch,
			localPath: workspaceService.repositoryDirectory(projectID: project.id).path(),
			projectID: project.id
		)
		context.insert(repository)
		context.insert(IssueTrackerRecord(
			provider: .githubIssues,
			displayName: Self.repositoryFullName,
			sourceIdentifier: Self.repositoryFullName,
			filterName: "Ready for agent",
			webURL: "\(Self.repositoryURL)/issues",
			projectID: project.id
		))

		for demoTicket in DemoTickets.all {
			let descriptor = demoTicket.descriptor
			context.insert(TicketRecord(
				provider: descriptor.provider,
				externalID: descriptor.externalID,
				title: descriptor.title,
				body: descriptor.body,
				status: descriptor.status,
				labels: descriptor.labels,
				assignee: descriptor.assignee,
				priority: descriptor.priority,
				webURL: descriptor.webURL?.absoluteString ?? "",
				createdAt: descriptor.createdAt,
				updatedAt: descriptor.updatedAt,
				estimatedComplexity: descriptor.estimatedComplexity,
				blockedBy: descriptor.blockedBy,
				sourceProjectID: project.id
			))
		}

		try workspaceService.ensureProjectLayout(projectID: project.id)
		try ModelIntegrityValidator.save(context: context)
		return project.id
	}

	func resetDemoProject(in context: ModelContext) throws -> UUID {
		let projects = try context.fetch(FetchDescriptor<Project>())
		let demoProjects = projects.filter { Self.isDemoProject($0) }
		for project in demoProjects {
			try deleteProjectTree(projectID: project.id, context: context)
			try? FileManager.default.removeItem(at: workspaceService.projectDirectory(projectID: project.id))
		}
		try ModelIntegrityValidator.save(context: context)
		return try openDemoProject(in: context)
	}

	static func isDemoProject(_ project: Project) -> Bool {
		project.name == projectName &&
			project.repositoryName == repositoryFullName &&
			project.runtimeProviderKind == .mockRuntime &&
			project.agentProviderKind == .mockAgent
	}

	private func deleteProjectTree(projectID: UUID, context: ModelContext) throws {
		let repositories = try context.fetch(FetchDescriptor<RepositoryRecord>()).filter { $0.projectID == projectID }
		let issueTrackers = try context.fetch(FetchDescriptor<IssueTrackerRecord>()).filter { $0.projectID == projectID }
		let accountIDs = Set((repositories.compactMap(\.providerAccountID) + issueTrackers.compactMap(\.providerAccountID)))
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>()).filter { $0.sourceProjectID == projectID }
		let ticketIDs = Set(tickets.map(\.id))
		let runs = try context.fetch(FetchDescriptor<RunRecord>()).filter { $0.projectID == projectID }
		let runIDs = Set(runs.map(\.id))
		let ticketRuns = try context.fetch(FetchDescriptor<TicketRunRecord>()).filter { runIDs.contains($0.runID) || ticketIDs.contains($0.ticketID) }
		let ticketRunIDs = Set(ticketRuns.map(\.id))

		try context.fetch(FetchDescriptor<RuntimeEventRecord>())
			.filter { runIDs.contains($0.runID) || $0.ticketRunID.map(ticketRunIDs.contains) == true }
			.forEach(context.delete)
		try context.fetch(FetchDescriptor<PullRequestRecord>())
			.filter { ticketRunIDs.contains($0.ticketRunID) }
			.forEach(context.delete)
		try context.fetch(FetchDescriptor<ReportRecord>())
			.filter { $0.projectID == projectID || runIDs.contains($0.runID) }
			.forEach(context.delete)
		ticketRuns.forEach(context.delete)
		runs.forEach(context.delete)
		try context.fetch(FetchDescriptor<QueueItemRecord>())
			.filter { $0.projectID == projectID || ticketIDs.contains($0.ticketID) }
			.forEach(context.delete)
		tickets.forEach(context.delete)
		repositories.forEach(context.delete)
		issueTrackers.forEach(context.delete)
		try context.fetch(FetchDescriptor<ProviderAccountRecord>())
			.filter { accountIDs.contains($0.id) }
			.forEach(context.delete)
		try context.fetch(FetchDescriptor<Project>())
			.filter { $0.id == projectID }
			.forEach(context.delete)
	}
}

struct DemoModeState: Equatable {
	let isDemoProject: Bool
	let usesOfflineRuntime: Bool
	let hasStoredCredentials: Bool

	var title: String {
		isDemoProject ? "Offline Demo" : "Live Project"
	}

	var detail: String {
		if isDemoProject && isNetworkFree {
			return "Mock runtime and mock agent are active. No GitHub credentials are attached."
		}
		if isDemoProject {
			return "Demo project needs attention before it can be treated as fully offline."
		}
		return "Project uses configured providers."
	}

	var isNetworkFree: Bool {
		isDemoProject && usesOfflineRuntime && hasStoredCredentials == false
	}

	@MainActor
	init(project: Project?, repository: RepositoryRecord?, issueTracker: IssueTrackerRecord?) {
		guard let project else {
			isDemoProject = false
			usesOfflineRuntime = false
			hasStoredCredentials = false
			return
		}
		isDemoProject = DemoDataSeeder.isDemoProject(project)
		usesOfflineRuntime = project.runtimeProviderKind == .mockRuntime && project.agentProviderKind == .mockAgent
		hasStoredCredentials = repository?.providerAccountID != nil || issueTracker?.providerAccountID != nil
	}
}

struct DemoTicketSeed {
	let externalID: String
	let title: String
	let body: String
	let labels: [String]
	let priority: PriorityLevel
	let complexity: Int

	var descriptor: TicketDescriptor {
		TicketDescriptor(
			provider: .githubIssues,
			externalID: externalID,
			title: title,
			body: body,
			status: .ready,
			labels: labels,
			assignee: "Charlie",
			priority: priority,
			webURL: URL(string: "https://github.com/charlie/burton-ios/issues/\(externalID.replacingOccurrences(of: "BUR-", with: ""))"),
			createdAt: Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now,
			updatedAt: Calendar.current.date(byAdding: .hour, value: -Int.random(in: 2...40), to: .now) ?? .now,
			estimatedComplexity: complexity,
			blockedBy: []
		)
	}
}

enum DemoTickets {
	static let all: [DemoTicketSeed] = [
		DemoTicketSeed(
			externalID: "BUR-101",
			title: "Fix OAuth refresh race condition",
			body: "Session refresh can overlap during app launch and timeline hydration, occasionally replacing a fresh token with a stale response.",
			labels: ["auth", "race-condition"],
			priority: .urgent,
			complexity: 8
		),
		DemoTicketSeed(
			externalID: "BUR-102",
			title: "Add dark mode notification preview",
			body: "Notification previews in Settings should show the same color treatment users see in dark mode.",
			labels: ["ui", "notifications"],
			priority: .medium,
			complexity: 4
		),
		DemoTicketSeed(
			externalID: "BUR-103",
			title: "Improve low-connectivity timeline cache",
			body: "Timeline loading should reuse the last successful cache snapshot when connectivity is poor.",
			labels: ["offline", "timeline"],
			priority: .high,
			complexity: 9
		),
		DemoTicketSeed(
			externalID: "BUR-104",
			title: "Add empty state for muted accounts",
			body: "The muted accounts screen currently renders a blank list when the user has no muted accounts.",
			labels: ["empty-state", "settings"],
			priority: .low,
			complexity: 2
		),
		DemoTicketSeed(
			externalID: "BUR-105",
			title: "Refactor profile header layout",
			body: "Profile header spacing should adapt cleanly between compact and expanded macOS window sizes.",
			labels: ["profile", "macos"],
			priority: .medium,
			complexity: 6
		),
		DemoTicketSeed(
			externalID: "BUR-106",
			title: "Add Swift Testing coverage for SessionStore",
			body: "Add focused Swift Testing coverage for session refresh, logout, and persisted account readiness.",
			labels: ["tests", "swift-testing"],
			priority: .high,
			complexity: 7
		),
		DemoTicketSeed(
			externalID: "BUR-107",
			title: "Investigate slow image loading",
			body: "Image loading regressed in dense timeline cells after the cache key migration.",
			labels: ["performance", "images"],
			priority: .high,
			complexity: 8
		),
		DemoTicketSeed(
			externalID: "BUR-108",
			title: "Add app icon picker polish",
			body: "Icon picker rows should show clearer selected state, keyboard focus, and preview labels.",
			labels: ["polish", "settings"],
			priority: .low,
			complexity: 3
		),
		DemoTicketSeed(
			externalID: "BUR-109",
			title: "Fix keyboard navigation on macOS",
			body: "Sidebar and timeline keyboard navigation should preserve selection when switching panes.",
			labels: ["macos", "keyboard"],
			priority: .medium,
			complexity: 5
		),
		DemoTicketSeed(
			externalID: "BUR-110",
			title: "Generate accessibility labels for timeline cells",
			body: "Timeline cells need generated labels that describe author, timestamp, reply count, and attachment state.",
			labels: ["accessibility", "timeline"],
			priority: .high,
			complexity: 6
		)
	]
}
