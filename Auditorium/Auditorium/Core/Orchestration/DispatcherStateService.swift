import Foundation
import SwiftData

@MainActor
struct DispatcherStateService {
	@discardableResult
	func start(
		projectID: UUID,
		run: RunRecord,
		dispatchPlan: TicketDispatchPlan,
		ticketRuns: [TicketRunRecord],
		context: ModelContext,
		now: Date = .now
	) throws -> DispatcherRunRecord {
		let record: DispatcherRunRecord
		if let existing = try existingRecord(runID: run.id, context: context) {
			record = existing
		}
		else {
			let created = DispatcherRunRecord(
				projectID: projectID,
				runID: run.id,
				status: .running,
				requestedConcurrency: dispatchPlan.requestedConcurrency,
				effectiveConcurrency: dispatchPlan.orchestrationPlan.concurrency,
				selectedTicketRunIDs: ticketRuns.map(\.id),
				skippedQueueItemIDs: dispatchPlan.skippedItems.map(\.queueItemID),
				skipReasonCounts: skipReasonCounts(dispatchPlan.skippedItems),
				selectedCount: ticketRuns.count,
				skippedCount: dispatchPlan.skippedItems.count,
				startedAt: now,
				updatedAt: now,
				resumeAction: "Resume dispatcher for unfinished ticket runs."
			)
			context.insert(created)
			record = created
		}
		record.status = .running
		record.requestedConcurrency = dispatchPlan.requestedConcurrency
		record.effectiveConcurrency = dispatchPlan.orchestrationPlan.concurrency
		record.selectedTicketRunIDs = ticketRuns.map(\.id)
		record.skippedQueueItemIDs = dispatchPlan.skippedItems.map(\.queueItemID)
		record.skipReasonCounts = skipReasonCounts(dispatchPlan.skippedItems)
		record.selectedCount = ticketRuns.count
		record.skippedCount = dispatchPlan.skippedItems.count
		record.startedAt = now
		return try refresh(run: run, ticketRuns: ticketRuns, context: context, now: now)
	}

	@discardableResult
	func refresh(
		run: RunRecord,
		ticketRuns: [TicketRunRecord],
		context: ModelContext,
		now: Date = .now,
		statusOverride: DispatcherRunStatus? = nil,
		resumeAction: String? = nil,
		failureReason: String? = nil
	) throws -> DispatcherRunRecord {
		let record: DispatcherRunRecord
		if let existing = try existingRecord(runID: run.id, context: context) {
			record = existing
		}
		else {
			let created = DispatcherRunRecord(
				projectID: run.projectID,
				runID: run.id,
				status: .planned,
				requestedConcurrency: 0,
				effectiveConcurrency: 0,
				selectedTicketRunIDs: ticketRuns.map(\.id),
				selectedCount: ticketRuns.count,
				startedAt: run.startedAt,
				updatedAt: now
			)
			context.insert(created)
			record = created
		}
		let buckets = bucket(ticketRuns)
		record.pendingTicketRunIDs = buckets.pending
		record.runningTicketRunIDs = buckets.running
		record.terminalTicketRunIDs = buckets.terminal
		record.pendingCount = buckets.pending.count
		record.runningCount = buckets.running.count
		record.terminalCount = buckets.terminal.count
		record.status = statusOverride ?? status(for: run)
		record.updatedAt = now
		if isTerminal(record.status) {
			record.completedAt = run.endedAt ?? now
		}
		else {
			record.completedAt = nil
		}
		record.resumeAction = resumeAction ?? defaultResumeAction(for: record)
		record.failureReason = failureReason
		return record
	}

	@discardableResult
	func markReconciled(
		run: RunRecord,
		ticketRuns: [TicketRunRecord],
		context: ModelContext,
		now: Date = .now,
		reason: String
	) throws -> DispatcherRunRecord {
		try refresh(
			run: run,
			ticketRuns: ticketRuns,
			context: context,
			now: now,
			statusOverride: .reconciled,
			resumeAction: "Review reconciled failures, then requeue tickets that still need work.",
			failureReason: reason
		)
	}

	private func existingRecord(runID: UUID, context: ModelContext) throws -> DispatcherRunRecord? {
		try context.fetch(FetchDescriptor<DispatcherRunRecord>()).first { $0.runID == runID }
	}

	private func skipReasonCounts(_ skippedItems: [TicketDispatchSkip]) -> [String: Int] {
		Dictionary(grouping: skippedItems, by: { $0.reason.rawValue })
			.mapValues(\.count)
	}

	private func bucket(_ ticketRuns: [TicketRunRecord]) -> (pending: [UUID], running: [UUID], terminal: [UUID]) {
		var pending: [UUID] = []
		var running: [UUID] = []
		var terminal: [UUID] = []
		for ticketRun in ticketRuns {
			switch ticketRun.status {
			case .pending:
				pending.append(ticketRun.id)
			case .preparing, .running:
				running.append(ticketRun.id)
			case .blocked, .needsReview, .completed, .failed, .canceled:
				terminal.append(ticketRun.id)
			}
		}
		return (pending, running, terminal)
	}

	private func status(for run: RunRecord) -> DispatcherRunStatus {
		switch run.status {
		case .pending, .running, .paused:
			return .running
		case .completed:
			return .completed
		case .completedWithFailures:
			return .completedWithFailures
		case .canceled:
			return .canceled
		case .failed:
			return .failed
		}
	}

	private func isTerminal(_ status: DispatcherRunStatus) -> Bool {
		switch status {
		case .planned, .running:
			return false
		case .completed, .completedWithFailures, .canceled, .failed, .reconciled:
			return true
		}
	}

	private func defaultResumeAction(for record: DispatcherRunRecord) -> String {
		if record.runningCount > 0 {
			return "Reconcile active ticket runs before dispatching more work."
		}
		if record.pendingCount > 0 {
			return "Resume dispatcher for pending ticket runs."
		}
		if record.status == .reconciled {
			return "Review reconciled failures, then requeue tickets that still need work."
		}
		return "Review completed dispatcher results."
	}
}
