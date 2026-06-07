import Foundation

enum ApplicationSettingsKeys {
	nonisolated static let logsDirectoryPath = "logsDirectoryPath"
	nonisolated static let reportsDirectoryPath = "reportsDirectoryPath"
}

struct ApplicationPathSettings: Equatable, Sendable {
	let logsDirectoryPath: String
	let reportsDirectoryPath: String

	nonisolated init(
		logsDirectoryPath: String = "",
		reportsDirectoryPath: String = ""
	) {
		self.logsDirectoryPath = logsDirectoryPath
		self.reportsDirectoryPath = reportsDirectoryPath
	}

	nonisolated static func load(defaults: UserDefaults = .standard) -> ApplicationPathSettings {
		ApplicationPathSettings(
			logsDirectoryPath: defaults.string(forKey: ApplicationSettingsKeys.logsDirectoryPath) ?? "",
			reportsDirectoryPath: defaults.string(forKey: ApplicationSettingsKeys.reportsDirectoryPath) ?? ""
		)
	}

	func logsDirectory(defaultDirectory: URL, projectID: UUID) -> URL {
		if let customRoot = directoryURL(from: logsDirectoryPath) {
			return customRoot.appending(path: projectID.uuidString)
		}
		return defaultDirectory
	}

	func reportsDirectory(defaultDirectory: URL, projectID: UUID) -> URL {
		if let customRoot = directoryURL(from: reportsDirectoryPath) {
			return customRoot.appending(path: projectID.uuidString)
		}
		return defaultDirectory
	}

	private func directoryURL(from path: String) -> URL? {
		let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.isEmpty == false else { return nil }
		return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath, isDirectory: true)
	}
}
