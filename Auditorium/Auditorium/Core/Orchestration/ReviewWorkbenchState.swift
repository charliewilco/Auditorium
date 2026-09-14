import Foundation

struct ReviewWorkbenchState: Equatable {
	struct Row: Identifiable, Equatable {
		let id: UUID
		let ticketExternalID: String
		let ticketTitle: String
		let ticketStatus: TicketStatus
		let runStatus: TicketRunStatus
		let lifecyclePhase: TicketRunLifecyclePhase
		let failedPhase: TicketRunLifecyclePhase?
		let branchName: String
		let workspacePath: String
		let runtimeID: String
		let pullRequestURL: String?
		let reportBackStatus: TicketReportBackStatus?
		let reportBackCommentURL: String?
		let reportBackSummary: String
		let containerName: String?
		let containerStatus: ContainerRunStatus?
		let containerImageName: String
		let containerEnvironmentVariableNames: [String]
		let containerExitCode: Int?
		let containerCleanupEligibility: ContainerCleanupEligibility?
		let containerReconciliationState: ContainerReconciliationState?
		let containerSummary: String
		let logTail: String
		let changedFiles: [String]
		let failureReason: String?
		let nextAction: String
	}

	struct SkippedItem: Identifiable, Equatable {
		let id: UUID
		let ticketID: UUID?
		let reason: String
		let detail: String
	}

	let rows: [Row]
	let skippedItems: [SkippedItem]

	@MainActor
	static func make(
		ticketRuns: [TicketRunRecord],
		tickets: [TicketRecord],
		events: [RuntimeEventRecord],
		coordinationMessages: [CoordinationMessageRecord],
		pullRequests: [PullRequestRecord],
		reportBacks: [TicketReportBackRecord],
		containerRuns: [ContainerRunRecord],
		logTailProvider: ((ContainerRunRecord) -> String)? = nil
	) -> ReviewWorkbenchState {
		let resolvedLogTailProvider = logTailProvider ?? { ContainerRunTrackingService().logTail(for: $0, maximumBytes: 2_048) }
		let ticketsByID = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
		let pullRequestsByTicketRunID = Dictionary(grouping: pullRequests, by: \.ticketRunID)
			.compactMapValues { $0.sorted { $0.createdAt > $1.createdAt }.first }
		let reportBacksByTicketRunID = Dictionary(grouping: reportBacks, by: \.ticketRunID)
			.compactMapValues { $0.sorted { $0.updatedAt > $1.updatedAt }.first }
		let containersByTicketRunID = Dictionary(grouping: containerRuns, by: \.ticketRunID)
			.compactMapValues { $0.sorted { $0.lastSeenAt > $1.lastSeenAt }.first }
		let eventsByTicketRunID = Dictionary(
			grouping: events.compactMap { event -> (UUID, RuntimeEventRecord)? in
				guard let ticketRunID = event.ticketRunID else { return nil }
				return (ticketRunID, event)
			}
		) { $0.0 }.mapValues { $0.map(\.1) }
		let messagesByTicketRunID = Dictionary(
			grouping: coordinationMessages.compactMap { message -> (UUID, CoordinationMessageRecord)? in
				guard let ticketRunID = message.ticketRunID else { return nil }
				return (ticketRunID, message)
			}
		) { $0.0 }.mapValues { $0.map(\.1) }

		let rows =
			ticketRuns
			.sorted { lhs, rhs in
				(lhs.startedAt ?? .distantPast, lhs.id.uuidString) < (rhs.startedAt ?? .distantPast, rhs.id.uuidString)
			}
			.map { ticketRun in
				let ticket = ticketsByID[ticketRun.ticketID]
				let pullRequest = pullRequestsByTicketRunID[ticketRun.id]
				let reportBack = reportBacksByTicketRunID[ticketRun.id]
				let container = containersByTicketRunID[ticketRun.id]
				let rowEvents = eventsByTicketRunID[ticketRun.id] ?? []
				let rowMessages = messagesByTicketRunID[ticketRun.id] ?? []
				let files = changedFiles(events: rowEvents, messages: rowMessages)
				return Row(
					id: ticketRun.id,
					ticketExternalID: ticket?.externalID ?? "Unknown",
					ticketTitle: ticket?.title ?? "Unknown Ticket",
					ticketStatus: ticket?.status ?? .backlog,
					runStatus: ticketRun.status,
					lifecyclePhase: ticketRun.lifecyclePhase,
					failedPhase: ticketRun.failedPhase,
					branchName: ticketRun.branchName,
					workspacePath: ticketRun.workspacePath,
					runtimeID: ticketRun.runtimeID,
					pullRequestURL: pullRequest?.url ?? ticketRun.pullRequestURL,
					reportBackStatus: reportBack?.status,
					reportBackCommentURL: reportBack?.commentURL,
					reportBackSummary: reportBackSummary(reportBack),
					containerName: container?.containerName,
					containerStatus: container?.status,
					containerImageName: container?.imageName ?? "",
					containerEnvironmentVariableNames: container?.environmentVariableNames ?? [],
					containerExitCode: container?.exitCode,
					containerCleanupEligibility: container?.cleanupEligibility,
					containerReconciliationState: container?.reconciliationState,
					containerSummary: containerSummary(container),
					logTail: container.map(resolvedLogTailProvider) ?? "",
					changedFiles: files,
					failureReason: ticketRun.failureReason,
					nextAction: nextAction(
						ticketRun: ticketRun,
						reportBack: reportBack,
						pullRequest: pullRequest,
						container: container
					)
				)
			}

		return ReviewWorkbenchState(
			rows: rows,
			skippedItems: skippedItems(from: events)
		)
	}

