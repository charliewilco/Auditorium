import Foundation
import SwiftData

enum AppSchema {
	enum V1: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 0, 0)
		}

		static var models: [any PersistentModel.Type] {
			legacyModelTypes
		}
	}

	enum V2: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 1, 0)
		}

		static var models: [any PersistentModel.Type] {
			legacyModelTypes
		}
	}

	enum V3: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 2, 0)
		}

		static var models: [any PersistentModel.Type] {
			legacyModelTypes
		}
	}

	enum V4: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 3, 0)
		}

		static var models: [any PersistentModel.Type] {
			legacyModelTypes
		}
	}

	enum V5: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 4, 0)
		}

		static var models: [any PersistentModel.Type] {
			legacyModelTypes
		}
	}

	enum V6: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 5, 0)
		}

		static var models: [any PersistentModel.Type] {
			legacyModelTypes
		}
	}

	enum V7: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 6, 0)
		}

		static var models: [any PersistentModel.Type] {
			legacyModelTypes
		}
	}

	enum V8: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 7, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypesV8
		}
	}

	enum V9: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 8, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypesV11
		}
	}

	enum V10: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 9, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypesV11
		}
	}

	enum V11: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 10, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypesV11
		}
	}

	enum V12: VersionedSchema {
		static var versionIdentifier: Schema.Version {
			Schema.Version(1, 11, 0)
		}

		static var models: [any PersistentModel.Type] {
			modelTypes
		}
	}

	enum MigrationPlan: SchemaMigrationPlan {
		static var schemas: [any VersionedSchema.Type] {
			[V7.self, V8.self, V9.self, V10.self, V11.self, V12.self]
		}

		static var stages: [MigrationStage] {
			[
				.lightweight(fromVersion: V7.self, toVersion: V8.self),
				.lightweight(fromVersion: V8.self, toVersion: V9.self),
				.lightweight(fromVersion: V9.self, toVersion: V10.self),
				.lightweight(fromVersion: V10.self, toVersion: V11.self),
				.lightweight(fromVersion: V11.self, toVersion: V12.self),
			]
		}
	}

	static let legacyModelTypes: [any PersistentModel.Type] = [
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

	static let modelTypesV8: [any PersistentModel.Type] =
		legacyModelTypes + [
			TicketReportBackRecord.self
		]

	static let modelTypesV11: [any PersistentModel.Type] =
		modelTypesV8 + [
			ContainerRunRecord.self
		]

	static let modelTypes: [any PersistentModel.Type] =
		modelTypesV11 + [
			DispatcherRunRecord.self
		]

	static var currentSchema: Schema {
		Schema(versionedSchema: V12.self)
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
