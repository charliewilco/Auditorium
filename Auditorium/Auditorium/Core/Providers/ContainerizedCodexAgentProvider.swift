import Darwin
import Foundation

struct ContainerizedCodexAgentConfiguration: Sendable {
	let containerExecutablePath: String
	let imageName: String
	let workspaceMountPath: String
	let codexHomeMountPath: String
	let hostUserID: String
	let hostGroupID: String
	let codexArguments: [String]
	let imageBuildContext: URL?
	let buildsImageIfMissing: Bool

	init(
		containerExecutablePath: String = "/usr/bin/env",
		imageName: String = "localhost/auditorium-codex:latest",
		workspaceMountPath: String = "/workspace",
		codexHomeMountPath: String = "/home/auditorium/.codex",
		hostUserID: String = String(getuid()),
		hostGroupID: String = String(getgid()),
		imageBuildContext: URL? = Self.defaultImageBuildContext(),
		buildsImageIfMissing: Bool = true,
		codexArguments: [String] = [
			"codex",
			"exec",
			"--json",
			"--sandbox",
			"workspace-write",
			"-c",
			"approval_policy=never",
			"--ignore-user-config",
		]
	) {
		self.containerExecutablePath = containerExecutablePath
		self.imageName = imageName
		self.workspaceMountPath = workspaceMountPath
		self.codexHomeMountPath = codexHomeMountPath
		self.hostUserID = hostUserID
		self.hostGroupID = hostGroupID
		self.codexArguments = codexArguments
		self.imageBuildContext = imageBuildContext
		self.buildsImageIfMissing = buildsImageIfMissing
	}

	nonisolated private static func defaultImageBuildContext() -> URL? {
		let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
		for candidate in [
			currentDirectory.appending(path: "containers/codex"),
			currentDirectory.appending(path: "Auditorium/Auditorium/Resources/containers/codex"),
			Bundle.main.resourceURL?.appending(path: "containers/codex"),
			Bundle.main.resourceURL,
		].compactMap({ $0 }) {
			if FileManager.default.fileExists(atPath: candidate.appending(path: "Containerfile").path()) {
				return candidate
			}
		}
		return nil
	}
}

struct ContainerizedCodexAgentProvider: AgentProvider, Sendable {
	let configuration: ContainerizedCodexAgentConfiguration
	let authBundleService: CodexAuthBundleService

	init(
		configuration: ContainerizedCodexAgentConfiguration = ContainerizedCodexAgentConfiguration(),
		authBundleService: CodexAuthBundleService = CodexAuthBundleService()
	) {
		self.configuration = configuration
		self.authBundleService = authBundleService
	}

	func runAgent(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
		AsyncThrowingStream { continuation in
			let cancellationToken = ProcessCancellationToken()
			let containerName = Self.containerName(for: request.workspace)
			let task = Task.detached {
				var authBundle: CodexAuthBundle?
				defer {
					authBundleService.cleanUp(authBundle)
				}

				do {
					continuation.yield(
						AgentEvent(
							level: .info,
							category: .agent,
							message: "container_codex_started",
							summary: nil,
							outcome: nil
						)
					)
					try await Self.ensureImage(configuration: configuration)
					authBundle = try await authBundleService.createBundle()
					let arguments = Self.containerRunArguments(
						configuration: configuration,
						request: request,
						authBundle: try Self.requireAuthBundle(authBundle),
						containerName: containerName
					)
					let result = try await ProcessCommand.runStreaming(
						executable: configuration.containerExecutablePath,
						arguments: arguments,
						workingDirectory: request.workspace.path,
						environment: request.environment,
						cancellationToken: cancellationToken,
						onStandardOutputLine: { line in
							continuation.yield(
								AgentEvent(
									level: .info,
									category: .agent,
									message: "container_codex_stdout: \(line)",
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
									message: "container_codex_stderr: \(line)",
									summary: nil,
									outcome: nil
								)
							)
						},
						allowsNonZeroExit: true
					)
					let logURL = try Self.writeLog(result, workspacePath: request.workspace.path)
					continuation.yield(Self.finalEvent(result: result, logURL: logURL))
					continuation.finish()
				}
				catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in
				cancellationToken.cancel()
				task.cancel()
				Task.detached {
					await Self.killContainer(named: containerName, configuration: configuration)
				}
			}
		}
	}

