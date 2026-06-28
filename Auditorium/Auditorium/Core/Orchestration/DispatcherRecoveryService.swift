import Foundation
import SwiftData

struct DispatcherRecoveryResult: Equatable, Sendable {
	let scannedDispatcherRuns: Int
	let recoveredTicketIDs: [UUID]
	let alreadyQueuedTicketIDs: [UUID]
	let skippedTicketIDs: [UUID]
	let recoveredProjectIDs: [UUID]

	var recoveredCount: Int { recoveredTicketIDs.count }
	var alreadyQueuedCount: Int { alreadyQueuedTicketIDs.count }
	var skippedCount: Int { skippedTicketIDs.count }
	var hasRecoverableWork: Bool { recoveredCount > 0 || alreadyQueuedCount > 0 }
}

struct DispatcherResumeCommand: Equatable, Sendable {
	let projectIDs: [UUID]
	let ticketIDs: [UUID]
	let recoveredTicketIDs: [UUID]
	let alreadyQueuedTicketIDs: [UUID]
	let skippedTicketIDs: [UUID]
	let summary: String

	init(recoveryResult: DispatcherRecoveryResult) {
		self.projectIDs = recoveryResult.recoveredProjectIDs
		self.recoveredTicketIDs = recoveryResult.recoveredTicketIDs
		self.alreadyQueuedTicketIDs = recoveryResult.alreadyQueuedTicketIDs
		self.skippedTicketIDs = recoveryResult.skippedTicketIDs
		self.ticketIDs = Self.unique(recoveryResult.recoveredTicketIDs + recoveryResult.alreadyQueuedTicketIDs)
		self.summary = Self.summary(
			recoveredCount: recoveryResult.recoveredCount,
			alreadyQueuedCount: recoveryResult.alreadyQueuedCount,
			skippedCount: recoveryResult.skippedCount,
			projectCount: recoveryResult.recoveredProjectIDs.count
		)
	}

	var hasWorkToStart: Bool {
		ticketIDs.isEmpty == false && projectIDs.isEmpty == false
	}

	var singleProjectID: UUID? {
		projectIDs.count == 1 ? projectIDs[0] : nil
	}

	var canStartSingleProject: Bool {
		hasWorkToStart && singleProjectID != nil
	}

	private static func unique(_ values: [UUID]) -> [UUID] {
		var seen: Set<UUID> = []
		var result: [UUID] = []
		for value in values where seen.contains(value) == false {
			seen.insert(value)
			result.append(value)
		}
		return result
	}

	private static func summary(recoveredCount: Int, alreadyQueuedCount: Int, skippedCount: Int, projectCount: Int) -> String {
		guard recoveredCount > 0 || alreadyQueuedCount > 0 else {
			return "No recovered dispatcher work is ready to start."
		}
		let ticketCount = recoveredCount + alreadyQueuedCount
		let ticketWord = ticketCount == 1 ? "ticket" : "tickets"
		let projectWord = projectCount == 1 ? "project" : "projects"
		if skippedCount > 0 {
			return "Resume \(ticketCount) recovered \(ticketWord) across \(projectCount) \(projectWord); \(skippedCount) were skipped."
		}
		return "Resume \(ticketCount) recovered \(ticketWord) across \(projectCount) \(projectWord)."
	}
}

