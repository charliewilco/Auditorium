import Foundation
import SwiftData

@MainActor
struct TicketRunLifecycleService {
	@discardableResult
	func transition(
		_ ticketRun: TicketRunRecord,
		to phase: TicketRunLifecyclePhase,
		runID: UUID,
		context: ModelContext,
		now: Date = .now,
		reason: String? = nil
	) -> Bool {
		let previous = ticketRun.lifecyclePhase
		guard previous != phase else { return true }
		guard Self.canTransition(from: previous, to: phase) else {
			context.insert(
				RuntimeEventRecord(
					runID: runID,
					ticketRunID: ticketRun.id,
					timestamp: now,
					level: .warning,
					category: .orchestration,
					message: "ticket_lifecycle_transition_rejected",
					metadataJSON: metadata(previous: previous, next: phase, reason: reason)
				)
			)
			return false
		}
		ticketRun.lifecyclePhase = phase
		context.insert(
			RuntimeEventRecord(
				runID: runID,
				ticketRunID: ticketRun.id,
				timestamp: now,
				level: .info,
				category: .orchestration,
				message: "ticket_lifecycle_transition",
				metadataJSON: metadata(previous: previous, next: phase, reason: reason)
			)
		)
		return true
	}

	func fail(
		_ ticketRun: TicketRunRecord,
		runID: UUID,
		context: ModelContext,
		now: Date = .now,
		reason: String
	) {
		let failedAt = ticketRun.lifecyclePhase
		ticketRun.failedPhase = failedAt
		ticketRun.lifecyclePhase = .failed
		context.insert(
			RuntimeEventRecord(
				runID: runID,
				ticketRunID: ticketRun.id,
				timestamp: now,
				level: .error,
				category: .orchestration,
				message: "ticket_lifecycle_failed",
				metadataJSON: metadata(previous: failedAt, next: .failed, reason: reason)
			)
		)
	}

	private func metadata(previous: TicketRunLifecyclePhase, next: TicketRunLifecyclePhase, reason: String?) -> String {
		var payload = [
			"previousPhase": previous.rawValue,
			"nextPhase": next.rawValue,
		]
		if let reason {
			payload["reason"] = reason
		}
		return (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "{}"
	}

	private static func canTransition(from previous: TicketRunLifecyclePhase, to next: TicketRunLifecyclePhase) -> Bool {
		switch (previous, next) {
		case (.queued, .preparing),
			(.preparing, .running),
			(.running, .artifactPersisted),
			(.artifactPersisted, .prCreated),
			(.artifactPersisted, .noPullRequest),
			(.prCreated, .reportBackPending),
			(.noPullRequest, .reportBackPending),
			(.failed, .reportBackPending),
			(.reportBackPending, .reported),
			(.reported, .reviewReady):
			return true
		case (_, .failed):
			return previous != .reviewReady
		default:
			return false
		}
	}
}
