import Foundation
import SwiftData

@Model
final class Project {
	var id: UUID
	var name: String
	var repositoryProviderKindRaw: String
	var repositoryName: String
	var repositoryURL: String
	var defaultBranch: String
	var issueProviderKindRaw: String
	var runtimeProviderKindRaw: String
	var agentProviderKindRaw: String
	var workflowPolicyMarkdown: String
	var createdAt: Date
	var updatedAt: Date

	init(
		id: UUID = UUID(),
		name: String,
		repositoryProviderKind: RepositoryProviderKind,
		repositoryName: String,
		repositoryURL: String,
		defaultBranch: String,
		issueProviderKind: IssueProviderKind,
		runtimeProviderKind: RuntimeProviderKind,
		agentProviderKind: AgentProviderKind,
		workflowPolicyMarkdown: String = WorkflowPolicy.defaultMarkdown,
		createdAt: Date = .now,
		updatedAt: Date = .now
	) {
		self.id = id
		self.name = name
		self.repositoryProviderKindRaw = repositoryProviderKind.rawValue
		self.repositoryName = repositoryName
		self.repositoryURL = repositoryURL
		self.defaultBranch = defaultBranch
		self.issueProviderKindRaw = issueProviderKind.rawValue
		self.runtimeProviderKindRaw = runtimeProviderKind.rawValue
		self.agentProviderKindRaw = agentProviderKind.rawValue
		self.workflowPolicyMarkdown = workflowPolicyMarkdown
		self.createdAt = createdAt
		self.updatedAt = updatedAt
	}

	var repositoryProviderKind: RepositoryProviderKind {
		get { RepositoryProviderKind(rawValue: repositoryProviderKindRaw) ?? .github }
		set { repositoryProviderKindRaw = newValue.rawValue }
	}

	var issueProviderKind: IssueProviderKind {
		get { IssueProviderKind(rawValue: issueProviderKindRaw) ?? .githubIssues }
		set { issueProviderKindRaw = newValue.rawValue }
	}

	var runtimeProviderKind: RuntimeProviderKind {
		get { RuntimeProviderKind(rawValue: runtimeProviderKindRaw) ?? .mockRuntime }
		set { runtimeProviderKindRaw = newValue.rawValue }
	}

	var agentProviderKind: AgentProviderKind {
		get { AgentProviderKind(rawValue: agentProviderKindRaw) ?? .mockAgent }
		set { agentProviderKindRaw = newValue.rawValue }
	}
}

@Model
final class RepositoryRecord {
	var id: UUID
	var providerRaw: String
	var owner: String
	var name: String
	var fullName: String
	var cloneURL: String
	var webURL: String
	var defaultBranch: String
	var localPath: String
	var lastSyncedAt: Date?
	var providerAccountID: UUID?
	var projectID: UUID

	init(
		id: UUID = UUID(),
		provider: RepositoryProviderKind,
		owner: String,
		name: String,
		fullName: String,
		cloneURL: String,
		webURL: String,
		defaultBranch: String,
		localPath: String = "",
		lastSyncedAt: Date? = nil,
		providerAccountID: UUID? = nil,
		projectID: UUID
	) {
		self.id = id
		self.providerRaw = provider.rawValue
		self.owner = owner
		self.name = name
		self.fullName = fullName
		self.cloneURL = cloneURL
		self.webURL = webURL
		self.defaultBranch = defaultBranch
		self.localPath = localPath
		self.lastSyncedAt = lastSyncedAt
		self.providerAccountID = providerAccountID
		self.projectID = projectID
	}

	var provider: RepositoryProviderKind {
		get { RepositoryProviderKind(rawValue: providerRaw) ?? .github }
		set { providerRaw = newValue.rawValue }
	}
}

@Model
final class IssueTrackerRecord {
	var id: UUID
	var providerRaw: String
	var displayName: String
	var sourceIdentifier: String
	var filterName: String
	var webURL: String
	var projectID: UUID
	var providerAccountID: UUID?
	var createdAt: Date
	var updatedAt: Date

	init(
		id: UUID = UUID(),
		provider: IssueProviderKind,
		displayName: String,
		sourceIdentifier: String,
		filterName: String,
		webURL: String,
		projectID: UUID,
		providerAccountID: UUID? = nil,
		createdAt: Date = .now,
		updatedAt: Date = .now
	) {
		self.id = id
		self.providerRaw = provider.rawValue
		self.displayName = displayName
		self.sourceIdentifier = sourceIdentifier
		self.filterName = filterName
		self.webURL = webURL
		self.projectID = projectID
		self.providerAccountID = providerAccountID
		self.createdAt = createdAt
		self.updatedAt = updatedAt
	}

