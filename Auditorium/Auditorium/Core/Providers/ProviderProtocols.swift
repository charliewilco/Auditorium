import Foundation

enum ProviderError: LocalizedError {
	case notImplemented(String)
	case unavailable(String)

	var errorDescription: String? {
		switch self {
		case .notImplemented(let provider): "\(provider) is not implemented yet."
		case .unavailable(let detail): detail
		}
	}
}

protocol SourceCodeProvider {
	var kind: RepositoryProviderKind { get }
	var authentication: ProviderAuthenticationDescriptor { get }

	func listRepositories() async throws -> [RepositoryDescriptor]
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor
}

protocol IssueTrackerProvider {
	var kind: IssueProviderKind { get }
	var authentication: ProviderAuthenticationDescriptor { get }

	func listTickets(projectID: String) async throws -> [TicketDescriptor]
	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws
	func addComment(ticketID: String, body: String) async throws
}

typealias RepositoryProvider = SourceCodeProvider
typealias IssueProvider = IssueTrackerProvider

protocol RuntimeProvider {
	func prepareWorkspace(for ticket: TicketDescriptor, repository: RepositoryDescriptor) async throws -> WorkspaceDescriptor
	func startExecution(_ request: RuntimeExecutionRequest) async throws -> RuntimeExecutionHandle
	func stopExecution(handle: RuntimeExecutionHandle) async throws
}

protocol AgentProvider {
	func runAgent(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error>
}
