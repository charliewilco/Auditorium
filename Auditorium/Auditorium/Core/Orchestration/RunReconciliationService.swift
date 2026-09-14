import Foundation
import SwiftData

struct RunReconciliationResult: Equatable {
	let reconciledRuns: Int
	let reconciledTicketRuns: Int
	let killedContainers: [String]
	let orphanedContainers: [String]
	let reconciledProjectIDs: [UUID]
}

@MainActor
struct RunReconciliationService {
	let killContainer: @MainActor (String) -> Void
	let inspectContainer: @MainActor (String) -> Bool

	init(
		containerControl: ContainerRuntimeControl = ContainerRuntimeControl(),
		killContainer: (@MainActor (String) -> Void)? = nil,
		inspectContainer: (@MainActor (String) -> Bool)? = nil
	) {
		self.killContainer =
			killContainer
			?? { name in
				_ = containerControl.killContainerBlocking(named: name)
			}
		self.inspectContainer =
			inspectContainer
			?? { name in
				containerControl.inspectContainerBlocking(named: name)
			}
	}

	func reconcileInterruptedRuns(context: ModelContext, now: Date = .now) throws -> RunReconciliationResult {
		let runs = try context.fetch(FetchDescriptor<RunRecord>())
		let ticketRuns = try context.fetch(FetchDescriptor<TicketRunRecord>())
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		var reconciledRuns = 0
		var reconciledTicketRuns = 0
		var killedContainers: [String] = []
		var reconciledProjectIDs: [UUID] = []

		for run in runs where Self.isActive(run.status) {
			reconciledRuns += 1
			if reconciledProjectIDs.contains(run.projectID) == false {
				reconciledProjectIDs.append(run.projectID)
			}
			let relatedTicketRuns = ticketRuns.filter { $0.runID == run.id }
			var reconciledTicketRunsForRun = 0
			for ticketRun in relatedTicketRuns where Self.isActive(ticketRun.status) {
				if let containerName = Self.containerName(for: ticketRun), killedContainers.contains(containerName) == false {
					killContainer(containerName)
					try? ContainerRunTrackingService().markKilled(containerName: containerName, context: context, now: now)
					killedContainers.append(containerName)
				}
				reconciledTicketRuns += 1
				reconciledTicketRunsForRun += 1
				let previousStatus = ticketRun.status
				ticketRun.status = .failed
				ticketRun.endedAt = now
				ticketRun.failureReason = "Run was interrupted during a previous app session."
				TicketRunLifecycleService().fail(
					ticketRun,
					runID: run.id,
					context: context,
					now: now,
					reason: ticketRun.failureReason ?? "Run was interrupted during a previous app session."
				)
				if let ticket = tickets.first(where: { $0.id == ticketRun.ticketID }) {
					reconcile(ticket: ticket, previousTicketRunStatus: previousStatus, now: now)
				}
				context.insert(
					RuntimeEventRecord(
						runID: run.id,
						ticketRunID: ticketRun.id,
						timestamp: now,
						level: .error,
						category: .orchestration,
						message: "Ticket run reconciled as failed after app relaunch."
					)
				)
			}
			run.status = .failed
			run.endedAt = now
			run.completedTickets = relatedTicketRuns.filter { $0.status == .completed || $0.status == .needsReview }.count
			run.failedTickets = relatedTicketRuns.filter { $0.status == .failed }.count
			run.blockedTickets = relatedTicketRuns.filter { $0.status == .blocked }.count
			run.pullRequestsCreated = relatedTicketRuns.filter { $0.pullRequestURL != nil }.count
			run.summary =
				"Run was interrupted during a previous app session. Reconciled \(reconciledTicketRunsForRun) unfinished ticket runs."
			context.insert(
				RuntimeEventRecord(
					runID: run.id,
					timestamp: now,
					level: .error,
					category: .orchestration,
					message: "Run reconciled as failed after app relaunch."
				)
			)
			try DispatcherStateService().markReconciled(
				run: run,
				ticketRuns: relatedTicketRuns,
				context: context,
				now: now,
				reason: run.summary
			)
			try TicketReportBackService().ensurePendingReportBacks(
				run: run,
				ticketRuns: relatedTicketRuns,
				tickets: tickets,
				context: context,
				now: now
			)
		}

		if reconciledRuns > 0 {
			try ModelIntegrityValidator.save(context: context)
		}
		let orphanedContainers = try ContainerRunTrackingService().markMissingActiveContainersAsOrphaned(
			context: context,
			inspectContainer: inspectContainer,
			now: now
		)
		if orphanedContainers.isEmpty == false {
			try ModelIntegrityValidator.save(context: context)
		}
		return RunReconciliationResult(
			reconciledRuns: reconciledRuns,
			reconciledTicketRuns: reconciledTicketRuns,
			killedContainers: killedContainers,
			orphanedContainers: orphanedContainers,
			reconciledProjectIDs: reconciledProjectIDs
		)
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

	private static func containerName(for ticketRun: TicketRunRecord) -> String? {
		guard ticketRun.runtimeID.hasPrefix("container-") else {
			return nil
		}
		return ContainerRuntimeControl.containerName(forRuntimeID: ticketRun.runtimeID)
	}
}