	var provider: IssueProviderKind {
		get { IssueProviderKind(rawValue: providerRaw) ?? .githubIssues }
		set { providerRaw = newValue.rawValue }
	}
}

@Model
final class TicketRecord {
	var id: UUID
	var providerRaw: String
	var externalID: String
	var title: String
	var body: String
	var statusRaw: String
	var labels: [String]
	var assignee: String?
	var priorityRaw: String
	var webURL: String
	var createdAt: Date
	var updatedAt: Date
	var estimatedComplexity: Int
	var blockedBy: [String]
	var sourceProjectID: UUID

	init(
		id: UUID = UUID(),
		provider: IssueProviderKind,
		externalID: String,
		title: String,
		body: String,
		status: TicketStatus,
		labels: [String],
		assignee: String?,
		priority: PriorityLevel,
		webURL: String,
		createdAt: Date,
		updatedAt: Date,
		estimatedComplexity: Int,
		blockedBy: [String] = [],
		sourceProjectID: UUID
	) {
		self.id = id
		self.providerRaw = provider.rawValue
		self.externalID = externalID
		self.title = title
		self.body = body
		self.statusRaw = status.rawValue
		self.labels = labels
		self.assignee = assignee
		self.priorityRaw = priority.rawValue
		self.webURL = webURL
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.estimatedComplexity = estimatedComplexity
		self.blockedBy = blockedBy
		self.sourceProjectID = sourceProjectID
	}

	var provider: IssueProviderKind {
		get { IssueProviderKind(rawValue: providerRaw) ?? .githubIssues }
		set { providerRaw = newValue.rawValue }
	}

	var status: TicketStatus {
		get { TicketStatus(rawValue: statusRaw) ?? .backlog }
		set { statusRaw = newValue.rawValue }
	}

	var priority: PriorityLevel {
		get { PriorityLevel(rawValue: priorityRaw) ?? .medium }
		set { priorityRaw = newValue.rawValue }
	}
}

@Model
final class QueueItemRecord {
	var id: UUID
	var ticketID: UUID
	var projectID: UUID
	var position: Int
	var priorityRaw: String
	var isEnabled: Bool
	var concurrencyGroup: String
	var createdAt: Date

	init(
		id: UUID = UUID(),
		ticketID: UUID,
		projectID: UUID,
		position: Int,
		priority: PriorityLevel,
		isEnabled: Bool = true,
		concurrencyGroup: String = "default",
		createdAt: Date = .now
	) {
		self.id = id
		self.ticketID = ticketID
		self.projectID = projectID
		self.position = position
		self.priorityRaw = priority.rawValue
		self.isEnabled = isEnabled
		self.concurrencyGroup = concurrencyGroup
		self.createdAt = createdAt
	}

	var priority: PriorityLevel {
		get { PriorityLevel(rawValue: priorityRaw) ?? .medium }
		set { priorityRaw = newValue.rawValue }
	}
}

@Model
final class RunRecord {
	var id: UUID
	var projectID: UUID
	var startedAt: Date
	var endedAt: Date?
	var statusRaw: String
	var totalTickets: Int
	var completedTickets: Int
	var failedTickets: Int
	var blockedTickets: Int
	var pullRequestsCreated: Int
	var queueSnapshotJSON: String
	var workflowPolicySnapshotMarkdown: String
	var reportMarkdown: String
	var summary: String

	init(
		id: UUID = UUID(),
		projectID: UUID,
		startedAt: Date = .now,
		endedAt: Date? = nil,
		status: RunStatus = .pending,
		totalTickets: Int = 0,
		completedTickets: Int = 0,
		failedTickets: Int = 0,
		blockedTickets: Int = 0,
		pullRequestsCreated: Int = 0,
		queueSnapshotJSON: String = "[]",
		workflowPolicySnapshotMarkdown: String = WorkflowPolicy.defaultMarkdown,
		reportMarkdown: String = "",
		summary: String = ""
	) {
		self.id = id
		self.projectID = projectID
		self.startedAt = startedAt
		self.endedAt = endedAt
		self.statusRaw = status.rawValue
		self.totalTickets = totalTickets
		self.completedTickets = completedTickets
		self.failedTickets = failedTickets
		self.blockedTickets = blockedTickets
		self.pullRequestsCreated = pullRequestsCreated
		self.queueSnapshotJSON = queueSnapshotJSON
		self.workflowPolicySnapshotMarkdown = workflowPolicySnapshotMarkdown
		self.reportMarkdown = reportMarkdown
		self.summary = summary
	}

