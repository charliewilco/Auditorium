import Foundation
import SwiftData

struct TicketDispatchPlan: Equatable, Sendable {
	let projectID: UUID
	let requestedConcurrency: Int
	let orchestrationPlan: OrchestrationRunPlan
	let skippedItems: [TicketDispatchSkip]

	var hasDispatchableWork: Bool {
		orchestrationPlan.queueSnapshot.isEmpty == false
	}
}

struct TicketDispatchSkip: Equatable, Sendable {
	let queueItemID: UUID
	let ticketID: UUID?
	let reason: TicketDispatchSkipReason
	let detail: String
}

enum TicketDispatchSkipReason: String, Codable, Equatable, Sendable {
	case disabled
	case missingTicket
	case terminalTicket
	case blockedTicket
	case unresolvedBlocker
	case alreadyRunning
	case retryBackoff
	case retryLimitReached

	var title: String {
		switch self {
		case .disabled: "Disabled"
		case .missingTicket: "Missing Ticket"
		case .terminalTicket: "Terminal Ticket"
		case .blockedTicket: "Blocked Ticket"
		case .unresolvedBlocker: "Unresolved Blocker"
		case .alreadyRunning: "Already Running"
		case .retryBackoff: "Retry Backoff"
		case .retryLimitReached: "Retry Limit Reached"
		}
	}
}

@MainActor
struct TicketDispatcherService {
	func makeDispatchPlan(
		project: Project,
		requestedConcurrency: Int,
		context: ModelContext,
		now: Date = .now
	) throws -> TicketDispatchPlan {
		let queueItems = try context.fetch(FetchDescriptor<QueueItemRecord>())
			.filter { $0.projectID == project.id }
			.sorted(by: dispatchOrder)
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
			.filter { $0.sourceProjectID == project.id }
		let ticketRuns = try context.fetch(FetchDescriptor<TicketRunRecord>())
		let parsedPolicy = try? WorkflowPolicyParser().parse(project.workflowPolicyMarkdown)
		let retryPolicy =
			parsedPolicy.map(RetryPolicy.init(parsedPolicy:))
			?? RetryPolicy(maxRetries: 0, maxRetryBackoffMilliseconds: 300_000)
		let ticketsByID = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
		let ticketsByExternalID = Dictionary(grouping: tickets, by: \.externalID)
		let activeTicketIDs = Set(
			ticketRuns
				.filter { $0.status == .preparing || $0.status == .running }
				.map(\.ticketID)
		)
		let latestRunsByTicketID = latestRunsByTicketID(ticketRuns)

		var dispatchableItems: [QueueItemRecord] = []
		var skippedItems: [TicketDispatchSkip] = []

		for item in queueItems {
			guard item.isEnabled else {
				skippedItems.append(skip(item, ticketID: item.ticketID, reason: .disabled, detail: "Queue item is disabled."))
				continue
			}
			guard let ticket = ticketsByID[item.ticketID] else {
				skippedItems.append(
					skip(item, ticketID: item.ticketID, reason: .missingTicket, detail: "Queue item has no matching ticket.")
				)
				continue
			}
			if activeTicketIDs.contains(ticket.id) {
				skippedItems.append(
					skip(item, ticketID: ticket.id, reason: .alreadyRunning, detail: "Ticket already has an active run.")
				)
				continue
			}
			if ticket.status == .needsReview || ticket.status == .completed || ticket.status == .canceled {
				skippedItems.append(
					skip(item, ticketID: ticket.id, reason: .terminalTicket, detail: "Ticket is already \(ticket.status.title).")
				)
				continue
			}
			if ticket.status == .blocked {
				skippedItems.append(skip(item, ticketID: ticket.id, reason: .blockedTicket, detail: "Ticket is marked blocked."))
				continue
			}
			if let unresolvedBlocker = unresolvedBlocker(for: ticket, ticketsByExternalID: ticketsByExternalID) {
				skippedItems.append(
					skip(
						item,
						ticketID: ticket.id,
						reason: .unresolvedBlocker,
						detail: "Waiting on blocker \(unresolvedBlocker)."
					)
				)
				continue
			}
			if let latestRun = latestRunsByTicketID[ticket.id], latestRun.status == .failed {
				if retryPolicy.shouldRetry(status: latestRun.status, retryCount: latestRun.retryCount) == false {
					skippedItems.append(
						skip(
							item,
							ticketID: ticket.id,
							reason: .retryLimitReached,
							detail:
								"Retry count \(latestRun.retryCount) is not eligible under max retries \(retryPolicy.maxRetries)."
						)
					)
					continue
				}
				if let endedAt = latestRun.endedAt {
					let backoff = TimeInterval(retryPolicy.backoffMilliseconds(for: max(0, latestRun.retryCount - 1))) / 1000
					let retryAfter = endedAt.addingTimeInterval(backoff)
					if retryAfter > now {
						skippedItems.append(
							skip(
								item,
								ticketID: ticket.id,
								reason: .retryBackoff,
								detail:
									"Retry available after \(retryAfter.formatted(date: .omitted, time: .shortened))."
							)
						)
						continue
					}
				}
			}
			dispatchableItems.append(item)
		}

		return TicketDispatchPlan(
			projectID: project.id,
			requestedConcurrency: requestedConcurrency,
			orchestrationPlan: OrchestrationRunPlan.make(
				queueItems: dispatchableItems,
				requestedConcurrency: requestedConcurrency,
				workflowPolicyMarkdown: project.workflowPolicyMarkdown
			),
			skippedItems: skippedItems
		)
	}

	private func dispatchOrder(_ lhs: QueueItemRecord, _ rhs: QueueItemRecord) -> Bool {
		if lhs.position != rhs.position {
			return lhs.position < rhs.position
		}
		if lhs.priority.sortWeight != rhs.priority.sortWeight {
			return lhs.priority.sortWeight > rhs.priority.sortWeight
		}
		return lhs.createdAt < rhs.createdAt
	}

	private func latestRunsByTicketID(_ ticketRuns: [TicketRunRecord]) -> [UUID: TicketRunRecord] {
		var latest: [UUID: TicketRunRecord] = [:]
		for ticketRun in ticketRuns {
			guard let existing = latest[ticketRun.ticketID] else {
				latest[ticketRun.ticketID] = ticketRun
				continue
			}
			if sortDate(ticketRun) > sortDate(existing) {
				latest[ticketRun.ticketID] = ticketRun
			}
		}
		return latest
	}

	private func sortDate(_ ticketRun: TicketRunRecord) -> Date {
		ticketRun.endedAt ?? ticketRun.startedAt ?? .distantPast
	}

	private func unresolvedBlocker(for ticket: TicketRecord, ticketsByExternalID: [String: [TicketRecord]]) -> String? {
		for blocker in ticket.blockedBy where blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
			let normalized = blocker.trimmingCharacters(in: .whitespacesAndNewlines)
			let blockerTickets = ticketsByExternalID[normalized] ?? []
			guard let blockerTicket = blockerTickets.first else {
				return normalized
			}
			if blockerTicket.status != .completed && blockerTicket.status != .needsReview {
				return normalized
			}
		}
		return nil
	}

	private func skip(
		_ item: QueueItemRecord,
		ticketID: UUID?,
		reason: TicketDispatchSkipReason,
		detail: String
	) -> TicketDispatchSkip {
		TicketDispatchSkip(queueItemID: item.id, ticketID: ticketID, reason: reason, detail: detail)
	}
}
