import Foundation
import SwiftData

nonisolated struct ModelIntegrityIssue: Equatable, Sendable {
	let model: String
	let id: String
	let field: String
	let reason: String
}

nonisolated enum ModelIntegrityError: LocalizedError, Equatable {
	case invalidRows([ModelIntegrityIssue])

	var errorDescription: String? {
		switch self {
		case .invalidRows(let issues):
			"SwiftData integrity validation failed for \(issues.count) persisted field\(issues.count == 1 ? "" : "s")."
		}
	}
}

@MainActor
enum ModelIntegrityValidator {
	static func save(context: ModelContext) throws {
		let issues = try validate(context: context)
		if issues.isEmpty == false {
			throw ModelIntegrityError.invalidRows(issues)
		}
		try context.save()
	}

	static func validate(context: ModelContext) throws -> [ModelIntegrityIssue] {
		var issues: [ModelIntegrityIssue] = []
		try validateProjects(context: context, issues: &issues)
		try validateRepositories(context: context, issues: &issues)
		try validateIssueTrackers(context: context, issues: &issues)
		try validateTickets(context: context, issues: &issues)
		try validateQueueItems(context: context, issues: &issues)
		try validateRuns(context: context, issues: &issues)
		try validateTicketRuns(context: context, issues: &issues)
		try validatePullRequests(context: context, issues: &issues)
		try validateRuntimeEvents(context: context, issues: &issues)
		try validateReports(context: context, issues: &issues)
		try validateProviderAccounts(context: context, issues: &issues)
		return issues
	}

	static func containsSecretMaterial(_ value: String) -> Bool {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.isEmpty == false else {
			return false
		}
		if trimmed.range(of: #"github_pat_[A-Za-z0-9_]{20,}"#, options: .regularExpression) != nil {
			return true
		}
		if trimmed.range(of: #"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"#, options: .regularExpression) != nil {
			return true
		}
		if trimmed.range(of: #"\bBearer\s+[A-Za-z0-9._\-]{20,}\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
			return true
		}
		return false
	}
}

