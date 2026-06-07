import Foundation
import SwiftData

enum AppSchema {
	static let modelTypes: [any PersistentModel.Type] = [
		Project.self,
		RepositoryRecord.self,
		IssueTrackerRecord.self,
		TicketRecord.self,
		QueueItemRecord.self,
		RunRecord.self,
		TicketRunRecord.self,
		PullRequestRecord.self,
		RuntimeEventRecord.self,
		ReportRecord.self,
		ProviderAccountRecord.self
	]

	static func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
		let schema = Schema(modelTypes)
		let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
		return try ModelContainer(for: schema, configurations: [configuration])
	}
}
