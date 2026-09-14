import Foundation
import SwiftData

struct TicketReportBackSweepResult: Equatable, Sendable {
	let attemptedCount: Int
	let succeededCount: Int
	let failedCount: Int
}

struct TicketReportBackService {
	private let inFlightTimeout: TimeInterval

	init(inFlightTimeout: TimeInterval = 300) {
		self.inFlightTimeout = inFlightTimeout
	}

	@MainActor
	func projectIDsNeedingReportBackRetry(context: ModelContext, now: Date = .now) throws -> [UUID] {
		let runs = try context.fetch(FetchDescriptor<RunRecord>()).filter { $0.status.isTerminalForReportBack }
		let runsByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
		let ticketRuns = try context.fetch(FetchDescriptor<TicketRunRecord>()).filter { $0.status.isTerminalForReportBack }
		let attempts = try context.fetch(FetchDescriptor<TicketReportBackRecord>())
		let latestAttempts = Dictionary(grouping: attempts, by: \.ticketRunID)
			.compactMapValues { $0.sorted { $0.updatedAt > $1.updatedAt }.first }
		var projectIDs: Set<UUID> = []

		for ticketRun in ticketRuns {
			guard let run = runsByID[ticketRun.runID],
				shouldAttemptReportBack(latestAttempts[ticketRun.id], now: now)
			else {
				continue
			}
			projectIDs.insert(run.projectID)
		}

		return projectIDs.sorted { $0.uuidString < $1.uuidString }
	}

