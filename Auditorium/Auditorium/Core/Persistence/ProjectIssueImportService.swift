import Foundation
import SwiftData

@MainActor
struct ProjectIssueImportService {
	@discardableResult
	func importTickets(
		for project: Project,
		context: ModelContext,
		provider: any IssueTrackerProvider
	) async throws -> Int {
		let descriptors = try await provider.listTickets(projectID: project.repositoryName)
		let existingTickets = try context.fetch(FetchDescriptor<TicketRecord>())
			.filter { $0.sourceProjectID == project.id && $0.provider == project.issueProviderKind }
		var ticketsByExternalID = Dictionary(uniqueKeysWithValues: existingTickets.map { ($0.externalID, $0) })
		var importedCount = 0

		for descriptor in descriptors {
			if let ticket = ticketsByExternalID[descriptor.externalID] {
				ticket.title = descriptor.title
				ticket.body = descriptor.body
				ticket.status = descriptor.status
				ticket.labels = descriptor.labels
				ticket.assignee = descriptor.assignee
				ticket.priority = descriptor.priority
				ticket.webURL = descriptor.webURL?.absoluteString ?? ""
				ticket.createdAt = descriptor.createdAt
				ticket.updatedAt = descriptor.updatedAt
				ticket.estimatedComplexity = descriptor.estimatedComplexity
				ticket.blockedBy = descriptor.blockedBy
			} else {
				let ticket = TicketRecord(
					provider: descriptor.provider,
					externalID: descriptor.externalID,
					title: descriptor.title,
					body: descriptor.body,
					status: descriptor.status,
					labels: descriptor.labels,
					assignee: descriptor.assignee,
					priority: descriptor.priority,
					webURL: descriptor.webURL?.absoluteString ?? "",
					createdAt: descriptor.createdAt,
					updatedAt: descriptor.updatedAt,
					estimatedComplexity: descriptor.estimatedComplexity,
					blockedBy: descriptor.blockedBy,
					sourceProjectID: project.id
				)
				context.insert(ticket)
				ticketsByExternalID[descriptor.externalID] = ticket
			}
			importedCount += 1
		}

		try ModelIntegrityValidator.save(context: context)
		return importedCount
	}

	@discardableResult
	func importTickets(projectID: UUID, context: ModelContext, providerRegistry: ProviderRegistry) async throws -> Int {
		let projects = try context.fetch(FetchDescriptor<Project>())
		guard let project = projects.first(where: { $0.id == projectID }) else {
			throw ProjectCreationError.projectNotFound(projectID)
		}
		let provider = try providerRegistry.issueTrackerProvider(for: project, context: context)
		return try await importTickets(for: project, context: context, provider: provider)
	}
}
