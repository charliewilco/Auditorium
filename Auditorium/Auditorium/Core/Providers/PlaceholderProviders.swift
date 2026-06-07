import Foundation

extension SourceCodeProvider {
	var authentication: ProviderAuthenticationDescriptor {
		ProviderAuthenticationDescriptor(method: .token, displayName: "\(kind.title) Token", oauth: nil)
	}
}

extension IssueTrackerProvider {
	var authentication: ProviderAuthenticationDescriptor {
		ProviderAuthenticationDescriptor(method: .token, displayName: "\(kind.title) Token", oauth: nil)
	}
}

final class GitHubRepositoryProvider: SourceCodeProvider {
	let kind = RepositoryProviderKind.github
	let authentication = ProviderAuthenticationDescriptor(method: .oauth, displayName: "GitHub OAuth", oauth: GitHubOAuth.descriptor)
	private let client: GitHubAPIClient?

	init(token: String? = nil, client: GitHubAPIClient? = nil) {
		if let client {
			self.client = client
		}
		else if let token, token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
			self.client = GitHubAPIClient(token: token)
		}
		else {
			self.client = nil
		}
	}

	func listRepositories() async throws -> [RepositoryDescriptor] {
		try await requireClient().listRepositories()
	}

	func fetchRepository(fullName: String) async throws -> RepositoryDescriptor {
		try await requireClient().repository(fullName: fullName)
	}

	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws {
		if FileManager.default.fileExists(atPath: path.appending(path: ".git").path()) {
			_ = try await ProcessCommand.run(
				executable: "/usr/bin/git",
				arguments: ["fetch", "--all", "--prune"],
				workingDirectory: path
			)
			return
		}
		try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
		_ = try await ProcessCommand.run(executable: "/usr/bin/env", arguments: ["gh", "repo", "clone", repository.fullName, path.path()])
	}

	func ticketBranchName(for ticket: TicketDescriptor, prefix: String) -> String {
		GitBranchName.make(prefix: prefix, ticketExternalID: ticket.externalID, ticketTitle: ticket.title)
	}

	func createBranch(named branchName: String, in repositoryPath: URL) async throws {
		let existing = try await ProcessCommand.runStreaming(
			executable: "/usr/bin/git",
			arguments: ["rev-parse", "--verify", branchName],
			workingDirectory: repositoryPath,
			allowsNonZeroExit: true
		)
		let arguments = existing.exitCode == 0 ? ["checkout", branchName] : ["checkout", "-b", branchName]
		_ = try await ProcessCommand.run(executable: "/usr/bin/git", arguments: arguments, workingDirectory: repositoryPath)
	}

	func commitChanges(in repositoryPath: URL, message: String) async throws -> Bool {
		let status = try await ProcessCommand.run(
			executable: "/usr/bin/git",
			arguments: ["status", "--porcelain"],
			workingDirectory: repositoryPath
		)
		guard status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
			return false
		}
		_ = try await ProcessCommand.run(executable: "/usr/bin/git", arguments: ["add", "-A"], workingDirectory: repositoryPath)
		_ = try await ProcessCommand.run(
			executable: "/usr/bin/git",
			arguments: ["-c", "user.name=Auditorium", "-c", "user.email=auditorium@local.invalid", "commit", "-m", message],
			workingDirectory: repositoryPath
		)
		return true
	}

	func pushBranch(named branchName: String, from repositoryPath: URL) async throws {
		_ = try await ProcessCommand.run(
			executable: "/usr/bin/git",
			arguments: Self.pushArguments(branchName: branchName),
			workingDirectory: repositoryPath
		)
	}

	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor {
		try await requireClient().createPullRequest(request)
	}

	func fetchPullRequest(repositoryFullName: String, number: Int) async throws -> PullRequestDescriptor {
		try await requireClient().pullRequest(repositoryFullName: repositoryFullName, number: number)
	}

	nonisolated static func pushArguments(branchName: String) -> [String] {
		["push", "-u", "origin", branchName]
	}

	private func requireClient() throws -> GitHubAPIClient {
		guard let client else {
			throw ProviderError.unavailable("GitHub credentials are required.")
		}
		return client
	}
}

