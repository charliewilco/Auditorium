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
	let allowsAutoMerge: Bool

	init(
		title: String,
		body: String,
		branchName: String,
		targetBranch: String,
		repository: RepositoryDescriptor,
		allowsAutoMerge: Bool = false
	) {
		self.title = title
		self.body = body
		self.branchName = branchName
		self.targetBranch = targetBranch
		self.repository = repository
		self.allowsAutoMerge = allowsAutoMerge
	}
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
	let runtimeID: String
	let branchName: String
}

struct RuntimeExecutionRequest: Sendable {
	let ticket: TicketDescriptor
	let workspace: WorkspaceDescriptor
	let policyMarkdown: String
	let environment: [String: String]

	init(
		ticket: TicketDescriptor,
		workspace: WorkspaceDescriptor,
		policyMarkdown: String,
		environment: [String: String] = [:]
	) {
		self.ticket = ticket
		self.workspace = workspace
		self.policyMarkdown = policyMarkdown
		self.environment = environment
	}
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
	let environment: [String: String]

	init(
		ticket: TicketDescriptor,
		repository: RepositoryDescriptor,
		workspace: WorkspaceDescriptor,
		policyMarkdown: String,
		environment: [String: String] = [:]
	) {
		self.ticket = ticket
		self.repository = repository
		self.workspace = workspace
		self.policyMarkdown = policyMarkdown
		self.environment = environment
	}
}

struct AgentEvent: Sendable {
	let level: EventLevel
	let category: EventCategory
	let message: String
	let summary: String?
	let outcome: AgentRunOutcome?
	let metadataJSON: String?
	let logPath: String?

	nonisolated init(
		level: EventLevel,
		category: EventCategory,
		message: String,
		summary: String? = nil,
		outcome: AgentRunOutcome? = nil,
		metadataJSON: String? = nil,
		logPath: String? = nil
	) {
		self.level = level
		self.category = category
		self.message = message
		self.summary = summary
		self.outcome = outcome
		self.metadataJSON = metadataJSON
		self.logPath = logPath
	}
}

enum AgentRunOutcome: String, Sendable {
	case completed
	case failed
	case blocked
}

typealias MockTicketOutcome = AgentRunOutcome

struct RuntimeHealthCheck: Identifiable, Sendable {
	let id: String
	let name: String
	let state: RuntimeHealthState
	let detail: String
	let version: String?
}

struct RuntimeProviderStatus: Identifiable, Sendable {
	let id: String
	let kind: RuntimeProviderKind
	let detection: RuntimeHealthCheck
	let implementationState: ProviderImplementationState
	let implementationDetail: String

	var isRunnable: Bool {
		detection.state == .available && implementationState == .implemented
	}
}
