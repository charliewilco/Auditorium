import Foundation
import SwiftData

enum ProviderImplementationState: String, Sendable {
	case detected
	case authenticated
	case authorized
	case implemented
	case unavailable
}

enum ProviderCredentialError: LocalizedError, Equatable {
	case missingGitHubCredentials(String)
	case expiredGitHubCredentials(String)

	var errorDescription: String? {
		switch self {
		case .missingGitHubCredentials(let operation):
			"GitHub credentials are required before \(operation). Connect GitHub in Settings or project setup."
		case .expiredGitHubCredentials(let operation):
			"GitHub credentials expired before \(operation), and Auditorium could not refresh them. Reconnect GitHub in Settings or project setup."
		}
	}
}

struct ProviderCapability: Sendable, Identifiable {
	let id: String
	let title: String
	let isSupported: Bool
}

@MainActor
struct ProviderRegistry {
	let keychainService: KeychainService
	let githubOAuthService: GitHubOAuthDeviceFlowService
	let refreshSkew: TimeInterval
	let now: @Sendable () -> Date

	init(
		keychainService: KeychainService,
		githubOAuthService: GitHubOAuthDeviceFlowService = GitHubOAuthDeviceFlowService(),
		refreshSkew: TimeInterval = 60,
		now: @escaping @Sendable () -> Date = { Date() }
	) {
		self.keychainService = keychainService
		self.githubOAuthService = githubOAuthService
		self.refreshSkew = refreshSkew
		self.now = now
	}

	func sourceCodeProvider(for project: Project, context: ModelContext) async throws -> any SourceCodeProvider {
		switch project.repositoryProviderKind {
		case .github:
			return GitHubRepositoryProvider(
				token: try await requireGitHubToken(
					for: project,
					context: context,
					operation: "running GitHub source-code operations"
				)
			)
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

	func issueTrackerProvider(for project: Project, context: ModelContext) async throws -> any IssueTrackerProvider {
		switch project.issueProviderKind {
		case .githubIssues:
			let issueTracker = try context.fetch(FetchDescriptor<IssueTrackerRecord>())
				.first { $0.projectID == project.id && $0.provider == .githubIssues }
			return GitHubIssueTrackerProvider(
				repositoryFullName: project.repositoryName,
				issueFilter: GitHubIssueFilter(rawValue: issueTracker?.filterName),
				token: try await requireGitHubToken(for: project, context: context, operation: "importing GitHub issues")
			)
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

	func requireGitHubToken(for project: Project, context: ModelContext, operation: String) async throws -> String {
		guard
			let token = try await githubToken(for: project, context: context, operation: operation)?.trimmingCharacters(
				in: .whitespacesAndNewlines
			),
			token.isEmpty == false
		else {
			throw ProviderCredentialError.missingGitHubCredentials(operation)
		}
		return token
	}

	func githubToken(for project: Project, context: ModelContext, operation: String) async throws -> String? {
		let repositories = try context.fetch(FetchDescriptor<RepositoryRecord>())
		guard let repository = repositories.first(where: { $0.projectID == project.id }),
			let accountID = repository.providerAccountID
		else {
			return nil
		}
		let accounts = try context.fetch(FetchDescriptor<ProviderAccountRecord>())
		guard let account = accounts.first(where: { $0.id == accountID }) else {
			return nil
		}
		guard let token = try keychainService.readSecret(account: account.keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
			token.isEmpty == false
		else {
			return nil
		}
		if account.accessTokenRequiresRefresh(at: now(), skew: refreshSkew) {
			return try await refreshGitHubToken(for: account, context: context, operation: operation)
		}
		return token
	}

	func clearGitHubCredentials(context: ModelContext) throws {
		let accounts = try context.fetch(FetchDescriptor<ProviderAccountRecord>())
			.filter {
				$0.providerKindRaw == RepositoryProviderKind.github.rawValue
					|| $0.providerKindRaw == IssueProviderKind.githubIssues.rawValue
			}
		for account in accounts {
			try keychainService.deleteSecret(account: account.keychainAccount)
			if let refreshTokenKeychainAccount = account.refreshTokenKeychainAccount {
				try keychainService.deleteSecret(account: refreshTokenKeychainAccount)
			}
			context.delete(account)
		}
		try ModelIntegrityValidator.save(context: context)
	}

	func capabilities(for repositoryProviderKind: RepositoryProviderKind) -> [ProviderCapability] {
		switch repositoryProviderKind {
		case .github:
			return [
				ProviderCapability(id: "list-repositories", title: "List repositories", isSupported: true),
				ProviderCapability(id: "clone-update", title: "Clone or update repository", isSupported: true),
				ProviderCapability(id: "pull-request", title: "Open pull request", isSupported: true),
			]
		default:
			return [
				ProviderCapability(id: "placeholder", title: "Provider placeholder", isSupported: false)
			]
		}
	}

	private func refreshGitHubToken(for account: ProviderAccountRecord, context: ModelContext, operation: String) async throws -> String {
		let refreshDate = now()
		guard
			let refreshTokenKeychainAccount = account.refreshTokenKeychainAccount,
			account.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
			account.refreshTokenExpiresAt.map({ $0 > refreshDate }) ?? true,
			let refreshToken = try keychainService.readSecret(account: refreshTokenKeychainAccount)?.trimmingCharacters(
				in: .whitespacesAndNewlines
			),
			refreshToken.isEmpty == false
		else {
			throw ProviderCredentialError.expiredGitHubCredentials(operation)
		}

		let response = try await githubOAuthService.refreshToken(clientID: account.oauthClientID, refreshToken: refreshToken)
		let metadata = GitHubOAuthTokenMetadata(response: response, oauthClientID: account.oauthClientID, issuedAt: refreshDate)
		try keychainService.storeSecret(response.accessToken, account: account.keychainAccount)
		if let rotatedRefreshToken = metadata.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
			rotatedRefreshToken.isEmpty == false
		{
			try keychainService.storeSecret(rotatedRefreshToken, account: refreshTokenKeychainAccount)
			account.refreshTokenExpiresAt = metadata.refreshTokenExpiresAt
		}
		account.grantedScopesRaw = metadata.grantedScopesRaw.isEmpty ? account.grantedScopesRaw : metadata.grantedScopesRaw
		account.tokenType = metadata.tokenType
		account.accessTokenExpiresAt = metadata.accessTokenExpiresAt
		account.lastValidatedAt = refreshDate
		account.updatedAt = refreshDate
		try ModelIntegrityValidator.save(context: context)
		return response.accessToken
	}
}
