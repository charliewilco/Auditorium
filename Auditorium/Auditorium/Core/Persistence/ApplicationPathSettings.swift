import Foundation

enum ApplicationSettingsKeys {
	nonisolated static let runtimeIsolationLevel = "runtimeIsolationLevel"
	nonisolated static let logsDirectoryPath = "logsDirectoryPath"
	nonisolated static let reportsDirectoryPath = "reportsDirectoryPath"
}

enum RuntimeIsolationLevel: String, CaseIterable, Codable, Identifiable, Sendable {
	case mockOnly = "mock-only"
	case localWorkspace = "local-workspace"
	case externalRuntime = "external-runtime"

	var id: String { rawValue }

	var title: String {
		switch self {
		case .mockOnly: "Mock Only"
		case .localWorkspace: "Local Workspace"
		case .externalRuntime: "External Runtime"
		}
	}

	var detail: String {
		switch self {
		case .mockOnly: "Only offline mock runtime runs can start."
		case .localWorkspace: "Mock and Local Workspace runs can start."
		case .externalRuntime: "Any configured runtime can start after its health checks pass."
		}
	}

	func allows(runtimeProviderKind: RuntimeProviderKind) -> Bool {
		switch self {
		case .mockOnly:
			runtimeProviderKind == .mockRuntime
		case .localWorkspace:
			runtimeProviderKind == .mockRuntime || runtimeProviderKind == .localWorkspace
		case .externalRuntime:
			true
		}
	}
}

struct ApplicationPathSettings: Equatable, Sendable {
	let runtimeIsolationLevel: RuntimeIsolationLevel
	let logsDirectoryPath: String
	let reportsDirectoryPath: String

	nonisolated init(
		runtimeIsolationLevel: RuntimeIsolationLevel = .localWorkspace,
		logsDirectoryPath: String = "",
		reportsDirectoryPath: String = ""
	) {
		self.runtimeIsolationLevel = runtimeIsolationLevel
		self.logsDirectoryPath = logsDirectoryPath
		self.reportsDirectoryPath = reportsDirectoryPath
	}

	nonisolated static func load(defaults: UserDefaults = .standard) -> ApplicationPathSettings {
		ApplicationPathSettings(
			runtimeIsolationLevel: RuntimeIsolationLevel(
				rawValue: defaults.string(forKey: ApplicationSettingsKeys.runtimeIsolationLevel) ?? ""
			) ?? .localWorkspace,
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
