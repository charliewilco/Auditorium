import Foundation
import SwiftData

struct QueueFillResult: Equatable, Sendable {
	let queuedCount: Int
	let skippedCount: Int
	let alreadyQueuedCount: Int

	init(queuedCount: Int, skippedCount: Int, alreadyQueuedCount: Int = 0) {
		self.queuedCount = queuedCount
		self.skippedCount = skippedCount
		self.alreadyQueuedCount = alreadyQueuedCount
	}
}

struct QueueFillPolicy: Equatable, Sendable {
	let limit: Int
	let maxQueueDepth: Int
	let excludedLabels: Set<String>
	let skipsBlockedTickets: Bool

	init(
		limit: Int = 12,
		maxQueueDepth: Int = Int.max,
		excludedLabels: Set<String> = ["blocked", "do-not-run", "manual", "wontfix"],
		skipsBlockedTickets: Bool = true
	) {
		self.limit = max(0, limit)
		self.maxQueueDepth = max(0, maxQueueDepth)
		self.excludedLabels = Set(
			excludedLabels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { $0.isEmpty == false }
		)
		self.skipsBlockedTickets = skipsBlockedTickets
	}
}

struct QueueFillService {
	@discardableResult
	@MainActor
	func queueNextTickets(
		projectID: UUID,
		limit: Int = 12,
		context: ModelContext,
		providerRegistry: ProviderRegistry
	) async throws -> QueueFillResult {
		let projects = try context.fetch(FetchDescriptor<Project>())
		guard let project = projects.first(where: { $0.id == projectID }) else {
			throw ProjectCreationError.projectNotFound(projectID)
		}
		let provider = try await providerRegistry.issueTrackerProvider(for: project, context: context)
		return try await queueNextTickets(
			for: project,
			policy: QueueFillPolicy(limit: limit),
			context: context,
			provider: provider
		)
	}

	@discardableResult
	@MainActor
	func queueNextTickets(
		for project: Project,
		limit: Int = 12,
		context: ModelContext,
		provider: any IssueTrackerProvider
	) async throws -> QueueFillResult {
		try await queueNextTickets(
			for: project,
			policy: QueueFillPolicy(limit: limit),
			context: context,
			provider: provider
		)
	}

	@discardableResult
	@MainActor
	func queueNextTickets(
		for project: Project,
		policy: QueueFillPolicy,
		context: ModelContext,
		provider: any IssueTrackerProvider
	) async throws -> QueueFillResult {
		try await ProjectIssueImportService().importTickets(for: project, context: context, provider: provider)
		let queueItems = try context.fetch(FetchDescriptor<QueueItemRecord>())
			.filter { $0.projectID == project.id }
		let queuedTicketIDs = Set(queueItems.map(\.ticketID))
		let remainingCapacity = max(0, min(policy.limit, policy.maxQueueDepth - queueItems.filter(\.isEnabled).count))
		guard remainingCapacity > 0 else {
			return QueueFillResult(queuedCount: 0, skippedCount: 0, alreadyQueuedCount: queueItems.count)
		}
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		for ticket in tickets where queuedTicketIDs.contains(ticket.id) {
			ticket.status = .queued
		}
		let candidates = tickets.filter { ticket in
			ticket.sourceProjectID == project.id
				&& ticket.provider == project.issueProviderKind
				&& queuedTicketIDs.contains(ticket.id) == false
				&& Self.isEligible(ticket, policy: policy)
		}
		.sorted { first, second in
			if first.priority.sortWeight != second.priority.sortWeight {
				return first.priority.sortWeight > second.priority.sortWeight
			}
			return first.updatedAt > second.updatedAt
		}
		let selectedIDs = Array(candidates.prefix(remainingCapacity).map(\.id))
		try QueueService().addTickets(selectedIDs, projectID: project.id, context: context)
		return QueueFillResult(
			queuedCount: selectedIDs.count,
			skippedCount: max(0, candidates.count - selectedIDs.count),
			alreadyQueuedCount: queueItems.count
		)
	}

	private static func isEligible(_ ticket: TicketRecord, policy: QueueFillPolicy) -> Bool {
		switch ticket.status {
		case .backlog, .ready:
			break
		case .queued, .running, .blocked, .needsReview, .completed, .failed, .canceled:
			return false
		}
		if policy.skipsBlockedTickets, ticket.blockedBy.isEmpty == false {
			return false
		}
		let labels = Set(ticket.labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
		return labels.isDisjoint(with: policy.excludedLabels)
	}
}
