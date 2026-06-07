import Foundation
import SwiftData

@MainActor
struct DemoDataSeeder {
	let workspaceService: ApplicationWorkspaceService

	func openDemoProject(in context: ModelContext) throws -> UUID {
		let projects = try context.fetch(FetchDescriptor<Project>())
		if let existing = projects.first(where: { $0.name == "Burton Demo" }) {
			return existing.id
		}

		let project = Project(
			name: "Burton Demo",
			repositoryProviderKind: .github,
			repositoryName: "charlie/burton-ios",
			repositoryURL: "https://github.com/charlie/burton-ios",
			defaultBranch: "next",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
		context.insert(project)

		let repository = RepositoryRecord(
			provider: .github,
			owner: "charlie",
			name: "burton-ios",
			fullName: "charlie/burton-ios",
			cloneURL: "https://github.com/charlie/burton-ios.git",
			webURL: "https://github.com/charlie/burton-ios",
			defaultBranch: "next",
			localPath: workspaceService.repositoryDirectory(projectID: project.id).path(),
			projectID: project.id
		)
		context.insert(repository)
		context.insert(IssueTrackerRecord(
			provider: .githubIssues,
			displayName: "charlie/burton-ios",
			sourceIdentifier: "charlie/burton-ios",
			filterName: "Ready for agent",
			webURL: "https://github.com/charlie/burton-ios/issues",
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
