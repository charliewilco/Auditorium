import Foundation
import SwiftData

enum ProjectEnvironmentSecretError: LocalizedError, Equatable {
	case invalidName(String)
	case missingSecret(String)

	var errorDescription: String? {
		switch self {
		case .invalidName(let name):
			"Runtime environment variable name '\(name)' is invalid. Use uppercase letters, digits, and underscores, starting with a letter or underscore."
		case .missingSecret(let name):
			"Runtime environment secret \(name) is missing from Keychain. Replace or delete it before running this project."
		}
	}
}

struct ProjectEnvironmentSecretService {
	let keychain: KeychainService

	init(keychain: KeychainService = KeychainService()) {
		self.keychain = keychain
	}

	static func normalizedName(_ name: String) -> String {
		name.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func isValidName(_ name: String) -> Bool {
		normalizedName(name).range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil
	}

	static func keychainAccount(projectID: UUID, name: String) -> String {
		"\(projectID.uuidString)-env-\(normalizedName(name))"
	}

	@discardableResult
	@MainActor
	func upsertSecret(projectID: UUID, name rawName: String, value: String, isEnabled: Bool = true, context: ModelContext) throws
		-> ProjectEnvironmentSecretRecord
	{
		let name = try validateName(rawName)
		let account = Self.keychainAccount(projectID: projectID, name: name)
		try keychain.storeSecret(value, account: account)
		let records = try context.fetch(FetchDescriptor<ProjectEnvironmentSecretRecord>())
		if let existing = records.first(where: { $0.projectID == projectID && $0.name == name }) {
			existing.keychainAccount = account
			existing.isEnabled = isEnabled
			existing.updatedAt = .now
			try ModelIntegrityValidator.save(context: context)
			return existing
		}
		let record = ProjectEnvironmentSecretRecord(
			projectID: projectID,
			name: name,
			keychainAccount: account,
			isEnabled: isEnabled
		)
		context.insert(record)
		try ModelIntegrityValidator.save(context: context)
		return record
	}

	@MainActor
	func setEnabled(_ isEnabled: Bool, record: ProjectEnvironmentSecretRecord, context: ModelContext) throws {
		record.isEnabled = isEnabled
		record.updatedAt = .now
		try ModelIntegrityValidator.save(context: context)
	}

	@MainActor
	func deleteSecret(_ record: ProjectEnvironmentSecretRecord, context: ModelContext) throws {
		try keychain.deleteSecret(account: record.keychainAccount)
		context.delete(record)
		try ModelIntegrityValidator.save(context: context)
	}

	@MainActor
	func resolveEnabledEnvironment(projectID: UUID, context: ModelContext) throws -> [String: String] {
		let records = try context.fetch(FetchDescriptor<ProjectEnvironmentSecretRecord>())
			.filter { $0.projectID == projectID && $0.isEnabled }
			.sorted { $0.name < $1.name }
		var environment: [String: String] = [:]
		for record in records {
			let name = try validateName(record.name)
			guard let value = try keychain.readSecret(account: record.keychainAccount) else {
				throw ProjectEnvironmentSecretError.missingSecret(name)
			}
			environment[name] = value
		}
		return environment
	}

	private func validateName(_ rawName: String) throws -> String {
		let name = Self.normalizedName(rawName)
		guard Self.isValidName(name) else {
			throw ProjectEnvironmentSecretError.invalidName(rawName)
		}
		return name
	}
}