@MainActor
struct DispatcherRecoveryService {
	func recoverReconciledRuns(projectID: UUID? = nil, context: ModelContext, now: Date = .now) throws -> DispatcherRecoveryResult {
		let dispatchers = try context.fetch(FetchDescriptor<DispatcherRunRecord>())
			.filter { dispatcher in
				dispatcher.status == .reconciled && (projectID == nil || dispatcher.projectID == projectID)
			}
			.sorted { $0.updatedAt < $1.updatedAt }
		let ticketRuns = try context.fetch(FetchDescriptor<TicketRunRecord>())
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		var queueItems = try context.fetch(FetchDescriptor<QueueItemRecord>())

		var recoveredTicketIDs: [UUID] = []
		var alreadyQueuedTicketIDs: [UUID] = []
		var skippedTicketIDs: [UUID] = []
		var recoveredProjectIDs: [UUID] = []

		for dispatcher in dispatchers {
			let relatedTicketRuns = ticketRunsByDispatcherOrder(dispatcher: dispatcher, ticketRuns: ticketRuns)
			let candidates = recoveryCandidates(ticketRuns: relatedTicketRuns, tickets: tickets)
			guard candidates.isEmpty == false else {
				dispatcher.resumeAction = "No retryable interrupted ticket runs remain for recovery."
				dispatcher.updatedAt = now
				continue
			}

			var runRecovered: [UUID] = []
			var runAlreadyQueued: [UUID] = []
			var runSkipped: [UUID] = []
			var nextPosition = ((queueItems.filter { $0.projectID == dispatcher.projectID }.map(\.position).max()) ?? -1) + 1

			for ticket in candidates {
				if recoveredTicketIDs.contains(ticket.id) || alreadyQueuedTicketIDs.contains(ticket.id) {
					runSkipped.append(ticket.id)
					continue
				}
				let existingItems =
					queueItems
					.filter { $0.projectID == dispatcher.projectID && $0.ticketID == ticket.id }
					.sorted { $0.position < $1.position }
				if let existingItem = existingItems.first {
					if existingItem.isEnabled {
						runAlreadyQueued.append(ticket.id)
						alreadyQueuedTicketIDs.append(ticket.id)
					}
					else {
						existingItem.isEnabled = true
						runRecovered.append(ticket.id)
						recoveredTicketIDs.append(ticket.id)
					}
				}
				else {
					let item = QueueItemRecord(
						ticketID: ticket.id,
						projectID: dispatcher.projectID,
						position: nextPosition,
						priority: ticket.priority
					)
					context.insert(item)
					queueItems.append(item)
					nextPosition += 1
					runRecovered.append(ticket.id)
					recoveredTicketIDs.append(ticket.id)
				}
				ticket.status = .queued
				ticket.updatedAt = now
			}

			skippedTicketIDs.append(contentsOf: runSkipped)
			if runRecovered.isEmpty == false || runAlreadyQueued.isEmpty == false {
				if recoveredProjectIDs.contains(dispatcher.projectID) == false {
					recoveredProjectIDs.append(dispatcher.projectID)
				}
				dispatcher.resumeAction =
					"Recovered \(runRecovered.count + runAlreadyQueued.count) interrupted ticket runs to the queue; start a new supervised run when ready."
				dispatcher.updatedAt = now
				context.insert(
					RuntimeEventRecord(
						runID: dispatcher.runID,
						timestamp: now,
						level: .warning,
						category: .orchestration,
						message: "dispatcher_recovery_requeued",
						metadataJSON: recoveryMetadata(
							recovered: runRecovered,
							alreadyQueued: runAlreadyQueued,
							skipped: runSkipped
						)
					)
				)
			}
		}

		if recoveredTicketIDs.isEmpty == false || alreadyQueuedTicketIDs.isEmpty == false || skippedTicketIDs.isEmpty == false {
			try normalizeQueuePositions(queueItems: queueItems, context: context)
		}
		try ModelIntegrityValidator.save(context: context)
		return DispatcherRecoveryResult(
			scannedDispatcherRuns: dispatchers.count,
			recoveredTicketIDs: recoveredTicketIDs,
			alreadyQueuedTicketIDs: alreadyQueuedTicketIDs,
			skippedTicketIDs: skippedTicketIDs,
			recoveredProjectIDs: recoveredProjectIDs
		)
	}

	private func ticketRunsByDispatcherOrder(dispatcher: DispatcherRunRecord, ticketRuns: [TicketRunRecord]) -> [TicketRunRecord] {
		let byID = Dictionary(uniqueKeysWithValues: ticketRuns.map { ($0.id, $0) })
		let orderedIDs = dispatcher.selectedTicketRunIDs.isEmpty ? dispatcher.terminalTicketRunIDs : dispatcher.selectedTicketRunIDs
		return orderedIDs.compactMap { byID[$0] }
	}

	private func recoveryCandidates(ticketRuns: [TicketRunRecord], tickets: [TicketRecord]) -> [TicketRecord] {
		let ticketsByID = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
		var seen: Set<UUID> = []
		var candidates: [TicketRecord] = []
		for ticketRun in ticketRuns where isRecoverable(ticketRun.status) {
			guard seen.contains(ticketRun.ticketID) == false,
				let ticket = ticketsByID[ticketRun.ticketID],
				isRecoverable(ticket.status)
			else {
				continue
			}
			seen.insert(ticket.id)
			candidates.append(ticket)
		}
		return candidates
	}

	private func isRecoverable(_ status: TicketRunStatus) -> Bool {
		switch status {
		case .failed, .canceled:
			return true
		case .pending, .preparing, .running, .blocked, .needsReview, .completed:
			return false
		}
	}

	private func isRecoverable(_ status: TicketStatus) -> Bool {
		switch status {
		case .failed, .canceled, .queued, .ready:
			return true
		case .backlog, .running, .blocked, .needsReview, .completed:
			return false
		}
	}

	private func normalizeQueuePositions(queueItems: [QueueItemRecord], context: ModelContext) throws {
		let projectIDs = Set(queueItems.map(\.projectID))
		for projectID in projectIDs {
			let items =
				queueItems
				.filter { $0.projectID == projectID }
				.sorted { lhs, rhs in
					if lhs.position != rhs.position {
						return lhs.position < rhs.position
					}
					return lhs.createdAt < rhs.createdAt
				}
			for (index, item) in items.enumerated() {
				item.position = index
			}
		}
	}

	private func recoveryMetadata(recovered: [UUID], alreadyQueued: [UUID], skipped: [UUID]) -> String {
		struct Payload: Encodable {
			let recoveredTicketIDs: [String]
			let alreadyQueuedTicketIDs: [String]
			let skippedTicketIDs: [String]
		}
		let payload = Payload(
			recoveredTicketIDs: recovered.map(\.uuidString),
			alreadyQueuedTicketIDs: alreadyQueued.map(\.uuidString),
			skippedTicketIDs: skipped.map(\.uuidString)
		)
		return (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "{}"
	}
}