private extension ModelIntegrityValidator {
	static func validateProjects(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<Project>()) {
			let id = record.id.uuidString
			requireNonEmpty(record.name, model: "Project", id: id, field: "name", issues: &issues)
			requireNonEmpty(record.repositoryName, model: "Project", id: id, field: "repositoryName", issues: &issues)
			requireNonEmpty(record.repositoryURL, model: "Project", id: id, field: "repositoryURL", issues: &issues)
			requireNonEmpty(record.defaultBranch, model: "Project", id: id, field: "defaultBranch", issues: &issues)
			requireKnownRawValue(record.repositoryProviderKindRaw, as: RepositoryProviderKind.self, model: "Project", id: id, field: "repositoryProviderKindRaw", issues: &issues)
			requireKnownRawValue(record.issueProviderKindRaw, as: IssueProviderKind.self, model: "Project", id: id, field: "issueProviderKindRaw", issues: &issues)
			requireKnownRawValue(record.runtimeProviderKindRaw, as: RuntimeProviderKind.self, model: "Project", id: id, field: "runtimeProviderKindRaw", issues: &issues)
			requireKnownRawValue(record.agentProviderKindRaw, as: AgentProviderKind.self, model: "Project", id: id, field: "agentProviderKindRaw", issues: &issues)
			scanSecrets([
				("name", record.name),
				("repositoryName", record.repositoryName),
				("repositoryURL", record.repositoryURL),
				("workflowPolicyMarkdown", record.workflowPolicyMarkdown)
			], model: "Project", id: id, issues: &issues)
		}
	}

	static func validateRepositories(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<RepositoryRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(record.providerRaw, as: RepositoryProviderKind.self, model: "RepositoryRecord", id: id, field: "providerRaw", issues: &issues)
			requireNonEmpty(record.owner, model: "RepositoryRecord", id: id, field: "owner", issues: &issues)
			requireNonEmpty(record.name, model: "RepositoryRecord", id: id, field: "name", issues: &issues)
			requireNonEmpty(record.fullName, model: "RepositoryRecord", id: id, field: "fullName", issues: &issues)
			requireNonEmpty(record.cloneURL, model: "RepositoryRecord", id: id, field: "cloneURL", issues: &issues)
			requireNonEmpty(record.webURL, model: "RepositoryRecord", id: id, field: "webURL", issues: &issues)
			requireNonEmpty(record.defaultBranch, model: "RepositoryRecord", id: id, field: "defaultBranch", issues: &issues)
			scanSecrets([
				("cloneURL", record.cloneURL),
				("webURL", record.webURL),
				("localPath", record.localPath)
			], model: "RepositoryRecord", id: id, issues: &issues)
		}
	}

	static func validateIssueTrackers(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<IssueTrackerRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(record.providerRaw, as: IssueProviderKind.self, model: "IssueTrackerRecord", id: id, field: "providerRaw", issues: &issues)
			requireNonEmpty(record.displayName, model: "IssueTrackerRecord", id: id, field: "displayName", issues: &issues)
			requireNonEmpty(record.sourceIdentifier, model: "IssueTrackerRecord", id: id, field: "sourceIdentifier", issues: &issues)
			scanSecrets([
				("displayName", record.displayName),
				("sourceIdentifier", record.sourceIdentifier),
				("filterName", record.filterName),
				("webURL", record.webURL)
			], model: "IssueTrackerRecord", id: id, issues: &issues)
		}
	}

	static func validateTickets(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<TicketRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(record.providerRaw, as: IssueProviderKind.self, model: "TicketRecord", id: id, field: "providerRaw", issues: &issues)
			requireKnownRawValue(record.statusRaw, as: TicketStatus.self, model: "TicketRecord", id: id, field: "statusRaw", issues: &issues)
			requireKnownRawValue(record.priorityRaw, as: PriorityLevel.self, model: "TicketRecord", id: id, field: "priorityRaw", issues: &issues)
			requireNonEmpty(record.externalID, model: "TicketRecord", id: id, field: "externalID", issues: &issues)
			requireNonEmpty(record.title, model: "TicketRecord", id: id, field: "title", issues: &issues)
			requireNonNegative(record.estimatedComplexity, model: "TicketRecord", id: id, field: "estimatedComplexity", issues: &issues)
			scanSecrets([
				("externalID", record.externalID),
				("title", record.title),
				("body", record.body),
				("webURL", record.webURL)
			], model: "TicketRecord", id: id, issues: &issues)
		}
	}

	static func validateQueueItems(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<QueueItemRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(record.priorityRaw, as: PriorityLevel.self, model: "QueueItemRecord", id: id, field: "priorityRaw", issues: &issues)
			requireNonNegative(record.position, model: "QueueItemRecord", id: id, field: "position", issues: &issues)
			requireNonEmpty(record.concurrencyGroup, model: "QueueItemRecord", id: id, field: "concurrencyGroup", issues: &issues)
			scanSecrets([("concurrencyGroup", record.concurrencyGroup)], model: "QueueItemRecord", id: id, issues: &issues)
		}
	}

	static func validateRuns(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<RunRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(record.statusRaw, as: RunStatus.self, model: "RunRecord", id: id, field: "statusRaw", issues: &issues)
			requireNonNegative(record.totalTickets, model: "RunRecord", id: id, field: "totalTickets", issues: &issues)
			requireNonNegative(record.completedTickets, model: "RunRecord", id: id, field: "completedTickets", issues: &issues)
			requireNonNegative(record.failedTickets, model: "RunRecord", id: id, field: "failedTickets", issues: &issues)
			requireNonNegative(record.blockedTickets, model: "RunRecord", id: id, field: "blockedTickets", issues: &issues)
			requireNonNegative(record.pullRequestsCreated, model: "RunRecord", id: id, field: "pullRequestsCreated", issues: &issues)
			if record.completedTickets + record.failedTickets + record.blockedTickets > record.totalTickets {
				issues.append(ModelIntegrityIssue(model: "RunRecord", id: id, field: "totalTickets", reason: "terminal ticket counts exceed totalTickets"))
			}
			scanSecrets([
				("reportMarkdown", record.reportMarkdown),
				("summary", record.summary)
			], model: "RunRecord", id: id, issues: &issues)
		}
	}

	static func validateTicketRuns(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<TicketRunRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(record.statusRaw, as: TicketRunStatus.self, model: "TicketRunRecord", id: id, field: "statusRaw", issues: &issues)
			requireNonNegative(record.retryCount, model: "TicketRunRecord", id: id, field: "retryCount", issues: &issues)
			if !(0...1).contains(record.confidence) {
				issues.append(ModelIntegrityIssue(model: "TicketRunRecord", id: id, field: "confidence", reason: "confidence must be between 0 and 1"))
			}
			scanSecrets([
				("workspacePath", record.workspacePath),
				("containerID", record.containerID),
				("branchName", record.branchName),
				("logPath", record.logPath),
				("pullRequestURL", record.pullRequestURL ?? ""),
				("summary", record.summary),
				("failureReason", record.failureReason ?? "")
			], model: "TicketRunRecord", id: id, issues: &issues)
		}
	}

	static func validatePullRequests(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<PullRequestRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(record.providerRaw, as: RepositoryProviderKind.self, model: "PullRequestRecord", id: id, field: "providerRaw", issues: &issues)
			requireKnownRawValue(record.statusRaw, as: PullRequestStatus.self, model: "PullRequestRecord", id: id, field: "statusRaw", issues: &issues)
			requireKnownRawValue(record.checksStatusRaw, as: ChecksStatus.self, model: "PullRequestRecord", id: id, field: "checksStatusRaw", issues: &issues)
			requireNonEmpty(record.title, model: "PullRequestRecord", id: id, field: "title", issues: &issues)
			requireNonEmpty(record.url, model: "PullRequestRecord", id: id, field: "url", issues: &issues)
			requireNonEmpty(record.branchName, model: "PullRequestRecord", id: id, field: "branchName", issues: &issues)
			requireNonEmpty(record.targetBranch, model: "PullRequestRecord", id: id, field: "targetBranch", issues: &issues)
			scanSecrets([
				("title", record.title),
				("url", record.url),
				("branchName", record.branchName),
				("targetBranch", record.targetBranch)
			], model: "PullRequestRecord", id: id, issues: &issues)
		}
	}

	static func validateRuntimeEvents(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<RuntimeEventRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(record.levelRaw, as: EventLevel.self, model: "RuntimeEventRecord", id: id, field: "levelRaw", issues: &issues)
			requireKnownRawValue(record.categoryRaw, as: EventCategory.self, model: "RuntimeEventRecord", id: id, field: "categoryRaw", issues: &issues)
			requireNonEmpty(record.message, model: "RuntimeEventRecord", id: id, field: "message", issues: &issues)
			if record.metadataJSON.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
				issues.append(ModelIntegrityIssue(model: "RuntimeEventRecord", id: id, field: "metadataJSON", reason: "metadataJSON must be valid JSON"))
			}
			scanSecrets([
				("message", record.message),
				("metadataJSON", record.metadataJSON)
			], model: "RuntimeEventRecord", id: id, issues: &issues)
		}
	}

	static func validateReports(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<ReportRecord>()) {
			let id = record.id.uuidString
			requireNonEmpty(record.title, model: "ReportRecord", id: id, field: "title", issues: &issues)
			requireNonEmpty(record.filePath, model: "ReportRecord", id: id, field: "filePath", issues: &issues)
			scanSecrets([
				("title", record.title),
				("markdown", record.markdown),
				("filePath", record.filePath)
			], model: "ReportRecord", id: id, issues: &issues)
		}
	}

	static func validateProviderAccounts(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<ProviderAccountRecord>()) {
			let id = record.id.uuidString
			requireKnownProviderKind(record.providerKindRaw, model: "ProviderAccountRecord", id: id, field: "providerKindRaw", issues: &issues)
			requireNonEmpty(record.displayName, model: "ProviderAccountRecord", id: id, field: "displayName", issues: &issues)
			requireNonEmpty(record.keychainAccount, model: "ProviderAccountRecord", id: id, field: "keychainAccount", issues: &issues)
			scanSecrets([
				("displayName", record.displayName),
				("keychainAccount", record.keychainAccount),
				("oauthClientID", record.oauthClientID),
				("grantedScopesRaw", record.grantedScopesRaw),
				("tokenType", record.tokenType),
				("refreshTokenKeychainAccount", record.refreshTokenKeychainAccount ?? "")
			], model: "ProviderAccountRecord", id: id, issues: &issues)
		}
	}

	static func requireKnownProviderKind(_ value: String, model: String, id: String, field: String, issues: inout [ModelIntegrityIssue]) {
		if RepositoryProviderKind(rawValue: value) == nil && IssueProviderKind(rawValue: value) == nil {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "provider kind is not recognized"))
		}
	}

	static func requireKnownRawValue<T: RawRepresentable>(_ value: String, as type: T.Type, model: String, id: String, field: String, issues: inout [ModelIntegrityIssue]) where T.RawValue == String {
		if type.init(rawValue: value) == nil {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "raw value is not recognized"))
		}
	}

	static func requireNonEmpty(_ value: String, model: String, id: String, field: String, issues: inout [ModelIntegrityIssue]) {
		if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "value must not be empty"))
		}
	}

	static func requireNonNegative(_ value: Int, model: String, id: String, field: String, issues: inout [ModelIntegrityIssue]) {
		if value < 0 {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "value must not be negative"))
		}
	}

	static func scanSecrets(_ fields: [(String, String)], model: String, id: String, issues: inout [ModelIntegrityIssue]) {
		for (field, value) in fields where containsSecretMaterial(value) {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "field appears to contain secret material"))
		}
	}
}