	var status: RunStatus {
		get { RunStatus(rawValue: statusRaw) ?? .pending }
		set { statusRaw = newValue.rawValue }
	}

	var queueSnapshot: [QueueRunSnapshot] {
		get {
			(try? JSONDecoder().decode([QueueRunSnapshot].self, from: Data(queueSnapshotJSON.utf8))) ?? []
		}
		set {
			queueSnapshotJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
		}
	}
}

@Model
final class TicketRunRecord {
	var id: UUID
	var runID: UUID
	var ticketID: UUID
	var workspacePath: String
	var runtimeID: String
	var branchName: String
	var statusRaw: String
	var lifecyclePhaseRaw: String
	var failedPhaseRaw: String?
	var startedAt: Date?
	var endedAt: Date?
	var retryCount: Int
	var logPath: String
	var pullRequestURL: String?
	var summary: String
	var failureReason: String?
	var confidence: Double

	init(
		id: UUID = UUID(),
		runID: UUID,
		ticketID: UUID,
		workspacePath: String = "",
		runtimeID: String = "",
		branchName: String = "",
		status: TicketRunStatus = .pending,
		lifecyclePhase: TicketRunLifecyclePhase = .queued,
		failedPhase: TicketRunLifecyclePhase? = nil,
		startedAt: Date? = nil,
		endedAt: Date? = nil,
		retryCount: Int = 0,
		logPath: String = "",
		pullRequestURL: String? = nil,
		summary: String = "",
		failureReason: String? = nil,
		confidence: Double = 0
	) {
		self.id = id
		self.runID = runID
		self.ticketID = ticketID
		self.workspacePath = workspacePath
		self.runtimeID = runtimeID
		self.branchName = branchName
		self.statusRaw = status.rawValue
		self.lifecyclePhaseRaw = lifecyclePhase.rawValue
		self.failedPhaseRaw = failedPhase?.rawValue
		self.startedAt = startedAt
		self.endedAt = endedAt
		self.retryCount = retryCount
		self.logPath = logPath
		self.pullRequestURL = pullRequestURL
		self.summary = summary
		self.failureReason = failureReason
		self.confidence = confidence
	}

	var status: TicketRunStatus {
		get { TicketRunStatus(rawValue: statusRaw) ?? .pending }
		set { statusRaw = newValue.rawValue }
	}

	var lifecyclePhase: TicketRunLifecyclePhase {
		get { TicketRunLifecyclePhase(rawValue: lifecyclePhaseRaw) ?? .queued }
		set { lifecyclePhaseRaw = newValue.rawValue }
	}

	var failedPhase: TicketRunLifecyclePhase? {
		get { failedPhaseRaw.flatMap(TicketRunLifecyclePhase.init(rawValue:)) }
		set { failedPhaseRaw = newValue?.rawValue }
	}
}

@Model
final class PullRequestRecord {
	var id: UUID
	var providerRaw: String
	var ticketRunID: UUID
	var title: String
	var url: String
	var branchName: String
	var targetBranch: String
	var statusRaw: String
	var checksStatusRaw: String
	var createdAt: Date
	var mergedAt: Date?

	init(
		id: UUID = UUID(),
		provider: RepositoryProviderKind,
		ticketRunID: UUID,
		title: String,
		url: String,
		branchName: String,
		targetBranch: String,
		status: PullRequestStatus,
		checksStatus: ChecksStatus,
		createdAt: Date = .now,
		mergedAt: Date? = nil
	) {
		self.id = id
		self.providerRaw = provider.rawValue
		self.ticketRunID = ticketRunID
		self.title = title
		self.url = url
		self.branchName = branchName
		self.targetBranch = targetBranch
		self.statusRaw = status.rawValue
		self.checksStatusRaw = checksStatus.rawValue
		self.createdAt = createdAt
		self.mergedAt = mergedAt
	}

	var provider: RepositoryProviderKind {
		get { RepositoryProviderKind(rawValue: providerRaw) ?? .github }
		set { providerRaw = newValue.rawValue }
	}

