import Foundation
import SwiftData

enum ProviderImplementationState: String, Sendable {
	case detected
	case authenticated
	case authorized
	case implemented
	case unavailable
}

struct ProviderCapability: Sendable, Identifiable {
	let id: String
	let title: String
	let isSupported: Bool
}

@MainActor
struct ProviderRegistry {
	let keychainService: KeychainService

	func sourceCodeProvider(for project: Project, context: ModelContext) throws -> any SourceCodeProvider {
		switch project.repositoryProviderKind {
		case .github:
			return GitHubRepositoryProvider(token: try githubToken(for: project, context: context))
		case .gitlab:
			return GitLabRepositoryProvider()
		case .bitbucket:
			return BitbucketRepositoryProvider()
		case .azureDevOps:
			return AzureDevOpsRepositoryProvider()
		case .genericGit:
			return GenericGitRepositoryProvider()
		}
	}

	func issueTrackerProvider(for project: Project, context: ModelContext) throws -> any IssueTrackerProvider {
		switch project.issueProviderKind {
		case .githubIssues:
			let issueTracker = try context.fetch(FetchDescriptor<IssueTrackerRecord>())
				.first { $0.projectID == project.id && $0.provider == .githubIssues }
			return GitHubIssueTrackerProvider(repositoryFullName: project.repositoryName, issueFilter: GitHubIssueFilter(rawValue: issueTracker?.filterName), token: try githubToken(for: project, context: context))
		case .linear:
			return LinearIssueTrackerProvider()
		case .asana:
			return AsanaIssueTrackerProvider()
		case .gitlabIssues:
			return GitLabIssueTrackerProvider()
		case .azureBoards:
			return AzureBoardsIssueTrackerProvider()
		case .imported:
			return MockGitHubIssueTrackerProvider()
		}
	}

	func githubToken(for project: Project, context: ModelContext) throws -> String? {
		let repositories = try context.fetch(FetchDescriptor<RepositoryRecord>())
		guard let repository = repositories.first(where: { $0.projectID == project.id }),
			  let accountID = repository.providerAccountID else {
			return nil
		}
		let accounts = try context.fetch(FetchDescriptor<ProviderAccountRecord>())
		guard let account = accounts.first(where: { $0.id == accountID }) else {
			return nil
		}
		return try keychainService.readSecret(account: account.keychainAccount)
	}

	func clearGitHubCredentials(context: ModelContext) throws {
		let accounts = try context.fetch(FetchDescriptor<ProviderAccountRecord>())
			.filter { $0.providerKindRaw == RepositoryProviderKind.github.rawValue || $0.providerKindRaw == IssueProviderKind.githubIssues.rawValue }
		for account in accounts {
			try keychainService.deleteSecret(account: account.keychainAccount)
			context.delete(account)
		}
		try context.save()
	}

	func capabilities(for repositoryProviderKind: RepositoryProviderKind) -> [ProviderCapability] {
		switch repositoryProviderKind {
		case .github:
			return [
				ProviderCapability(id: "list-repositories", title: "List repositories", isSupported: true),
				ProviderCapability(id: "clone-update", title: "Clone or update repository", isSupported: true),
				ProviderCapability(id: "pull-request", title: "Open pull request", isSupported: true)
			]
		default:
			return [
				ProviderCapability(id: "placeholder", title: "Provider placeholder", isSupported: false)
			]
		}
	}
}
