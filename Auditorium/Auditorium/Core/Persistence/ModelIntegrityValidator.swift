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
		try validateCoordinationMessages(context: context, issues: &issues)
		try validateReports(context: context, issues: &issues)
		try validateTicketReportBacks(context: context, issues: &issues)
		try validateContainerRuns(context: context, issues: &issues)
		try validateDispatcherRuns(context: context, issues: &issues)
		try validateProviderAccounts(context: context, issues: &issues)
		try validateProjectEnvironmentSecrets(context: context, issues: &issues)
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

extension ModelIntegrityValidator {
	fileprivate static func validateProjects(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<Project>()) {
			let id = record.id.uuidString
			requireNonEmpty(record.name, model: "Project", id: id, field: "name", issues: &issues)
			requireNonEmpty(record.repositoryName, model: "Project", id: id, field: "repositoryName", issues: &issues)
			requireNonEmpty(record.repositoryURL, model: "Project", id: id, field: "repositoryURL", issues: &issues)
			requireNonEmpty(record.defaultBranch, model: "Project", id: id, field: "defaultBranch", issues: &issues)
			requireKnownRawValue(
				record.repositoryProviderKindRaw,
				as: RepositoryProviderKind.self,
				model: "Project",
				id: id,
				field: "repositoryProviderKindRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.issueProviderKindRaw,
				as: IssueProviderKind.self,
				model: "Project",
				id: id,
				field: "issueProviderKindRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.runtimeProviderKindRaw,
				as: RuntimeProviderKind.self,
				model: "Project",
				id: id,
				field: "runtimeProviderKindRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.agentProviderKindRaw,
				as: AgentProviderKind.self,
				model: "Project",
				id: id,
				field: "agentProviderKindRaw",
				issues: &issues
			)
			scanSecrets(
				[
					("name", record.name),
					("repositoryName", record.repositoryName),
					("repositoryURL", record.repositoryURL),
					("workflowPolicyMarkdown", record.workflowPolicyMarkdown),
				],
				model: "Project",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateRepositories(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<RepositoryRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(
				record.providerRaw,
				as: RepositoryProviderKind.self,
				model: "RepositoryRecord",
				id: id,
				field: "providerRaw",
				issues: &issues
			)
			requireNonEmpty(record.owner, model: "RepositoryRecord", id: id, field: "owner", issues: &issues)
			requireNonEmpty(record.name, model: "RepositoryRecord", id: id, field: "name", issues: &issues)
			requireNonEmpty(record.fullName, model: "RepositoryRecord", id: id, field: "fullName", issues: &issues)
			requireNonEmpty(record.cloneURL, model: "RepositoryRecord", id: id, field: "cloneURL", issues: &issues)
			requireNonEmpty(record.webURL, model: "RepositoryRecord", id: id, field: "webURL", issues: &issues)
			requireNonEmpty(record.defaultBranch, model: "RepositoryRecord", id: id, field: "defaultBranch", issues: &issues)
			scanSecrets(
				[
					("cloneURL", record.cloneURL),
					("webURL", record.webURL),
					("localPath", record.localPath),
				],
				model: "RepositoryRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateIssueTrackers(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<IssueTrackerRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(
				record.providerRaw,
				as: IssueProviderKind.self,
				model: "IssueTrackerRecord",
				id: id,
				field: "providerRaw",
				issues: &issues
			)
			requireNonEmpty(record.displayName, model: "IssueTrackerRecord", id: id, field: "displayName", issues: &issues)
			requireNonEmpty(record.sourceIdentifier, model: "IssueTrackerRecord", id: id, field: "sourceIdentifier", issues: &issues)
			scanSecrets(
				[
					("displayName", record.displayName),
					("sourceIdentifier", record.sourceIdentifier),
					("filterName", record.filterName),
					("webURL", record.webURL),
				],
				model: "IssueTrackerRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateTickets(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<TicketRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(
				record.providerRaw,
				as: IssueProviderKind.self,
				model: "TicketRecord",
				id: id,
				field: "providerRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.statusRaw,
				as: TicketStatus.self,
				model: "TicketRecord",
				id: id,
				field: "statusRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.priorityRaw,
				as: PriorityLevel.self,
				model: "TicketRecord",
				id: id,
				field: "priorityRaw",
				issues: &issues
			)
			requireNonEmpty(record.externalID, model: "TicketRecord", id: id, field: "externalID", issues: &issues)
			requireNonEmpty(record.title, model: "TicketRecord", id: id, field: "title", issues: &issues)
			requireNonNegative(record.estimatedComplexity, model: "TicketRecord", id: id, field: "estimatedComplexity", issues: &issues)
			scanSecrets(
				[
					("externalID", record.externalID),
					("title", record.title),
					("body", record.body),
					("webURL", record.webURL),
				],
				model: "TicketRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateQueueItems(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<QueueItemRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(
				record.priorityRaw,
				as: PriorityLevel.self,
				model: "QueueItemRecord",
				id: id,
				field: "priorityRaw",
				issues: &issues
			)
			requireNonNegative(record.position, model: "QueueItemRecord", id: id, field: "position", issues: &issues)
			requireNonEmpty(record.concurrencyGroup, model: "QueueItemRecord", id: id, field: "concurrencyGroup", issues: &issues)
			scanSecrets([("concurrencyGroup", record.concurrencyGroup)], model: "QueueItemRecord", id: id, issues: &issues)
		}
	}

	fileprivate static func validateRuns(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<RunRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(record.statusRaw, as: RunStatus.self, model: "RunRecord", id: id, field: "statusRaw", issues: &issues)
			requireNonNegative(record.totalTickets, model: "RunRecord", id: id, field: "totalTickets", issues: &issues)
			requireNonNegative(record.completedTickets, model: "RunRecord", id: id, field: "completedTickets", issues: &issues)
			requireNonNegative(record.failedTickets, model: "RunRecord", id: id, field: "failedTickets", issues: &issues)
			requireNonNegative(record.blockedTickets, model: "RunRecord", id: id, field: "blockedTickets", issues: &issues)
			requireNonNegative(record.pullRequestsCreated, model: "RunRecord", id: id, field: "pullRequestsCreated", issues: &issues)
			if record.completedTickets + record.failedTickets + record.blockedTickets > record.totalTickets {
				issues.append(
					ModelIntegrityIssue(
						model: "RunRecord",
						id: id,
						field: "totalTickets",
						reason: "terminal ticket counts exceed totalTickets"
					)
				)
			}
			scanSecrets(
				[
					("queueSnapshotJSON", record.queueSnapshotJSON),
					("workflowPolicySnapshotMarkdown", record.workflowPolicySnapshotMarkdown),
					("reportMarkdown", record.reportMarkdown),
					("summary", record.summary),
				],
				model: "RunRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateTicketRuns(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<TicketRunRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(
				record.statusRaw,
				as: TicketRunStatus.self,
				model: "TicketRunRecord",
				id: id,
				field: "statusRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.lifecyclePhaseRaw,
				as: TicketRunLifecyclePhase.self,
				model: "TicketRunRecord",
				id: id,
				field: "lifecyclePhaseRaw",
				issues: &issues
			)
			if let failedPhaseRaw = record.failedPhaseRaw {
				requireKnownRawValue(
					failedPhaseRaw,
					as: TicketRunLifecyclePhase.self,
					model: "TicketRunRecord",
					id: id,
					field: "failedPhaseRaw",
					issues: &issues
				)
			}
			requireNonNegative(record.retryCount, model: "TicketRunRecord", id: id, field: "retryCount", issues: &issues)
			if !(0...1).contains(record.confidence) {
				issues.append(
					ModelIntegrityIssue(
						model: "TicketRunRecord",
						id: id,
						field: "confidence",
						reason: "confidence must be between 0 and 1"
					)
				)
			}
			scanSecrets(
				[
					("workspacePath", record.workspacePath),
					("runtimeID", record.runtimeID),
					("branchName", record.branchName),
					("lifecyclePhaseRaw", record.lifecyclePhaseRaw),
					("failedPhaseRaw", record.failedPhaseRaw ?? ""),
					("logPath", record.logPath),
					("pullRequestURL", record.pullRequestURL ?? ""),
					("summary", record.summary),
					("failureReason", record.failureReason ?? ""),
				],
				model: "TicketRunRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validatePullRequests(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<PullRequestRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(
				record.providerRaw,
				as: RepositoryProviderKind.self,
				model: "PullRequestRecord",
				id: id,
				field: "providerRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.statusRaw,
				as: PullRequestStatus.self,
				model: "PullRequestRecord",
				id: id,
				field: "statusRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.checksStatusRaw,
				as: ChecksStatus.self,
				model: "PullRequestRecord",
				id: id,
				field: "checksStatusRaw",
				issues: &issues
			)
			requireNonEmpty(record.title, model: "PullRequestRecord", id: id, field: "title", issues: &issues)
			requireNonEmpty(record.url, model: "PullRequestRecord", id: id, field: "url", issues: &issues)
			requireNonEmpty(record.branchName, model: "PullRequestRecord", id: id, field: "branchName", issues: &issues)
			requireNonEmpty(record.targetBranch, model: "PullRequestRecord", id: id, field: "targetBranch", issues: &issues)
			scanSecrets(
				[
					("title", record.title),
					("url", record.url),
					("branchName", record.branchName),
					("targetBranch", record.targetBranch),
				],
				model: "PullRequestRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateRuntimeEvents(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<RuntimeEventRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(
				record.levelRaw,
				as: EventLevel.self,
				model: "RuntimeEventRecord",
				id: id,
				field: "levelRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.categoryRaw,
				as: EventCategory.self,
				model: "RuntimeEventRecord",
				id: id,
				field: "categoryRaw",
				issues: &issues
			)
			requireNonEmpty(record.message, model: "RuntimeEventRecord", id: id, field: "message", issues: &issues)
			if record.metadataJSON.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
				issues.append(
					ModelIntegrityIssue(
						model: "RuntimeEventRecord",
						id: id,
						field: "metadataJSON",
						reason: "metadataJSON must be valid JSON"
					)
				)
			}
			scanSecrets(
				[
					("message", record.message),
					("metadataJSON", record.metadataJSON),
				],
				model: "RuntimeEventRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateCoordinationMessages(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<CoordinationMessageRecord>()) {
			let id = record.id.uuidString
			requireNonEmpty(
				record.externalMessageID,
				model: "CoordinationMessageRecord",
				id: id,
				field: "externalMessageID",
				issues: &issues
			)
			requireNonEmpty(record.kindRaw, model: "CoordinationMessageRecord", id: id, field: "kindRaw", issues: &issues)
			requireNonEmpty(record.summary, model: "CoordinationMessageRecord", id: id, field: "summary", issues: &issues)
			validateJSONStringArray(
				record.changedFilesJSON,
				model: "CoordinationMessageRecord",
				id: id,
				field: "changedFilesJSON",
				issues: &issues
			)
			validateJSONStringArray(record.labelsJSON, model: "CoordinationMessageRecord", id: id, field: "labelsJSON", issues: &issues)
			validateJSONStringArray(
				record.keywordsJSON,
				model: "CoordinationMessageRecord",
				id: id,
				field: "keywordsJSON",
				issues: &issues
			)
			scanSecrets(
				[
					("externalMessageID", record.externalMessageID),
					("kindRaw", record.kindRaw),
					("summary", record.summary),
					("changedFilesJSON", record.changedFilesJSON),
					("labelsJSON", record.labelsJSON),
					("keywordsJSON", record.keywordsJSON),
					("workspacePath", record.workspacePath),
					("branchName", record.branchName),
				],
				model: "CoordinationMessageRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateReports(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<ReportRecord>()) {
			let id = record.id.uuidString
			requireNonEmpty(record.title, model: "ReportRecord", id: id, field: "title", issues: &issues)
			requireNonEmpty(record.filePath, model: "ReportRecord", id: id, field: "filePath", issues: &issues)
			scanSecrets(
				[
					("title", record.title),
					("markdown", record.markdown),
					("filePath", record.filePath),
				],
				model: "ReportRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateTicketReportBacks(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<TicketReportBackRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(
				record.providerRaw,
				as: IssueProviderKind.self,
				model: "TicketReportBackRecord",
				id: id,
				field: "providerRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.statusRaw,
				as: TicketReportBackStatus.self,
				model: "TicketReportBackRecord",
				id: id,
				field: "statusRaw",
				issues: &issues
			)
			requireNonEmpty(record.externalTicketID, model: "TicketReportBackRecord", id: id, field: "externalTicketID", issues: &issues)
			requireNonNegative(record.attemptCount, model: "TicketReportBackRecord", id: id, field: "attemptCount", issues: &issues)
			scanSecrets(
				[
					("externalTicketID", record.externalTicketID),
					("commentURL", record.commentURL ?? ""),
					("failureReason", record.failureReason ?? ""),
				],
				model: "TicketReportBackRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateContainerRuns(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<ContainerRunRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(
				record.statusRaw,
				as: ContainerRunStatus.self,
				model: "ContainerRunRecord",
				id: id,
				field: "statusRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.cleanupEligibilityRaw,
				as: ContainerCleanupEligibility.self,
				model: "ContainerRunRecord",
				id: id,
				field: "cleanupEligibilityRaw",
				issues: &issues
			)
			requireKnownRawValue(
				record.reconciliationStateRaw,
				as: ContainerReconciliationState.self,
				model: "ContainerRunRecord",
				id: id,
				field: "reconciliationStateRaw",
				issues: &issues
			)
			requireNonEmpty(record.runtimeID, model: "ContainerRunRecord", id: id, field: "runtimeID", issues: &issues)
			requireNonEmpty(record.containerName, model: "ContainerRunRecord", id: id, field: "containerName", issues: &issues)
			validateJSONStringArray(
				record.environmentVariableNamesJSON,
				model: "ContainerRunRecord",
				id: id,
				field: "environmentVariableNamesJSON",
				issues: &issues
			)
			validateEnvironmentVariableNames(record.environmentVariableNames, model: "ContainerRunRecord", id: id, issues: &issues)
			if let exitCode = record.exitCode {
				requireNonNegative(exitCode, model: "ContainerRunRecord", id: id, field: "exitCode", issues: &issues)
			}
			scanSecrets(
				[
					("runtimeID", record.runtimeID),
					("containerName", record.containerName),
					("imageName", record.imageName),
					("workspacePath", record.workspacePath),
					("logPath", record.logPath),
					("failureReason", record.failureReason ?? ""),
				],
				model: "ContainerRunRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateDispatcherRuns(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<DispatcherRunRecord>()) {
			let id = record.id.uuidString
			requireKnownRawValue(
				record.statusRaw,
				as: DispatcherRunStatus.self,
				model: "DispatcherRunRecord",
				id: id,
				field: "statusRaw",
				issues: &issues
			)
			requireNonNegative(
				record.requestedConcurrency,
				model: "DispatcherRunRecord",
				id: id,
				field: "requestedConcurrency",
				issues: &issues
			)
			requireNonNegative(
				record.effectiveConcurrency,
				model: "DispatcherRunRecord",
				id: id,
				field: "effectiveConcurrency",
				issues: &issues
			)
			requireNonNegative(record.selectedCount, model: "DispatcherRunRecord", id: id, field: "selectedCount", issues: &issues)
			requireNonNegative(record.skippedCount, model: "DispatcherRunRecord", id: id, field: "skippedCount", issues: &issues)
			requireNonNegative(record.pendingCount, model: "DispatcherRunRecord", id: id, field: "pendingCount", issues: &issues)
			requireNonNegative(record.runningCount, model: "DispatcherRunRecord", id: id, field: "runningCount", issues: &issues)
			requireNonNegative(record.terminalCount, model: "DispatcherRunRecord", id: id, field: "terminalCount", issues: &issues)
			validateUUIDJSONArray(
				record.selectedTicketRunIDsJSON,
				model: "DispatcherRunRecord",
				id: id,
				field: "selectedTicketRunIDsJSON",
				issues: &issues
			)
			validateUUIDJSONArray(
				record.pendingTicketRunIDsJSON,
				model: "DispatcherRunRecord",
				id: id,
				field: "pendingTicketRunIDsJSON",
				issues: &issues
			)
			validateUUIDJSONArray(
				record.runningTicketRunIDsJSON,
				model: "DispatcherRunRecord",
				id: id,
				field: "runningTicketRunIDsJSON",
				issues: &issues
			)
			validateUUIDJSONArray(
				record.terminalTicketRunIDsJSON,
				model: "DispatcherRunRecord",
				id: id,
				field: "terminalTicketRunIDsJSON",
				issues: &issues
			)
			validateUUIDJSONArray(
				record.skippedQueueItemIDsJSON,
				model: "DispatcherRunRecord",
				id: id,
				field: "skippedQueueItemIDsJSON",
				issues: &issues
			)
			validateSkipReasonCounts(record.skipReasonCountsJSON, model: "DispatcherRunRecord", id: id, issues: &issues)
			if record.selectedCount != record.selectedTicketRunIDs.count {
				issues.append(
					ModelIntegrityIssue(
						model: "DispatcherRunRecord",
						id: id,
						field: "selectedCount",
						reason: "selectedCount must match selectedTicketRunIDsJSON"
					)
				)
			}
			if record.skippedCount != record.skippedQueueItemIDs.count {
				issues.append(
					ModelIntegrityIssue(
						model: "DispatcherRunRecord",
						id: id,
						field: "skippedCount",
						reason: "skippedCount must match skippedQueueItemIDsJSON"
					)
				)
			}
			if record.pendingCount != record.pendingTicketRunIDs.count {
				issues.append(
					ModelIntegrityIssue(
						model: "DispatcherRunRecord",
						id: id,
						field: "pendingCount",
						reason: "pendingCount must match pendingTicketRunIDsJSON"
					)
				)
			}
			if record.runningCount != record.runningTicketRunIDs.count {
				issues.append(
					ModelIntegrityIssue(
						model: "DispatcherRunRecord",
						id: id,
						field: "runningCount",
						reason: "runningCount must match runningTicketRunIDsJSON"
					)
				)
			}
			if record.terminalCount != record.terminalTicketRunIDs.count {
				issues.append(
					ModelIntegrityIssue(
						model: "DispatcherRunRecord",
						id: id,
						field: "terminalCount",
						reason: "terminalCount must match terminalTicketRunIDsJSON"
					)
				)
			}
			scanSecrets(
				[
					("statusRaw", record.statusRaw),
					("resumeAction", record.resumeAction),
					("failureReason", record.failureReason ?? ""),
				],
				model: "DispatcherRunRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateProviderAccounts(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<ProviderAccountRecord>()) {
			let id = record.id.uuidString
			requireKnownProviderKind(
				record.providerKindRaw,
				model: "ProviderAccountRecord",
				id: id,
				field: "providerKindRaw",
				issues: &issues
			)
			requireNonEmpty(record.displayName, model: "ProviderAccountRecord", id: id, field: "displayName", issues: &issues)
			requireNonEmpty(record.keychainAccount, model: "ProviderAccountRecord", id: id, field: "keychainAccount", issues: &issues)
			scanSecrets(
				[
					("displayName", record.displayName),
					("keychainAccount", record.keychainAccount),
					("oauthClientID", record.oauthClientID),
					("grantedScopesRaw", record.grantedScopesRaw),
					("tokenType", record.tokenType),
					("refreshTokenKeychainAccount", record.refreshTokenKeychainAccount ?? ""),
				],
				model: "ProviderAccountRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func validateProjectEnvironmentSecrets(context: ModelContext, issues: inout [ModelIntegrityIssue]) throws {
		for record in try context.fetch(FetchDescriptor<ProjectEnvironmentSecretRecord>()) {
			let id = record.id.uuidString
			requireNonEmpty(record.name, model: "ProjectEnvironmentSecretRecord", id: id, field: "name", issues: &issues)
			requireNonEmpty(
				record.keychainAccount,
				model: "ProjectEnvironmentSecretRecord",
				id: id,
				field: "keychainAccount",
				issues: &issues
			)
			if ProjectEnvironmentSecretService.isValidName(record.name) == false {
				issues.append(
					ModelIntegrityIssue(
						model: "ProjectEnvironmentSecretRecord",
						id: id,
						field: "name",
						reason: "environment variable name must match [A-Z_][A-Z0-9_]*"
					)
				)
			}
			scanSecrets(
				[
					("name", record.name),
					("keychainAccount", record.keychainAccount),
				],
				model: "ProjectEnvironmentSecretRecord",
				id: id,
				issues: &issues
			)
		}
	}

	fileprivate static func requireKnownProviderKind(
		_ value: String,
		model: String,
		id: String,
		field: String,
		issues: inout [ModelIntegrityIssue]
	) {
		if RepositoryProviderKind(rawValue: value) == nil && IssueProviderKind(rawValue: value) == nil {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "provider kind is not recognized"))
		}
	}

	fileprivate static func requireKnownRawValue<T: RawRepresentable>(
		_ value: String,
		as type: T.Type,
		model: String,
		id: String,
		field: String,
		issues: inout [ModelIntegrityIssue]
	) where T.RawValue == String {
		if type.init(rawValue: value) == nil {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "raw value is not recognized"))
		}
	}

	fileprivate static func requireNonEmpty(_ value: String, model: String, id: String, field: String, issues: inout [ModelIntegrityIssue]) {
		if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "value must not be empty"))
		}
	}

	fileprivate static func requireNonNegative(_ value: Int, model: String, id: String, field: String, issues: inout [ModelIntegrityIssue]) {
		if value < 0 {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "value must not be negative"))
		}
	}

	fileprivate static func validateJSONStringArray(
		_ value: String,
		model: String,
		id: String,
		field: String,
		issues: inout [ModelIntegrityIssue]
	) {
		guard let data = value.data(using: .utf8),
			(try? JSONDecoder().decode([String].self, from: data)) != nil
		else {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "value must be a JSON string array"))
			return
		}
	}

	fileprivate static func validateUUIDJSONArray(
		_ value: String,
		model: String,
		id: String,
		field: String,
		issues: inout [ModelIntegrityIssue]
	) {
		guard let data = value.data(using: .utf8),
			let strings = try? JSONDecoder().decode([String].self, from: data)
		else {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "value must be a JSON UUID string array"))
			return
		}
		for string in strings where UUID(uuidString: string) == nil {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "value must contain only UUID strings"))
		}
	}

	fileprivate static func validateSkipReasonCounts(
		_ value: String,
		model: String,
		id: String,
		issues: inout [ModelIntegrityIssue]
	) {
		guard let data = value.data(using: .utf8),
			let counts = try? JSONDecoder().decode([String: Int].self, from: data)
		else {
			issues.append(
				ModelIntegrityIssue(
					model: model,
					id: id,
					field: "skipReasonCountsJSON",
					reason: "value must be a JSON string-int object"
				)
			)
			return
		}
		for (reason, count) in counts {
			requireKnownRawValue(
				reason,
				as: TicketDispatchSkipReason.self,
				model: model,
				id: id,
				field: "skipReasonCountsJSON",
				issues: &issues
			)
			requireNonNegative(count, model: model, id: id, field: "skipReasonCountsJSON", issues: &issues)
		}
	}

	fileprivate static func validateEnvironmentVariableNames(
		_ values: [String],
		model: String,
		id: String,
		issues: inout [ModelIntegrityIssue]
	) {
		for value in values {
			if value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
				issues.append(
					ModelIntegrityIssue(
						model: model,
						id: id,
						field: "environmentVariableNamesJSON",
						reason: "environment variable name must match [A-Za-z_][A-Za-z0-9_]*"
					)
				)
			}
			if containsSecretMaterial(value) {
				issues.append(
					ModelIntegrityIssue(
						model: model,
						id: id,
						field: "environmentVariableNamesJSON",
						reason: "environment variable name appears to contain secret material"
					)
				)
			}
		}
	}

	fileprivate static func scanSecrets(_ fields: [(String, String)], model: String, id: String, issues: inout [ModelIntegrityIssue]) {
		for (field, value) in fields where containsSecretMaterial(value) {
			issues.append(ModelIntegrityIssue(model: model, id: id, field: field, reason: "field appears to contain secret material"))
		}
	}
}