	var status: PullRequestStatus {
		get { PullRequestStatus(rawValue: statusRaw) ?? .open }
		set { statusRaw = newValue.rawValue }
	}

	var checksStatus: ChecksStatus {
		get { ChecksStatus(rawValue: checksStatusRaw) ?? .pending }
		set { checksStatusRaw = newValue.rawValue }
	}
}

@Model
final class RuntimeEventRecord {
	var id: UUID
	var runID: UUID
	var ticketRunID: UUID?
	var timestamp: Date
	var levelRaw: String
	var categoryRaw: String
	var message: String
	var metadataJSON: String

	init(
		id: UUID = UUID(),
		runID: UUID,
		ticketRunID: UUID? = nil,
		timestamp: Date = .now,
		level: EventLevel,
		category: EventCategory,
		message: String,
		metadataJSON: String = "{}"
	) {
		self.id = id
		self.runID = runID
		self.ticketRunID = ticketRunID
		self.timestamp = timestamp
		self.levelRaw = level.rawValue
		self.categoryRaw = category.rawValue
		self.message = message
		self.metadataJSON = metadataJSON
	}

	var level: EventLevel {
		get { EventLevel(rawValue: levelRaw) ?? .info }
		set { levelRaw = newValue.rawValue }
	}

	var category: EventCategory {
		get { EventCategory(rawValue: categoryRaw) ?? .orchestration }
		set { categoryRaw = newValue.rawValue }
	}
}

@Model
final class CoordinationMessageRecord {
	var id: UUID
	var runID: UUID
	var ticketRunID: UUID?
	var externalMessageID: String
	var sourceIssueNumber: Int
	var targetIssueNumber: Int?
	var kindRaw: String
	var summary: String
	var changedFilesJSON: String
	var labelsJSON: String
	var keywordsJSON: String
	var workspacePath: String
	var branchName: String
	var createdAt: Date

	init(
		id: UUID = UUID(),
		runID: UUID,
		ticketRunID: UUID? = nil,
		externalMessageID: String,
		sourceIssueNumber: Int,
		targetIssueNumber: Int? = nil,
		kind: String,
		summary: String,
		changedFiles: [String] = [],
		labels: [String] = [],
		keywords: [String] = [],
		workspacePath: String = "",
		branchName: String = "",
		createdAt: Date = .now
	) {
		self.id = id
		self.runID = runID
		self.ticketRunID = ticketRunID
		self.externalMessageID = externalMessageID
		self.sourceIssueNumber = sourceIssueNumber
		self.targetIssueNumber = targetIssueNumber
		self.kindRaw = kind
		self.summary = summary
		self.changedFilesJSON = Self.encodeList(changedFiles)
		self.labelsJSON = Self.encodeList(labels)
		self.keywordsJSON = Self.encodeList(keywords)
		self.workspacePath = workspacePath
		self.branchName = branchName
		self.createdAt = createdAt
	}

	var changedFiles: [String] {
		get { Self.decodeList(changedFilesJSON) }
		set { changedFilesJSON = Self.encodeList(newValue) }
	}

	var labels: [String] {
		get { Self.decodeList(labelsJSON) }
		set { labelsJSON = Self.encodeList(newValue) }
	}

	var keywords: [String] {
		get { Self.decodeList(keywordsJSON) }
		set { keywordsJSON = Self.encodeList(newValue) }
	}

	private static func encodeList(_ values: [String]) -> String {
		(try? String(data: JSONEncoder().encode(values), encoding: .utf8)) ?? "[]"
	}

	private static func decodeList(_ json: String) -> [String] {
		(try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
	}
}

@Model
final class ReportRecord {
	var id: UUID
	var projectID: UUID
	var runID: UUID
	var title: String
	var markdown: String
	var filePath: String
	var createdAt: Date

	init(
		id: UUID = UUID(),
		projectID: UUID,
		runID: UUID,
		title: String,
		markdown: String,
		filePath: String,
		createdAt: Date = .now
	) {
		self.id = id
		self.projectID = projectID
		self.runID = runID
		self.title = title
		self.markdown = markdown
		self.filePath = filePath
		self.createdAt = createdAt
	}
}

@Model
final class TicketReportBackRecord {
	var id: UUID
	var ticketRunID: UUID
	var providerRaw: String
	var externalTicketID: String
	var statusRaw: String
	var attemptCount: Int
	var attemptedAt: Date
	var retryAfter: Date?
	var inFlightStartedAt: Date?
	var commentURL: String?
	var failureReason: String?
	var updatedAt: Date

