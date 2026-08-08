import Foundation

enum GitHubCLIAuthenticationError: LocalizedError, Equatable {
	case missingToken

	var errorDescription: String? {
		switch self {
		case .missingToken:
			"GitHub authentication completed, but GitHub CLI did not return an access token."
		}
	}
}

struct GitHubCLICommandResult: Sendable, Equatable {
	let exitCode: Int32
	let standardOutput: String
	let standardError: String
}

struct GitHubCLIAuthenticationService: Sendable {
	typealias CommandRunner = @Sendable (_ arguments: [String], _ allowsNonZeroExit: Bool) async throws -> GitHubCLICommandResult

	private let commandRunner: CommandRunner

	init(commandRunner: CommandRunner? = nil) {
		self.commandRunner =
			commandRunner
			?? { arguments, allowsNonZeroExit in
				let result = try await ProcessCommand.runStreaming(
					executable: "gh",
					arguments: arguments,
					allowsNonZeroExit: allowsNonZeroExit
				)
				return GitHubCLICommandResult(
					exitCode: result.exitCode,
					standardOutput: result.standardOutput,
					standardError: result.standardError
				)
			}
	}

	func authenticate() async throws -> String {
		if let token = try await currentToken() {
			return token
		}

		let protocolResult = try await commandRunner(
			["config", "get", "git_protocol", "--host", "github.com"],
			true
		)
		let configuredProtocol = protocolResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
		let gitProtocol = configuredProtocol == "ssh" ? "ssh" : "https"
		_ = try await commandRunner(
			[
				"auth", "login",
				"--hostname", "github.com",
				"--git-protocol", gitProtocol,
				"--web",
				"--clipboard",
				"--scopes", "repo,read:user",
				"--skip-ssh-key",
			],
			false
		)

		guard let token = try await currentToken() else {
			throw GitHubCLIAuthenticationError.missingToken
		}
		return token
	}

	private func currentToken() async throws -> String? {
		let result = try await commandRunner(["auth", "token", "--hostname", "github.com"], true)
		guard result.exitCode == 0 else { return nil }
		let token = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
		return token.isEmpty ? nil : token
	}
}
