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
	func fetchRepository(fullName: String) async throws -> RepositoryDescriptor
	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws
	func ticketBranchName(for ticket: TicketDescriptor, prefix: String) -> String
	func createBranch(named branchName: String, in repositoryPath: URL) async throws
	func commitChanges(in repositoryPath: URL, message: String) async throws -> Bool
	func pushBranch(named branchName: String, from repositoryPath: URL) async throws
	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor
	func fetchPullRequest(repositoryFullName: String, number: Int) async throws -> PullRequestDescriptor
}

extension SourceCodeProvider {
	func fetchRepository(fullName: String) async throws -> RepositoryDescriptor {
		throw ProviderError.notImplemented("\(kind.title) repository metadata")
	}

	func ticketBranchName(for ticket: TicketDescriptor, prefix: String) -> String {
		GitBranchName.make(prefix: prefix, ticketExternalID: ticket.externalID, ticketTitle: ticket.title)
	}

	func createBranch(named branchName: String, in repositoryPath: URL) async throws {
		throw ProviderError.notImplemented("\(kind.title) branch creation")
	}

	func commitChanges(in repositoryPath: URL, message: String) async throws -> Bool {
		throw ProviderError.notImplemented("\(kind.title) commits")
	}

	func pushBranch(named branchName: String, from repositoryPath: URL) async throws {
		throw ProviderError.notImplemented("\(kind.title) branch push")
	}

	func fetchPullRequest(repositoryFullName: String, number: Int) async throws -> PullRequestDescriptor {
		throw ProviderError.notImplemented("\(kind.title) pull request status")
	}
}

struct TicketHandoffRequest: Equatable, Sendable {
	let ticketID: String
	let body: String
	let labels: [String]
}

struct TicketHandoffReceipt: Equatable, Sendable {
	let commentURL: URL?
}

protocol TicketProvider {
	var kind: IssueProviderKind { get }
	var authentication: ProviderAuthenticationDescriptor { get }

	func listTickets(projectID: String) async throws -> [TicketDescriptor]
	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws
}

protocol HandoffProvider {
	var kind: IssueProviderKind { get }
	var authentication: ProviderAuthenticationDescriptor { get }

	@discardableResult
	func publishHandoff(_ request: TicketHandoffRequest) async throws -> TicketHandoffReceipt
}

protocol IssueTrackerProvider: TicketProvider, HandoffProvider {
	@discardableResult
	func addComment(ticketID: String, body: String) async throws -> URL?
	func addLabels(ticketID: String, labels: [String]) async throws
}

extension IssueTrackerProvider {
	@discardableResult
	func publishHandoff(_ request: TicketHandoffRequest) async throws -> TicketHandoffReceipt {
		let commentURL = try await addComment(ticketID: request.ticketID, body: request.body)
		if request.labels.isEmpty == false {
			try await addLabels(ticketID: request.ticketID, labels: request.labels)
		}
		return TicketHandoffReceipt(commentURL: commentURL)
	}

	func addLabels(ticketID: String, labels: [String]) async throws {
		if labels.isEmpty == false {
			throw ProviderError.notImplemented("\(kind.title) label updates")
		}
	}

	func applyWorkflowHandoffLabel(ticketID: String, policy: ParsedWorkflowPolicy) async throws {
		guard policy.updateIssueLabels,
			let handoffStatus = policy.handoffStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
			handoffStatus.isEmpty == false
		else {
			return
		}
		try await addLabels(ticketID: ticketID, labels: [handoffStatus])
	}
}

typealias RepositoryProvider = SourceCodeProvider
typealias IssueProvider = IssueTrackerProvider
typealias TicketHandoffProvider = HandoffProvider

protocol RuntimeProvider {
	func prepareWorkspace(for ticket: TicketDescriptor, repository: RepositoryDescriptor) async throws -> WorkspaceDescriptor
	func startExecution(_ request: RuntimeExecutionRequest) async throws -> RuntimeExecutionHandle
	func stopExecution(handle: RuntimeExecutionHandle) async throws
}

protocol AgentProvider {
	func runAgent(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error>
}
