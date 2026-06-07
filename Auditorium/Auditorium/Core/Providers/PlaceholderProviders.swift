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

	func listRepositories() async throws -> [RepositoryDescriptor] { throw ProviderError.notImplemented("GitHub Repository Provider") }
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws { throw ProviderError.notImplemented("GitHub Repository Provider") }
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor { throw ProviderError.notImplemented("GitHub Repository Provider") }
}

struct GitLabRepositoryProvider: SourceCodeProvider {
	let kind = RepositoryProviderKind.gitlab

	func listRepositories() async throws -> [RepositoryDescriptor] { throw ProviderError.notImplemented("GitLab Repository Provider") }
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws { throw ProviderError.notImplemented("GitLab Repository Provider") }
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor { throw ProviderError.notImplemented("GitLab Repository Provider") }
}

struct BitbucketRepositoryProvider: SourceCodeProvider {
	let kind = RepositoryProviderKind.bitbucket

	func listRepositories() async throws -> [RepositoryDescriptor] { throw ProviderError.notImplemented("Bitbucket Repository Provider") }
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws { throw ProviderError.notImplemented("Bitbucket Repository Provider") }
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor { throw ProviderError.notImplemented("Bitbucket Repository Provider") }
}

struct AzureDevOpsRepositoryProvider: SourceCodeProvider {
	let kind = RepositoryProviderKind.azureDevOps

	func listRepositories() async throws -> [RepositoryDescriptor] { throw ProviderError.notImplemented("Azure DevOps Repository Provider") }
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws { throw ProviderError.notImplemented("Azure DevOps Repository Provider") }
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor { throw ProviderError.notImplemented("Azure DevOps Repository Provider") }
}

struct GenericGitRepositoryProvider: SourceCodeProvider {
	let kind = RepositoryProviderKind.genericGit

	func listRepositories() async throws -> [RepositoryDescriptor] { throw ProviderError.notImplemented("Generic Git Repository Provider") }
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws { throw ProviderError.notImplemented("Generic Git Repository Provider") }
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor { throw ProviderError.notImplemented("Generic Git Repository Provider") }
}

final class GitHubIssueTrackerProvider: IssueTrackerProvider {
	let kind = IssueProviderKind.githubIssues
	let authentication = ProviderAuthenticationDescriptor(method: .oauth, displayName: "GitHub OAuth", oauth: GitHubOAuth.descriptor)

	func listTickets(projectID: String) async throws -> [TicketDescriptor] { throw ProviderError.notImplemented("GitHub Issue Tracker Provider") }
	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws { throw ProviderError.notImplemented("GitHub Issue Tracker Provider") }
	func addComment(ticketID: String, body: String) async throws { throw ProviderError.notImplemented("GitHub Issue Tracker Provider") }
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
	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws { throw ProviderError.notImplemented("Azure Boards Issue Provider") }
	func addComment(ticketID: String, body: String) async throws { throw ProviderError.notImplemented("Azure Boards Issue Provider") }
}

typealias AzureBoardsIssueProvider = AzureBoardsIssueTrackerProvider

struct CodexAgentProvider: AgentProvider {
	func runAgent(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> { throw ProviderError.notImplemented("Codex Agent Provider") }
}

struct GenericShellAgentProvider: AgentProvider {
	func runAgent(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> { throw ProviderError.notImplemented("Generic Shell Agent Provider") }
}

struct AppleContainerRuntimeProvider: RuntimeProvider {
	func prepareWorkspace(for ticket: TicketDescriptor, repository: RepositoryDescriptor) async throws -> WorkspaceDescriptor { throw ProviderError.notImplemented("Apple Container Runtime Provider") }
	func startExecution(_ request: RuntimeExecutionRequest) async throws -> RuntimeExecutionHandle { throw ProviderError.notImplemented("Apple Container Runtime Provider") }
	func stopExecution(handle: RuntimeExecutionHandle) async throws { throw ProviderError.notImplemented("Apple Container Runtime Provider") }
}

struct DockerRuntimeProvider: RuntimeProvider {
	func prepareWorkspace(for ticket: TicketDescriptor, repository: RepositoryDescriptor) async throws -> WorkspaceDescriptor { throw ProviderError.notImplemented("Docker Runtime Provider") }
	func startExecution(_ request: RuntimeExecutionRequest) async throws -> RuntimeExecutionHandle { throw ProviderError.notImplemented("Docker Runtime Provider") }
	func stopExecution(handle: RuntimeExecutionHandle) async throws { throw ProviderError.notImplemented("Docker Runtime Provider") }
}

struct LocalProcessRuntimeProvider: RuntimeProvider {
	func prepareWorkspace(for ticket: TicketDescriptor, repository: RepositoryDescriptor) async throws -> WorkspaceDescriptor { throw ProviderError.notImplemented("Local Process Runtime Provider") }
	func startExecution(_ request: RuntimeExecutionRequest) async throws -> RuntimeExecutionHandle { throw ProviderError.notImplemented("Local Process Runtime Provider") }
	func stopExecution(handle: RuntimeExecutionHandle) async throws { throw ProviderError.notImplemented("Local Process Runtime Provider") }
}
