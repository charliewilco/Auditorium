import Foundation
import SwiftData

@MainActor
struct QueueService {
	func addTickets(_ ticketIDs: Set<UUID>, projectID: UUID, context: ModelContext) throws {
		let existing = try context.fetch(FetchDescriptor<QueueItemRecord>()).filter { $0.projectID == projectID }
		var nextPosition = (existing.map(\.position).max() ?? -1) + 1
		let queuedIDs = Set(existing.map(\.ticketID))
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		for ticketID in ticketIDs where !queuedIDs.contains(ticketID) {
			let priority = tickets.first(where: { $0.id == ticketID })?.priority ?? .medium
			context.insert(QueueItemRecord(ticketID: ticketID, projectID: projectID, position: nextPosition, priority: priority))
			if let ticket = tickets.first(where: { $0.id == ticketID }) {
				ticket.status = .queued
				ticket.updatedAt = .now
			}
			nextPosition += 1
		}
		try context.save()
	}

	func moveQueueItems(from source: IndexSet, to destination: Int, projectID: UUID, context: ModelContext) throws {
		var items = try context.fetch(FetchDescriptor<QueueItemRecord>())
			.filter { $0.projectID == projectID }
			.sorted { $0.position < $1.position }
		let moving = source.map { items[$0] }
		var adjustedDestination = destination
		for index in source.sorted(by: >) {
			items.remove(at: index)
			if index < adjustedDestination {
				adjustedDestination -= 1
			}
		}
		items.insert(contentsOf: moving, at: min(adjustedDestination, items.count))
		for (index, item) in items.enumerated() {
			item.position = index
		}
		try context.save()
	}

	func removeQueueItem(_ item: QueueItemRecord, context: ModelContext) throws {
		let ticketID = item.ticketID
		context.delete(item)
		if let ticket = try context.fetch(FetchDescriptor<TicketRecord>()).first(where: { $0.id == ticketID }) {
			ticket.status = .ready
			ticket.updatedAt = .now
		}
		try context.save()
	}

	func clearQueue(projectID: UUID, context: ModelContext) throws {
		let items = try context.fetch(FetchDescriptor<QueueItemRecord>()).filter { $0.projectID == projectID }
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		for item in items {
			if let ticket = tickets.first(where: { $0.id == item.ticketID }), ticket.status == .queued {
				ticket.status = .ready
				ticket.updatedAt = .now
			}
			context.delete(item)
		}
		try context.save()
	}
}