struct GitLabRepositoryProvider: SourceCodeProvider {
	let kind = RepositoryProviderKind.gitlab

	func listRepositories() async throws -> [RepositoryDescriptor] { throw ProviderError.notImplemented("GitLab Repository Provider") }
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws {
		throw ProviderError.notImplemented("GitLab Repository Provider")
	}
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor {
		throw ProviderError.notImplemented("GitLab Repository Provider")
	}
}

struct BitbucketRepositoryProvider: SourceCodeProvider {
	let kind = RepositoryProviderKind.bitbucket

	func listRepositories() async throws -> [RepositoryDescriptor] { throw ProviderError.notImplemented("Bitbucket Repository Provider") }
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws {
		throw ProviderError.notImplemented("Bitbucket Repository Provider")
	}
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor {
		throw ProviderError.notImplemented("Bitbucket Repository Provider")
	}
}

struct AzureDevOpsRepositoryProvider: SourceCodeProvider {
	let kind = RepositoryProviderKind.azureDevOps

	func listRepositories() async throws -> [RepositoryDescriptor] { throw ProviderError.notImplemented("Azure DevOps Repository Provider") }
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws {
		throw ProviderError.notImplemented("Azure DevOps Repository Provider")
	}
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor {
		throw ProviderError.notImplemented("Azure DevOps Repository Provider")
	}
}

struct GenericGitRepositoryProvider: SourceCodeProvider {
	let kind = RepositoryProviderKind.genericGit

	func listRepositories() async throws -> [RepositoryDescriptor] { throw ProviderError.notImplemented("Generic Git Repository Provider") }
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws {
		throw ProviderError.notImplemented("Generic Git Repository Provider")
	}
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor {
		throw ProviderError.notImplemented("Generic Git Repository Provider")
	}
}

final class GitHubIssueTrackerProvider: IssueTrackerProvider {
	let kind = IssueProviderKind.githubIssues
	let authentication = ProviderAuthenticationDescriptor(method: .oauth, displayName: "GitHub OAuth", oauth: GitHubOAuth.descriptor)
	private let repositoryFullName: String?
	private let issueFilter: GitHubIssueFilter
	private let client: GitHubAPIClient?

	init(
		repositoryFullName: String? = nil,
		issueFilter: GitHubIssueFilter = GitHubIssueFilter(),
		token: String? = nil,
		client: GitHubAPIClient? = nil
	) {
		self.repositoryFullName = repositoryFullName
		self.issueFilter = issueFilter
		if let client {
			self.client = client
		}
		else if let token, token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
			self.client = GitHubAPIClient(token: token)
		}
		else {
			self.client = nil
		}
	}

	func listTickets(projectID: String) async throws -> [TicketDescriptor] {
		try await requireClient().listIssues(repositoryFullName: resolvedRepository(projectID: projectID), filter: issueFilter)
	}

	func fetchTicket(projectID: String, ticketID: String) async throws -> TicketDescriptor {
		try await requireClient().issue(repositoryFullName: resolvedRepository(projectID: projectID), issueNumber: ticketID)
	}

	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws {
		if status == .completed || status == .canceled {
			throw ProviderError.unavailable("Auditorium v0 does not automatically close GitHub issues.")
		}
	}

	func addComment(ticketID: String, body: String) async throws {
		let issue = try resolvedIssue(ticketID: ticketID)
		try await requireClient().addComment(repositoryFullName: issue.repository, issueNumber: issue.number, body: body)
	}

	func addLabels(ticketID: String, labels: [String]) async throws {
		let issue = try resolvedIssue(ticketID: ticketID)
		try await requireClient().addLabels(repositoryFullName: issue.repository, issueNumber: issue.number, labels: labels)
	}

	private func resolvedIssue(ticketID: String) throws -> (repository: String, number: String) {
		let parts = ticketID.split(separator: "#")
		let repository = parts.count == 2 ? String(parts[0]) : repositoryFullName
		let issueNumber = parts.count == 2 ? String(parts[1]) : ticketID
		guard let repository else {
			throw ProviderError.unavailable("A GitHub repository is required for issue \(ticketID).")
		}
		return (repository, issueNumber)
	}

	private func resolvedRepository(projectID: String) throws -> String {
		if let repositoryFullName {
			return repositoryFullName
		}
		guard projectID.contains("/") else {
			throw ProviderError.unavailable("GitHub Issues provider needs an OWNER/NAME repository identifier.")
		}
		return projectID
	}

	private func requireClient() throws -> GitHubAPIClient {
		guard let client else {
			throw ProviderError.unavailable("GitHub credentials are required.")
		}
		return client
	}
}

