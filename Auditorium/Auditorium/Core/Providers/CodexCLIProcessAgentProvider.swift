import Foundation

struct CodexCLIProcessAgentProvider: AgentProvider {
	let executablePath: String
	let arguments: [String]

	init(
		executablePath: String = "/usr/bin/env",
		arguments: [String] = ["codex", "exec", "--json", "--sandbox", "workspace-write", "-c", "approval_policy=never"]
	) {
		self.executablePath = executablePath
		self.arguments = arguments
	}

	func runAgent(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					continuation.yield(
						AgentEvent(level: .info, category: .agent, message: "codex_started", summary: nil, outcome: nil)
					)
					let result = try await ProcessCommand.runStreaming(
						executable: executablePath,
						arguments: arguments + [prompt(for: request)],
						workingDirectory: request.workspace.path,
						onStandardOutputLine: { line in
							continuation.yield(
								AgentEvent(
									level: .info,
									category: .agent,
									message: "codex_stdout: \(line)",
									summary: nil,
									outcome: nil
								)
							)
						},
						onStandardErrorLine: { line in
							continuation.yield(
								AgentEvent(
									level: .warning,
									category: .agent,
									message: "codex_stderr: \(line)",
									summary: nil,
									outcome: nil
								)
							)
						},
						allowsNonZeroExit: true
					)
					let logURL = try writeLog(result, workspacePath: request.workspace.path)
					continuation.yield(Self.finalEvent(result: result, logURL: logURL))
					continuation.finish()
				}
				catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in
				task.cancel()
			}
		}
	}

	private func prompt(for request: AgentRunRequest) -> String {
		"""
		You are working in \(request.repository.fullName) on issue \(request.ticket.externalID): \(request.ticket.title).

		Issue body:
		\(request.ticket.body)

		Workflow policy:
		\(request.policyMarkdown)
		"""
	}

	private func writeLog(_ result: ProcessResult, workspacePath: URL) throws -> URL {
		let logDirectory = workspacePath.appending(path: ".auditorium")
		try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
		let logURL = logDirectory.appending(path: "codex.log")
		let log = """
			# Codex CLI Log

			Exit code: \(result.exitCode)

			## stdout
			\(result.standardOutput)

			## stderr
			\(result.standardError)
			"""
		try log.write(to: logURL, atomically: true, encoding: .utf8)
		return logURL
	}

	private static func finalEvent(result: ProcessResult, logURL: URL) -> AgentEvent {
		if result.exitCode == 0 {
			return AgentEvent(
				level: .success,
				category: .agent,
				message: "codex_completed",
				summary: "Codex CLI completed successfully.",
				outcome: .completed,
				logPath: logURL.path()
			)
		}
		return AgentEvent(
			level: .error,
			category: .agent,
			message: "codex_failed",
			summary: "Codex CLI exited with status \(result.exitCode).",
			outcome: .failed,
			logPath: logURL.path()
		)
	}
}

typealias CodexAgentProvider = CodexCLIProcessAgentProvider
