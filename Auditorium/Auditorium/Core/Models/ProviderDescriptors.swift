import Foundation

struct RepositoryDescriptor: Identifiable, Hashable, Sendable {
	var id: String { fullName }
	let provider: RepositoryProviderKind
	let owner: String
	let name: String
	let fullName: String
	let cloneURL: URL
	let webURL: URL
	let defaultBranch: String
}

struct TicketDescriptor: Identifiable, Hashable, Sendable {
	var id: String { externalID }
	let provider: IssueProviderKind
	let externalID: String
	let title: String
	let body: String
	let status: TicketStatus
	let labels: [String]
	let assignee: String?
	let priority: PriorityLevel
	let webURL: URL?
	let createdAt: Date
	let updatedAt: Date
	let estimatedComplexity: Int
	let blockedBy: [String]
}

struct PullRequestRequest: Sendable {
	let title: String
	let body: String
	let branchName: String
	let targetBranch: String
	let repository: RepositoryDescriptor
}

struct PullRequestDescriptor: Sendable {
	let title: String
	let url: URL
	let branchName: String
	let targetBranch: String
	let status: PullRequestStatus
	let checksStatus: ChecksStatus
}

struct WorkspaceDescriptor: Sendable {
	let path: URL
	let containerID: String
	let branchName: String
}

struct RuntimeExecutionRequest: Sendable {
	let ticket: TicketDescriptor
	let workspace: WorkspaceDescriptor
	let policyMarkdown: String
}

struct RuntimeExecutionHandle: Sendable {
	let id: String
	let workspacePath: URL
}

struct AgentRunRequest: Sendable {
	let ticket: TicketDescriptor
	let repository: RepositoryDescriptor
	let workspace: WorkspaceDescriptor
	let policyMarkdown: String
}

struct AgentEvent: Sendable {
	let level: EventLevel
	let category: EventCategory
	let message: String
	let summary: String?
	let outcome: MockTicketOutcome?
}

enum MockTicketOutcome: String, Sendable {
	case completed
	case failed
	case blocked
}

struct RuntimeHealthCheck: Identifiable, Sendable {
	let id: String
	let name: String
	let state: RuntimeHealthState
	let detail: String
	let version: String?
}