typealias GitHubIssueProvider = GitHubIssueTrackerProvider

struct LinearIssueTrackerProvider: IssueTrackerProvider {
	let kind = IssueProviderKind.linear

	func listTickets(projectID: String) async throws -> [TicketDescriptor] { throw ProviderError.notImplemented("Linear Issue Provider") }
	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws { throw ProviderError.notImplemented("Linear Issue Provider") }
	func addComment(ticketID: String, body: String) async throws { throw ProviderError.notImplemented("Linear Issue Provider") }
}

typealias LinearIssueProvider = LinearIssueTrackerProvider

struct AsanaIssueTrackerProvider: IssueTrackerProvider {
	let kind = IssueProviderKind.asana

	func listTickets(projectID: String) async throws -> [TicketDescriptor] { throw ProviderError.notImplemented("Asana Issue Provider") }
	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws { throw ProviderError.notImplemented("Asana Issue Provider") }
	func addComment(ticketID: String, body: String) async throws { throw ProviderError.notImplemented("Asana Issue Provider") }
}

typealias AsanaIssueProvider = AsanaIssueTrackerProvider

struct GitLabIssueTrackerProvider: IssueTrackerProvider {
	let kind = IssueProviderKind.gitlabIssues

	func listTickets(projectID: String) async throws -> [TicketDescriptor] { throw ProviderError.notImplemented("GitLab Issue Provider") }
	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws { throw ProviderError.notImplemented("GitLab Issue Provider") }
	func addComment(ticketID: String, body: String) async throws { throw ProviderError.notImplemented("GitLab Issue Provider") }
}

typealias GitLabIssueProvider = GitLabIssueTrackerProvider

struct AzureBoardsIssueTrackerProvider: IssueTrackerProvider {
	let kind = IssueProviderKind.azureBoards

	func listTickets(projectID: String) async throws -> [TicketDescriptor] { throw ProviderError.notImplemented("Azure Boards Issue Provider") }
	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws {
		throw ProviderError.notImplemented("Azure Boards Issue Provider")
	}
	func addComment(ticketID: String, body: String) async throws { throw ProviderError.notImplemented("Azure Boards Issue Provider") }
}

typealias AzureBoardsIssueProvider = AzureBoardsIssueTrackerProvider

struct AppleContainerRuntimeProvider: RuntimeProvider {
	func prepareWorkspace(for ticket: TicketDescriptor, repository: RepositoryDescriptor) async throws -> WorkspaceDescriptor {
		throw ProviderError.notImplemented("Apple Container Runtime Provider")
	}
	func startExecution(_ request: RuntimeExecutionRequest) async throws -> RuntimeExecutionHandle {
		throw ProviderError.notImplemented("Apple Container Runtime Provider")
	}
	func stopExecution(handle: RuntimeExecutionHandle) async throws { throw ProviderError.notImplemented("Apple Container Runtime Provider") }
}
