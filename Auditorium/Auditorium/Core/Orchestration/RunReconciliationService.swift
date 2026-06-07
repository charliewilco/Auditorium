import Foundation
import SwiftData

struct RunReconciliationResult: Equatable {
	let reconciledRuns: Int
	let reconciledTicketRuns: Int
}

@MainActor
struct RunReconciliationService {
	func reconcileInterruptedRuns(context: ModelContext, now: Date = .now) throws -> RunReconciliationResult {
		let runs = try context.fetch(FetchDescriptor<RunRecord>())
		let ticketRuns = try context.fetch(FetchDescriptor<TicketRunRecord>())
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		var reconciledRuns = 0
		var reconciledTicketRuns = 0

		for run in runs where Self.isActive(run.status) {
			reconciledRuns += 1
			let relatedTicketRuns = ticketRuns.filter { $0.runID == run.id }
			var reconciledTicketRunsForRun = 0
			for ticketRun in relatedTicketRuns where Self.isActive(ticketRun.status) {
				reconciledTicketRuns += 1
				reconciledTicketRunsForRun += 1
				let previousStatus = ticketRun.status
				ticketRun.status = .failed
				ticketRun.endedAt = now
				ticketRun.failureReason = "Run was interrupted during a previous app session."
				if let ticket = tickets.first(where: { $0.id == ticketRun.ticketID }) {
					reconcile(ticket: ticket, previousTicketRunStatus: previousStatus, now: now)
				}
				context.insert(RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					timestamp: now,
					level: .error,
					category: .orchestration,
					message: "Ticket run reconciled as failed after app relaunch."
				))
			}
			run.status = .failed
			run.endedAt = now
			run.completedTickets = relatedTicketRuns.filter { $0.status == .completed || $0.status == .needsReview }.count
			run.failedTickets = relatedTicketRuns.filter { $0.status == .failed }.count
			run.blockedTickets = relatedTicketRuns.filter { $0.status == .blocked }.count
			run.pullRequestsCreated = relatedTicketRuns.filter { $0.pullRequestURL != nil }.count
			run.summary = "Run was interrupted during a previous app session. Reconciled \(reconciledTicketRunsForRun) unfinished ticket runs."
			context.insert(RuntimeEventRecord(
				runID: run.id,
				timestamp: now,
				level: .error,
				category: .orchestration,
				message: "Run reconciled as failed after app relaunch."
			))
		}

		if reconciledRuns > 0 {
			try ModelIntegrityValidator.save(context: context)
		}
		return RunReconciliationResult(reconciledRuns: reconciledRuns, reconciledTicketRuns: reconciledTicketRuns)
	}

	private static func isActive(_ status: RunStatus) -> Bool {
		switch status {
		case .pending, .running, .paused:
			return true
		case .completed, .completedWithFailures, .canceled, .failed:
			return false
		}
	}

	private static func isActive(_ status: TicketRunStatus) -> Bool {
		switch status {
		case .pending, .preparing, .running:
			return true
		case .blocked, .needsReview, .completed, .failed, .canceled:
			return false
		}
	}

	private func reconcile(ticket: TicketRecord, previousTicketRunStatus: TicketRunStatus, now: Date) {
		switch previousTicketRunStatus {
		case .preparing, .running:
			ticket.status = .failed
			ticket.updatedAt = now
		case .pending:
			if ticket.status == .running {
				ticket.status = .failed
				ticket.updatedAt = now
			}
		case .blocked, .needsReview, .completed, .failed, .canceled:
			break
		}
	}
}