	@discardableResult
	@MainActor
	func ensurePendingReportBacks(
		run: RunRecord,
		ticketRuns: [TicketRunRecord],
		tickets: [TicketRecord],
		context: ModelContext,
		now: Date = .now
	) throws -> Int {
		var existingTicketRunIDs = Set(try context.fetch(FetchDescriptor<TicketReportBackRecord>()).map(\.ticketRunID))
		let ticketsByID = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
		var queuedCount = 0

		for ticketRun in ticketRuns where ticketRun.status.isTerminalForReportBack && existingTicketRunIDs.contains(ticketRun.id) == false {
			guard let ticket = ticketsByID[ticketRun.ticketID] else { continue }
			let attempt = TicketReportBackRecord(
				ticketRunID: ticketRun.id,
				provider: ticket.provider,
				externalTicketID: ticket.externalID,
				status: .pending,
				attemptedAt: now,
				updatedAt: now
			)
			context.insert(
				attempt
			)
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					timestamp: now,
					level: .info,
					category: .report,
					message: "ticket_report_back_queued",
					metadataJSON: reportBackEventMetadata(attempt)
				)
			)
			existingTicketRunIDs.insert(ticketRun.id)
			queuedCount += 1
		}

		if queuedCount > 0 {
			try ModelIntegrityValidator.save(context: context)
		}
		return queuedCount
	}

	@discardableResult
	@MainActor
	func publishTerminalTicketRuns(
		project: Project,
		run: RunRecord,
		ticketRuns: [TicketRunRecord],
		tickets: [TicketRecord],
		pullRequests: [PullRequestRecord],
		policy: ParsedWorkflowPolicy,
		provider: any HandoffProvider,
		context: ModelContext,
		now: Date = .now
	) async -> TicketReportBackSweepResult {
		let existingAttempts = (try? context.fetch(FetchDescriptor<TicketReportBackRecord>())) ?? []
		let attemptsByTicketRunID = Dictionary(grouping: existingAttempts, by: \.ticketRunID)
			.compactMapValues { $0.sorted { $0.updatedAt > $1.updatedAt }.first }
		var attemptedCount = 0
		var succeededCount = 0
		var failedCount = 0
		for ticketRun in ticketRuns where ticketRun.status.isTerminalForReportBack {
			if shouldAttemptReportBack(attemptsByTicketRunID[ticketRun.id], now: now) == false {
				continue
			}
			guard let ticket = tickets.first(where: { $0.id == ticketRun.ticketID }) else {
				continue
			}
			attemptedCount += 1
			let didSucceed = await publish(
				project: project,
				run: run,
				ticketRun: ticketRun,
				ticket: ticket,
				pullRequest: pullRequests.first { $0.ticketRunID == ticketRun.id },
				policy: policy,
				provider: provider,
				context: context,
				now: now
			)
			if didSucceed {
				succeededCount += 1
			}
			else {
				failedCount += 1
			}
		}
		return TicketReportBackSweepResult(attemptedCount: attemptedCount, succeededCount: succeededCount, failedCount: failedCount)
	}

	@discardableResult
	@MainActor
	func publishPendingReportBacks(
		projectID: UUID,
		context: ModelContext,
		providerRegistry: ProviderRegistry,
		now: Date = .now
	) async throws -> TicketReportBackSweepResult {
		let projects = try context.fetch(FetchDescriptor<Project>())
		guard let project = projects.first(where: { $0.id == projectID }) else {
			throw ProjectCreationError.projectNotFound(projectID)
		}
		let provider = try await providerRegistry.issueTrackerProvider(for: project, context: context)
		let runs = try context.fetch(FetchDescriptor<RunRecord>()).filter { $0.projectID == project.id }
		let ticketRuns = try context.fetch(FetchDescriptor<TicketRunRecord>())
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		let pullRequests = try context.fetch(FetchDescriptor<PullRequestRecord>())
		var aggregate = TicketReportBackSweepResult(attemptedCount: 0, succeededCount: 0, failedCount: 0)
		for run in runs where run.status.isTerminalForReportBack {
			let policy = (try? WorkflowPolicyParser().parse(run.workflowPolicySnapshotMarkdown)) ?? ParsedWorkflowPolicy.defaultPolicy()
			let result = await publishTerminalTicketRuns(
				project: project,
				run: run,
				ticketRuns: ticketRuns.filter { $0.runID == run.id },
				tickets: tickets,
				pullRequests: pullRequests,
				policy: policy,
				provider: provider,
				context: context,
				now: now
			)
			aggregate = TicketReportBackSweepResult(
				attemptedCount: aggregate.attemptedCount + result.attemptedCount,
				succeededCount: aggregate.succeededCount + result.succeededCount,
				failedCount: aggregate.failedCount + result.failedCount
			)
		}
		return aggregate
	}

	private func shouldAttemptReportBack(_ attempt: TicketReportBackRecord?, now: Date) -> Bool {
		guard let attempt else { return true }
		if attempt.status == .succeeded {
			return false
		}
		if attempt.status == .inFlight {
			guard let startedAt = attempt.inFlightStartedAt else {
				return true
			}
			return startedAt.addingTimeInterval(inFlightTimeout) <= now
		}
		if let retryAfter = attempt.retryAfter, retryAfter > now {
			return false
		}
		return true
	}

	@MainActor
	private func publish(
		project: Project,
		run: RunRecord,
		ticketRun: TicketRunRecord,
		ticket: TicketRecord,
		pullRequest: PullRequestRecord?,
		policy: ParsedWorkflowPolicy,
		provider: any HandoffProvider,
		context: ModelContext,
		now: Date
	) async -> Bool {
		let createdAttempt: TicketReportBackRecord?
		let attempt: TicketReportBackRecord
		if let existing = existingOutboxItem(ticketRunID: ticketRun.id, context: context) {
			attempt = existing
			createdAttempt = nil
		}
		else {
			let created = TicketReportBackRecord(
				ticketRunID: ticketRun.id,
				provider: provider.kind,
				externalTicketID: ticket.externalID,
				status: .pending,
				attemptedAt: now,
				updatedAt: now
			)
			attempt = created
			createdAttempt = created
		}
		if let createdAttempt {
			context.insert(createdAttempt)
		}
		attempt.status = .inFlight
		attempt.attemptCount += 1
		attempt.attemptedAt = now
		attempt.inFlightStartedAt = now
		attempt.updatedAt = now
		attempt.failureReason = nil
		context.insert(
			RuntimeEventRecord(
				runID: run.id,
				ticketRunID: ticketRun.id,
				timestamp: now,
				level: .info,
				category: .report,
				message: "ticket_report_back_started",
				metadataJSON: reportBackEventMetadata(attempt)
			)
		)
		if ticketRun.lifecyclePhase == .failed {
			TicketRunLifecycleService().transition(ticketRun, to: .reportBackPending, runID: run.id, context: context, now: now)
		}
		try? ModelIntegrityValidator.save(context: context)
		do {
			let receipt = try await provider.publishHandoff(
				TicketHandoffRequest(
					ticketID: ticket.externalID,
					body: commentBody(project: project, run: run, ticketRun: ticketRun, ticket: ticket, pullRequest: pullRequest),
					labels: handoffLabels(for: ticketRun, policy: policy)
				)
			)
			attempt.status = .succeeded
			attempt.commentURL = receipt.commentURL?.absoluteString
			attempt.retryAfter = nil
			attempt.inFlightStartedAt = nil
			attempt.updatedAt = now
			TicketRunLifecycleService().transition(ticketRun, to: .reported, runID: run.id, context: context, now: now)
			TicketRunLifecycleService().transition(ticketRun, to: .reviewReady, runID: run.id, context: context, now: now)
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					timestamp: now,
					level: .success,
					category: .report,
					message: "ticket_report_back_completed",
					metadataJSON: reportBackEventMetadata(attempt)
				)
			)
			try? ModelIntegrityValidator.save(context: context)
			return true
		}
		catch {
			attempt.status = .failed
			attempt.failureReason = error.localizedDescription
			attempt.retryAfter = retryAfter(for: attempt, now: now)
			attempt.inFlightStartedAt = nil
			attempt.updatedAt = now
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					timestamp: now,
					level: .error,
					category: .report,
					message: "ticket_report_back_failed",
					metadataJSON: reportBackEventMetadata(attempt)
				)
			)
		}
		try? ModelIntegrityValidator.save(context: context)
		return false
	}

	private func existingOutboxItem(ticketRunID: UUID, context: ModelContext) -> TicketReportBackRecord? {
		(try? context.fetch(FetchDescriptor<TicketReportBackRecord>()))?.first { $0.ticketRunID == ticketRunID }
	}

	private func retryAfter(for attempt: TicketReportBackRecord, now: Date) -> Date {
		let delay = min(3_600, max(30, 30 * (1 << min(attempt.attemptCount - 1, 6))))
		return now.addingTimeInterval(TimeInterval(delay))
	}

	private func handoffLabels(for ticketRun: TicketRunRecord, policy: ParsedWorkflowPolicy) -> [String] {
		guard ticketRun.status.shouldApplyHandoffLabel,
			let label = policy.handoffStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
			label.isEmpty == false
		else {
			return []
		}
		return [label]
	}

	private func commentBody(
		project: Project,
		run: RunRecord,
		ticketRun: TicketRunRecord,
		ticket: TicketRecord,
		pullRequest: PullRequestRecord?
	) -> String {
		var lines = [
			"Auditorium finished processing this ticket.",
			"",
			"- Project: \(project.name)",
			"- Run: \(run.id.uuidString)",
			"- Status: \(ticketRun.status.title)",
			"- Branch: \(valueOrNone(ticketRun.branchName))",
		]
		if let pullRequestURL = pullRequest?.url ?? ticketRun.pullRequestURL {
			lines.append("- Pull request: \(pullRequestURL)")
			lines.append("- Next step: review the pull request and run report in Auditorium.")
		}
		else if ticketRun.status == .completed {
			lines.append("- Pull request: none")
			lines.append("- Next step: review the run summary in Auditorium.")
		}
		else {
			lines.append("- Failure reason: \(externalSafeValueOrNone(ticketRun.failureReason))")
			lines.append("- Next step: inspect the run in Auditorium, then retry after resolving the blocker.")
		}
		if ticketRun.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
			lines.append("- Summary: \(externalSafeValueOrNone(ticketRun.summary))")
		}
		lines.append("- Ticket: \(ticket.externalID)")
		return lines.joined(separator: "\n")
	}

	private func valueOrNone(_ value: String?) -> String {
		let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? "None" : trimmed
	}

	private func externalSafeValueOrNone(_ value: String?) -> String {
		let sanitized = sanitizeExternalCommentValue(value)
		return sanitized.isEmpty ? "None" : sanitized
	}

	private func sanitizeExternalCommentValue(_ value: String?) -> String {
		var sanitized = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		guard sanitized.isEmpty == false else { return "" }

		let replacements: [(String, String)] = [
			(#"(?i)(/Users/[^\s,;:)]+)"#, "[local path redacted]"),
			(#"(?i)(/private/tmp/[^\s,;:)]+)"#, "[local path redacted]"),
			(#"(?i)(/tmp/[^\s,;:)]+)"#, "[local path redacted]"),
			(#"(?i)(/var/folders/[^\s,;:)]+)"#, "[local path redacted]"),
			(#"(?i)(CODEX_AUTH_JSON|OPENAI_API_KEY|GH_TOKEN|GITHUB_TOKEN|keychain|auth\.json)[^\s,;)]*"#, "[sensitive value redacted]"),
			(#"(?i)\b[A-Z_]*(?:TOKEN|SECRET|PASSWORD|KEY)=\S+"#, "[sensitive value redacted]"),
		]
		for (pattern, replacement) in replacements {
			sanitized = sanitized.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
		}
		return sanitized
	}

	private func reportBackEventMetadata(_ attempt: TicketReportBackRecord) -> String {
		let payload = TicketReportBackEventMetadata(
			reportBackID: attempt.id.uuidString,
			provider: attempt.provider.rawValue,
			externalTicketID: attempt.externalTicketID,
			status: attempt.status.rawValue,
			attemptCount: attempt.attemptCount,
			retryAfter: attempt.retryAfter.map(Self.iso8601Formatter.string(from:)),
			commentURL: attempt.commentURL,
			failureReason: attempt.failureReason
		)
		return (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "{}"
	}

	private static let iso8601Formatter: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()
}

private struct TicketReportBackEventMetadata: Encodable {
	let reportBackID: String
	let provider: String
	let externalTicketID: String
	let status: String
	let attemptCount: Int
	let retryAfter: String?
	let commentURL: String?
	let failureReason: String?
}

extension RunStatus {
	fileprivate var isTerminalForReportBack: Bool {
		switch self {
		case .completed, .completedWithFailures, .canceled, .failed:
			return true
		case .pending, .running, .paused:
			return false
		}
	}
}