	init(
		id: UUID = UUID(),
		ticketRunID: UUID,
		provider: IssueProviderKind,
		externalTicketID: String,
		status: TicketReportBackStatus = .pending,
		attemptCount: Int = 0,
		attemptedAt: Date = .now,
		retryAfter: Date? = nil,
		inFlightStartedAt: Date? = nil,
		commentURL: String? = nil,
		failureReason: String? = nil,
		updatedAt: Date = .now
	) {
		self.id = id
		self.ticketRunID = ticketRunID
		self.providerRaw = provider.rawValue
		self.externalTicketID = externalTicketID
		self.statusRaw = status.rawValue
		self.attemptCount = attemptCount
		self.attemptedAt = attemptedAt
		self.retryAfter = retryAfter
		self.inFlightStartedAt = inFlightStartedAt
		self.commentURL = commentURL
		self.failureReason = failureReason
		self.updatedAt = updatedAt
	}

	var provider: IssueProviderKind {
		get { IssueProviderKind(rawValue: providerRaw) ?? .githubIssues }
		set { providerRaw = newValue.rawValue }
	}

	var status: TicketReportBackStatus {
		get { TicketReportBackStatus(rawValue: statusRaw) ?? .pending }
		set { statusRaw = newValue.rawValue }
	}
}

@Model
final class ProviderAccountRecord {
	var id: UUID
	var providerKindRaw: String
	var displayName: String
	var keychainAccount: String
	var oauthClientID: String
	var grantedScopesRaw: String
	var tokenType: String
	var accessTokenExpiresAt: Date?
	var refreshTokenKeychainAccount: String?
	var refreshTokenExpiresAt: Date?
	var lastValidatedAt: Date?
	var createdAt: Date
	var updatedAt: Date

	init(
		id: UUID = UUID(),
		providerKindRaw: String,
		displayName: String,
		keychainAccount: String,
		oauthClientID: String = "",
		grantedScopesRaw: String = "",
		tokenType: String = "",
		accessTokenExpiresAt: Date? = nil,
		refreshTokenKeychainAccount: String? = nil,
		refreshTokenExpiresAt: Date? = nil,
		lastValidatedAt: Date? = nil,
		createdAt: Date = .now,
		updatedAt: Date = .now
	) {
		self.id = id
		self.providerKindRaw = providerKindRaw
		self.displayName = displayName
		self.keychainAccount = keychainAccount
		self.oauthClientID = oauthClientID
		self.grantedScopesRaw = grantedScopesRaw
		self.tokenType = tokenType
		self.accessTokenExpiresAt = accessTokenExpiresAt
		self.refreshTokenKeychainAccount = refreshTokenKeychainAccount
		self.refreshTokenExpiresAt = refreshTokenExpiresAt
		self.lastValidatedAt = lastValidatedAt
		self.createdAt = createdAt
		self.updatedAt = updatedAt
	}

	var grantedScopes: Set<String> {
		Set(
			grantedScopesRaw
				.split { character in
					character == "," || character == " " || character == "\n"
				}
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { $0.isEmpty == false }
		)
	}

	func accessTokenRequiresRefresh(at date: Date, skew: TimeInterval = 60) -> Bool {
		guard let accessTokenExpiresAt else {
			return false
		}
		return accessTokenExpiresAt <= date.addingTimeInterval(skew)
	}
}

@Model
final class ProjectEnvironmentSecretRecord {
	var id: UUID
	var projectID: UUID
	var name: String
	var keychainAccount: String
	var isEnabled: Bool
	var createdAt: Date
	var updatedAt: Date

	init(
		id: UUID = UUID(),
		projectID: UUID,
		name: String,
		keychainAccount: String,
		isEnabled: Bool = true,
		createdAt: Date = .now,
		updatedAt: Date = .now
	) {
		self.id = id
		self.projectID = projectID
		self.name = name
		self.keychainAccount = keychainAccount
		self.isEnabled = isEnabled
		self.createdAt = createdAt
		self.updatedAt = updatedAt
	}
}

@Model
final class ContainerRunRecord {
	var id: UUID
	var projectID: UUID
	var runID: UUID
	var ticketRunID: UUID
	var runtimeID: String
	var containerName: String
	var statusRaw: String
	var imageName: String
	var environmentVariableNamesJSON: String
	var workspacePath: String
	var logPath: String
	var startedAt: Date
	var lastSeenAt: Date
	var endedAt: Date?
	var exitCode: Int?
	var cleanupEligibilityRaw: String
	var reconciliationStateRaw: String
	var failureReason: String?

