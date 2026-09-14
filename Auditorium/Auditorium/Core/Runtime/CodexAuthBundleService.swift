import Foundation

enum CodexAuthBundleError: LocalizedError, Equatable {
	case unauthenticated(String)
	case missingAuthFile(String)

	var errorDescription: String? {
		switch self {
		case .unauthenticated(let detail):
			"Codex CLI authentication is not available on the launching machine: \(detail)"
		case .missingAuthFile(let path):
			"Codex authentication file was not found at \(path). Run Codex login before starting a containerized run."
		}
	}
}

struct CodexAuthBundle: Sendable {
	let directory: URL
}

struct CodexAuthBundleService: Sendable {
	let sourceCodexHome: URL
	let temporaryRoot: URL
	let statusValidator: @Sendable () async throws -> Void

	init(
		sourceCodexHome: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".codex"),
		temporaryRoot: URL = FileManager.default.temporaryDirectory,
		statusValidator: (@Sendable () async throws -> Void)? = nil
	) {
		self.sourceCodexHome = sourceCodexHome
		self.temporaryRoot = temporaryRoot
		self.statusValidator = statusValidator ?? { try await Self.defaultStatusValidator() }
	}

	nonisolated func createBundle() async throws -> CodexAuthBundle {
		try await statusValidator()
		let sourceAuth = sourceCodexHome.appending(path: "auth.json")
		guard FileManager.default.fileExists(atPath: sourceAuth.path()) else {
			throw CodexAuthBundleError.missingAuthFile(sourceAuth.path())
		}

		let bundleDirectory =
			temporaryRoot
			.appending(path: "auditorium-codex-auth-\(UUID().uuidString)")
			.appending(path: ".codex")
		try FileManager.default.createDirectory(
			at: bundleDirectory,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let destinationAuth = bundleDirectory.appending(path: "auth.json")
		try FileManager.default.copyItem(at: sourceAuth, to: destinationAuth)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationAuth.path())
		return CodexAuthBundle(directory: bundleDirectory)
	}

	nonisolated func cleanUp(_ bundle: CodexAuthBundle?) {
		guard let bundle else { return }
		try? FileManager.default.removeItem(at: bundle.directory.deletingLastPathComponent())
	}

	nonisolated private static func defaultStatusValidator() async throws {
		let result = try await ProcessCommand.runStreaming(
			executable: "/usr/bin/env",
			arguments: ["codex", "login", "status"],
			allowsNonZeroExit: true
		)
		guard result.exitCode == 0 else {
			let detail = result.standardError.isEmpty ? result.standardOutput : result.standardError
			throw CodexAuthBundleError.unauthenticated(
				detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "codex login status failed." : detail
			)
		}
	}
}
