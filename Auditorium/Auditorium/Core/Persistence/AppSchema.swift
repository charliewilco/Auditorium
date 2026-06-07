import Foundation
import SwiftData

enum AppSchema {
	enum V1: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 0, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypes
		}
	}

	enum V2: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 1, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypes
		}
	}

	enum V3: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 2, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypes
		}
	}

	enum V4: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 3, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypes
		}
	}

	enum V5: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 4, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypes
		}
	}

	enum V6: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 5, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypes
		}
	}

	enum V7: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 6, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypes
		}
	}

	enum MigrationPlan: SchemaMigrationPlan {
		static var schemas: [any VersionedSchema.Type] {
			[V1.self, V2.self, V3.self, V4.self, V5.self, V6.self, V7.self]
		}

		static var stages: [MigrationStage] {
			[
				.lightweight(fromVersion: V1.self, toVersion: V2.self),
				.lightweight(fromVersion: V2.self, toVersion: V3.self),
				.lightweight(fromVersion: V3.self, toVersion: V4.self),
				.lightweight(fromVersion: V4.self, toVersion: V5.self),
				.lightweight(fromVersion: V5.self, toVersion: V6.self),
				.lightweight(fromVersion: V6.self, toVersion: V7.self),
			]
		}
	}

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
		CoordinationMessageRecord.self,
		ReportRecord.self,
		ProviderAccountRecord.self,
		ProjectEnvironmentSecretRecord.self,
	]

	static var currentSchema: Schema {
		Schema(versionedSchema: V7.self)
	}

	static func makeModelContainer(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
		let configuration: ModelConfiguration
		if let storeURL {
			configuration = ModelConfiguration(schema: currentSchema, url: storeURL, cloudKitDatabase: .none)
		}
		else {
			configuration = ModelConfiguration(schema: currentSchema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
		}
		return try ModelContainer(for: currentSchema, migrationPlan: MigrationPlan.self, configurations: [configuration])
	}
}