	init(
		id: UUID = UUID(),
		projectID: UUID,
		runID: UUID,
		ticketRunID: UUID,
		runtimeID: String,
		containerName: String,
		status: ContainerRunStatus = .starting,
		imageName: String = "",
		environmentVariableNames: [String] = [],
		workspacePath: String = "",
		logPath: String = "",
		startedAt: Date = .now,
		lastSeenAt: Date = .now,
		endedAt: Date? = nil,
		exitCode: Int? = nil,
		cleanupEligibility: ContainerCleanupEligibility = .notEligible,
		reconciliationState: ContainerReconciliationState = .unreconciled,
		failureReason: String? = nil
	) {
		self.id = id
		self.projectID = projectID
		self.runID = runID
		self.ticketRunID = ticketRunID
		self.runtimeID = runtimeID
		self.containerName = containerName
		self.statusRaw = status.rawValue
		self.imageName = imageName
		self.environmentVariableNamesJSON = Self.encodeList(environmentVariableNames)
		self.workspacePath = workspacePath
		self.logPath = logPath
		self.startedAt = startedAt
		self.lastSeenAt = lastSeenAt
		self.endedAt = endedAt
		self.exitCode = exitCode
		self.cleanupEligibilityRaw = cleanupEligibility.rawValue
		self.reconciliationStateRaw = reconciliationState.rawValue
		self.failureReason = failureReason
	}

	var status: ContainerRunStatus {
		get { ContainerRunStatus(rawValue: statusRaw) ?? .starting }
		set { statusRaw = newValue.rawValue }
	}

	var environmentVariableNames: [String] {
		get { Self.decodeList(environmentVariableNamesJSON) }
		set { environmentVariableNamesJSON = Self.encodeList(newValue) }
	}

	var cleanupEligibility: ContainerCleanupEligibility {
		get { ContainerCleanupEligibility(rawValue: cleanupEligibilityRaw) ?? .notEligible }
		set { cleanupEligibilityRaw = newValue.rawValue }
	}

	var reconciliationState: ContainerReconciliationState {
		get { ContainerReconciliationState(rawValue: reconciliationStateRaw) ?? .unreconciled }
		set { reconciliationStateRaw = newValue.rawValue }
	}

	private static func encodeList(_ values: [String]) -> String {
		(try? String(data: JSONEncoder().encode(values), encoding: .utf8)) ?? "[]"
	}

	private static func decodeList(_ json: String) -> [String] {
		(try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
	}
}

@Model
final class DispatcherRunRecord {
	var id: UUID
	var projectID: UUID
	var runID: UUID
	var statusRaw: String
	var requestedConcurrency: Int
	var effectiveConcurrency: Int
	var selectedTicketRunIDsJSON: String
	var pendingTicketRunIDsJSON: String
	var runningTicketRunIDsJSON: String
	var terminalTicketRunIDsJSON: String
	var skippedQueueItemIDsJSON: String
	var skipReasonCountsJSON: String
	var selectedCount: Int
	var skippedCount: Int
	var pendingCount: Int
	var runningCount: Int
	var terminalCount: Int
	var startedAt: Date
	var updatedAt: Date
	var completedAt: Date?
	var resumeAction: String
	var failureReason: String?