	nonisolated static func containerRunArguments(
		configuration: ContainerizedCodexAgentConfiguration,
		request: AgentRunRequest,
		authBundle: CodexAuthBundle,
		containerName: String
	) -> [String] {
		var arguments = [
			"container",
			"run",
			"--rm",
			"--init",
			"--name",
			containerName,
			"--uid",
			configuration.hostUserID,
			"--gid",
			configuration.hostGroupID,
			"--mount",
			"type=bind,source=\(request.workspace.path.path()),target=\(configuration.workspaceMountPath)",
			"--mount",
			"type=bind,source=\(authBundle.directory.path()),target=\(configuration.codexHomeMountPath),readonly",
			"--workdir",
			configuration.workspaceMountPath,
			"--env",
			"CODEX_HOME=\(configuration.codexHomeMountPath)",
			"--env",
			"HOME=/home/auditorium",
		]
		for name in request.environment.keys.sorted() where isValidEnvironmentName(name) {
			arguments.append(contentsOf: ["--env", name])
		}
		arguments.append(configuration.imageName)
		arguments.append(contentsOf: configuration.codexArguments)
		arguments.append(contentsOf: ["--cd", configuration.workspaceMountPath])
		arguments.append(prompt(for: request))
		return arguments
	}

	nonisolated private static func containerName(for workspace: WorkspaceDescriptor) -> String {
		let safeID = workspace.runtimeID
			.lowercased()
			.map { character in
				character.isLetter || character.isNumber || character == "-" ? character : "-"
			}
		return "auditorium-\(String(safeID))"
	}

	nonisolated private static func isValidEnvironmentName(_ name: String) -> Bool {
		name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
	}

	nonisolated private static func prompt(for request: AgentRunRequest) -> String {
		"""
		You are working in \(request.repository.fullName) on issue \(request.ticket.externalID): \(request.ticket.title).

		Issue body:
		\(request.ticket.body)

		Workflow policy:
		\(request.policyMarkdown)
		"""
	}

	nonisolated private static func requireAuthBundle(_ bundle: CodexAuthBundle?) throws -> CodexAuthBundle {
		guard let bundle else {
			throw ProviderError.unavailable("Codex authentication bundle was not created.")
		}
		return bundle
	}

	nonisolated private static func writeLog(_ result: ProcessResult, workspacePath: URL) throws -> URL {
		let logDirectory = workspacePath.appending(path: ".auditorium")
		try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
		let logURL = logDirectory.appending(path: "container-codex.log")
		let log = """
			# Containerized Codex CLI Log

			Exit code: \(result.exitCode)

			## stdout
			\(result.standardOutput)

			## stderr
			\(result.standardError)
			"""
		try log.write(to: logURL, atomically: true, encoding: .utf8)
		return logURL
	}

	nonisolated private static func finalEvent(result: ProcessResult, logURL: URL) -> AgentEvent {
		if result.exitCode == 0 {
			return AgentEvent(
				level: .success,
				category: .agent,
				message: "container_codex_completed",
				summary: "Containerized Codex CLI completed successfully.",
				outcome: .completed,
				logPath: logURL.path()
			)
		}
		return AgentEvent(
			level: .error,
			category: .agent,
			message: "container_codex_failed",
			summary: "Containerized Codex CLI exited with status \(result.exitCode).",
			outcome: .failed,
			logPath: logURL.path()
		)
	}

	nonisolated private static func killContainer(named name: String, configuration: ContainerizedCodexAgentConfiguration) async {
		_ = try? await ProcessCommand.runStreaming(
			executable: configuration.containerExecutablePath,
			arguments: ["container", "kill", name],
			allowsNonZeroExit: true
		)
	}

	nonisolated private static func ensureImage(configuration: ContainerizedCodexAgentConfiguration) async throws {
		let inspect = try await ProcessCommand.runStreaming(
			executable: configuration.containerExecutablePath,
			arguments: ["container", "image", "inspect", configuration.imageName],
			allowsNonZeroExit: true
		)
		if inspect.exitCode == 0 {
			return
		}
		guard configuration.buildsImageIfMissing,
			let imageBuildContext = configuration.imageBuildContext,
			FileManager.default.fileExists(atPath: imageBuildContext.appending(path: "Containerfile").path())
		else {
			throw ProviderError.unavailable(
				"Container image \(configuration.imageName) was not found. Build it with: container build --tag \(configuration.imageName) Auditorium/Auditorium/Resources/containers/codex"
			)
		}
		_ = try await ProcessCommand.runStreaming(
			executable: configuration.containerExecutablePath,
			arguments: ["container", "build", "--tag", configuration.imageName, imageBuildContext.path()]
		)
	}
}