	private static func reportBackSummary(_ record: TicketReportBackRecord?) -> String {
		guard let record else { return "Report-back not queued." }
		if let retryAfter = record.retryAfter, record.status == .failed {
			return "Report-back failed; retry after \(retryAfter.formatted(date: .omitted, time: .shortened))."
		}
		return "Report-back \(record.status.title.lowercased()), \(record.attemptCount) attempt\(record.attemptCount == 1 ? "" : "s")."
	}

	private static func containerSummary(_ record: ContainerRunRecord?) -> String {
		guard let record else { return "No container record." }
		let image = record.imageName.trimmingCharacters(in: .whitespacesAndNewlines)
		let exitCode = record.exitCode.map { ", exit \($0)" } ?? ""
		let imageSummary = image.isEmpty ? "" : " using \(image)"
		if let failureReason = record.failureReason, failureReason.isEmpty == false {
			return "\(record.containerName) \(record.status.title.lowercased())\(imageSummary)\(exitCode): \(failureReason)"
		}
		return "\(record.containerName) \(record.status.title.lowercased())\(imageSummary)\(exitCode)."
	}

	private static func nextAction(
		ticketRun: TicketRunRecord,
		reportBack: TicketReportBackRecord?,
		pullRequest: PullRequestRecord?,
		container: ContainerRunRecord?
	) -> String {
		if reportBack?.status == .pending {
			return "Publish the pending report-back; execution state is already preserved."
		}
		if reportBack?.status == .inFlight {
			return "Wait for report-back delivery to finish before retrying."
		}
		if reportBack?.status == .failed {
			return "Retry report-back; execution state is already preserved."
		}
		if ticketRun.status == .failed {
			return "Inspect failure reason and log tail, then retry this ticket when ready."
		}
		if ticketRun.status == .blocked {
			return "Resolve the blocker before rerunning this ticket."
		}
		if ticketRun.status == .canceled {
			return "Requeue this ticket if the work is still needed."
		}
		if ticketRun.status == .running || ticketRun.status == .preparing || container?.status == .running {
			return "Monitor the container log and runtime events."
		}
		if pullRequest != nil || ticketRun.pullRequestURL != nil {
			return "Review the pull request and merge only after human approval."
		}
		if ticketRun.status == .completed || ticketRun.status == .needsReview {
			return "Review the saved report and changed files."
		}
		return "Wait for the dispatcher to start this ticket."
	}

	private static func changedFiles(events: [RuntimeEventRecord], messages: [CoordinationMessageRecord]) -> [String] {
		var files: [String] = []
		for event in events {
			files.append(contentsOf: stringListMetadata(event.metadataJSON, keys: ["changedFiles", "changed_files"]))
		}
		for message in messages {
			files.append(contentsOf: message.changedFiles)
		}
		return Array(NSOrderedSet(array: files).compactMap { $0 as? String })
	}

	private static func skippedItems(from events: [RuntimeEventRecord]) -> [SkippedItem] {
		events
			.filter { $0.message.hasPrefix("Dispatcher skipped queue item:") }
			.compactMap { event in
				guard let data = event.metadataJSON.data(using: .utf8),
					let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
					let queueItemIDString = object["queueItemID"] as? String,
					let queueItemID = UUID(uuidString: queueItemIDString)
				else {
					return nil
				}
				let ticketID = (object["ticketID"] as? String).flatMap(UUID.init(uuidString:))
				let reason = object["reason"] as? String ?? "unknown"
				let detail = object["detail"] as? String ?? event.message
				return SkippedItem(id: queueItemID, ticketID: ticketID, reason: reason, detail: detail)
			}
	}

	private static func stringListMetadata(_ metadataJSON: String, keys: [String]) -> [String] {
		guard let data = metadataJSON.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else {
			return []
		}
		for key in keys {
			if let values = object[key] as? [String] {
				return values
			}
			if let values = object[key] as? [Any] {
				return values.compactMap { $0 as? String }
			}
		}
		return []
	}
}
