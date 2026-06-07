import Foundation

enum GenericCLIAgentConfigurationError: LocalizedError, Equatable {
	case emptyCommand
	case unterminatedQuote

	var errorDescription: String? {
		switch self {
		case .emptyCommand:
			"Generic CLI agent command must not be empty."
		case .unterminatedQuote:
			"Generic CLI agent command contains an unterminated quote."
		}
	}
}

struct GenericCLIAgentConfiguration: Equatable, Sendable {
	let commandLine: String
	let executablePath: String
	let arguments: [String]

	init(commandLine: String) throws {
		let tokens = try Self.tokens(from: commandLine)
		guard let executable = tokens.first else {
			throw GenericCLIAgentConfigurationError.emptyCommand
		}
		self.commandLine = commandLine
		if executable.contains("/") {
			self.executablePath = executable
			self.arguments = Array(tokens.dropFirst())
		}
		else {
			self.executablePath = "/usr/bin/env"
			self.arguments = tokens
		}
	}

	func arguments(prompt: String) -> [String] {
		arguments + [prompt]
	}

	private static func tokens(from commandLine: String) throws -> [String] {
		var tokens: [String] = []
		var current = ""
		var quote: Character?
		var isEscaped = false

		for character in commandLine {
			if isEscaped {
				current.append(character)
				isEscaped = false
				continue
			}
			if character == "\\" {
				isEscaped = true
				continue
			}
			if let activeQuote = quote {
				if character == activeQuote {
					quote = nil
				}
				else {
					current.append(character)
				}
				continue
			}
			if character == "\"" || character == "'" {
				quote = character
				continue
			}
			if character.isWhitespace {
				if current.isEmpty == false {
					tokens.append(current)
					current = ""
				}
				continue
			}
			current.append(character)
		}

		if isEscaped {
			current.append("\\")
		}
		if quote != nil {
			throw GenericCLIAgentConfigurationError.unterminatedQuote
		}
		if current.isEmpty == false {
			tokens.append(current)
		}
		return tokens
	}
}

struct GenericShellAgentProvider: AgentProvider {
	let configuration: GenericCLIAgentConfiguration

	init(configuration: GenericCLIAgentConfiguration) {
		self.configuration = configuration
	}

	init(commandLine: String) throws {
		self.configuration = try GenericCLIAgentConfiguration(commandLine: commandLine)
	}

	func runAgent(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					continuation.yield(
						AgentEvent(level: .info, category: .agent, message: "generic_cli_started", summary: nil, outcome: nil)
					)
					let result = try await ProcessCommand.runStreaming(
						executable: configuration.executablePath,
						arguments: configuration.arguments(prompt: prompt(for: request)),
						workingDirectory: request.workspace.path,
						onStandardOutputLine: { line in
							continuation.yield(
								AgentEvent(
									level: .info,
									category: .agent,
									message: "generic_cli_stdout: \(line)",
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
									message: "generic_cli_stderr: \(line)",
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
		let logURL = logDirectory.appending(path: "generic-cli.log")
		let log = """
			# Generic CLI Agent Log

			Command: \(configuration.commandLine)
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
				message: "generic_cli_completed",
				summary: "Generic CLI agent completed successfully.",
				outcome: .completed,
				logPath: logURL.path()
			)
		}
		return AgentEvent(
			level: .error,
			category: .agent,
			message: "generic_cli_failed",
			summary: "Generic CLI agent exited with status \(result.exitCode).",
			outcome: .failed,
			logPath: logURL.path()
		)
	}
}