	init(
		id: UUID = UUID(),
		projectID: UUID,
		runID: UUID,
		status: DispatcherRunStatus = .planned,
		requestedConcurrency: Int,
		effectiveConcurrency: Int,
		selectedTicketRunIDs: [UUID] = [],
		pendingTicketRunIDs: [UUID] = [],
		runningTicketRunIDs: [UUID] = [],
		terminalTicketRunIDs: [UUID] = [],
		skippedQueueItemIDs: [UUID] = [],
		skipReasonCounts: [String: Int] = [:],
		selectedCount: Int = 0,
		skippedCount: Int = 0,
		pendingCount: Int = 0,
		runningCount: Int = 0,
		terminalCount: Int = 0,
		startedAt: Date = .now,
		updatedAt: Date = .now,
		completedAt: Date? = nil,
		resumeAction: String = "Run dispatcher.",
		failureReason: String? = nil
	) {
		self.id = id
		self.projectID = projectID
		self.runID = runID
		self.statusRaw = status.rawValue
		self.requestedConcurrency = requestedConcurrency
		self.effectiveConcurrency = effectiveConcurrency
		self.selectedTicketRunIDsJSON = Self.encodeUUIDs(selectedTicketRunIDs)
		self.pendingTicketRunIDsJSON = Self.encodeUUIDs(pendingTicketRunIDs)
		self.runningTicketRunIDsJSON = Self.encodeUUIDs(runningTicketRunIDs)
		self.terminalTicketRunIDsJSON = Self.encodeUUIDs(terminalTicketRunIDs)
		self.skippedQueueItemIDsJSON = Self.encodeUUIDs(skippedQueueItemIDs)
		self.skipReasonCountsJSON = Self.encodeDictionary(skipReasonCounts)
		self.selectedCount = selectedCount
		self.skippedCount = skippedCount
		self.pendingCount = pendingCount
		self.runningCount = runningCount
		self.terminalCount = terminalCount
		self.startedAt = startedAt
		self.updatedAt = updatedAt
		self.completedAt = completedAt
		self.resumeAction = resumeAction
		self.failureReason = failureReason
	}

	var status: DispatcherRunStatus {
		get { DispatcherRunStatus(rawValue: statusRaw) ?? .planned }
		set { statusRaw = newValue.rawValue }
	}

	var selectedTicketRunIDs: [UUID] {
		get { Self.decodeUUIDs(selectedTicketRunIDsJSON) }
		set { selectedTicketRunIDsJSON = Self.encodeUUIDs(newValue) }
	}

	var pendingTicketRunIDs: [UUID] {
		get { Self.decodeUUIDs(pendingTicketRunIDsJSON) }
		set { pendingTicketRunIDsJSON = Self.encodeUUIDs(newValue) }
	}

	var runningTicketRunIDs: [UUID] {
		get { Self.decodeUUIDs(runningTicketRunIDsJSON) }
		set { runningTicketRunIDsJSON = Self.encodeUUIDs(newValue) }
	}

	var terminalTicketRunIDs: [UUID] {
		get { Self.decodeUUIDs(terminalTicketRunIDsJSON) }
		set { terminalTicketRunIDsJSON = Self.encodeUUIDs(newValue) }
	}

	var skippedQueueItemIDs: [UUID] {
		get { Self.decodeUUIDs(skippedQueueItemIDsJSON) }
		set { skippedQueueItemIDsJSON = Self.encodeUUIDs(newValue) }
	}

	var skipReasonCounts: [String: Int] {
		get { Self.decodeDictionary(skipReasonCountsJSON) }
		set { skipReasonCountsJSON = Self.encodeDictionary(newValue) }
	}

	private static func encodeUUIDs(_ values: [UUID]) -> String {
		(try? String(data: JSONEncoder().encode(values.map(\.uuidString)), encoding: .utf8)) ?? "[]"
	}

	private static func decodeUUIDs(_ json: String) -> [UUID] {
		guard let strings = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else {
			return []
		}
		return strings.compactMap(UUID.init(uuidString:))
	}

	private static func encodeDictionary(_ value: [String: Int]) -> String {
		(try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "{}"
	}

	private static func decodeDictionary(_ json: String) -> [String: Int] {
		(try? JSONDecoder().decode([String: Int].self, from: Data(json.utf8))) ?? [:]
	}
}

struct WorkflowPolicy {
	static let defaultMarkdown = """
		---
		concurrency: 3
		max_retries: 2
		handoff_status: "Needs Review"
		update_issue_labels: false
		branch_prefix: "auditorium"
		run_tests: true
		open_pull_request: true
		validation:
		  command: ""
		---
		You are an autonomous coding agent working on a single issue.
		Your job:
		1. Read the issue carefully.
		2. Inspect the repository.
		3. Create a focused implementation plan.
		4. Make the smallest correct change.
		5. Run relevant tests.
		6. Fix failures.
		7. Commit changes on a ticket-specific branch.
		8. Open a pull request.
		9. Leave a concise summary for human review.
		Do not make unrelated changes.
		Do not touch secrets.
		Do not rewrite large areas unless the issue requires it.
		When blocked, explain exactly what is missing.
		"""
}
