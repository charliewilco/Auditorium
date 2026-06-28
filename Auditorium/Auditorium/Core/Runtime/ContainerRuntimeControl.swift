import Foundation

struct ContainerRuntimeControl: Sendable {
	typealias AsyncCommandRunner =
		@Sendable (_ executable: String, _ arguments: [String], _ allowsNonZeroExit: Bool) async throws ->
		ProcessResult
	typealias BlockingCommandRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> ProcessResult

	let executablePath: String
	private let asyncCommandRunner: AsyncCommandRunner
	private let blockingCommandRunner: BlockingCommandRunner

	nonisolated init(
		executablePath: String = "/usr/bin/env",
		asyncCommandRunner: @escaping AsyncCommandRunner = { executable, arguments, allowsNonZeroExit in
			try await ProcessCommand.runStreaming(
				executable: executable,
				arguments: arguments,
				allowsNonZeroExit: allowsNonZeroExit
			)
		},
		blockingCommandRunner: @escaping BlockingCommandRunner = { executable, arguments in
			try ProcessCommand.runBlocking(executable: executable, arguments: arguments)
		}
	) {
		self.executablePath = executablePath
		self.asyncCommandRunner = asyncCommandRunner
		self.blockingCommandRunner = blockingCommandRunner
	}

	nonisolated func killContainer(named name: String) async -> ContainerRuntimeCommandResult {
		let executablePath = executablePath
		let asyncCommandRunner = asyncCommandRunner
		return await Task.detached {
			do {
				let result = try await asyncCommandRunner(executablePath, Self.killArguments(for: name), true)
				return ContainerRuntimeCommandResult(result: result, failureReason: nil)
			}
			catch {
				return ContainerRuntimeCommandResult(result: nil, failureReason: error.localizedDescription)
			}
		}.value
	}

	nonisolated func killContainerBlocking(named name: String) -> ContainerRuntimeCommandResult {
		do {
			let result = try blockingCommandRunner(executablePath, Self.killArguments(for: name))
			return ContainerRuntimeCommandResult(result: result, failureReason: nil)
		}
		catch {
			return ContainerRuntimeCommandResult(result: nil, failureReason: error.localizedDescription)
		}
	}

	nonisolated func inspectContainerBlocking(named name: String) -> Bool {
		(try? blockingCommandRunner(executablePath, Self.inspectArguments(for: name)))?.exitCode == 0
	}

	nonisolated func imageExists(named imageName: String) async throws -> Bool {
		let result = try await asyncCommandRunner(executablePath, Self.imageInspectArguments(for: imageName), true)
		return result.exitCode == 0
	}

	@discardableResult
	nonisolated func buildImage(named imageName: String, context: URL) async throws -> ProcessResult {
		try await asyncCommandRunner(executablePath, Self.imageBuildArguments(imageName: imageName, context: context), false)
	}

	nonisolated static func containerName(for workspace: WorkspaceDescriptor) -> String {
		containerName(forRuntimeID: workspace.runtimeID)
	}

	nonisolated static func containerName(forRuntimeID runtimeID: String) -> String {
		let safeID =
			runtimeID
			.lowercased()
			.map { character in
				character.isLetter || character.isNumber || character == "-" ? character : "-"
			}
		return "auditorium-\(String(safeID))"
	}

	nonisolated static func killArguments(for containerName: String) -> [String] {
		["container", "kill", containerName]
	}

	nonisolated static func inspectArguments(for containerName: String) -> [String] {
		["container", "inspect", containerName]
	}

	nonisolated static func imageInspectArguments(for imageName: String) -> [String] {
		["container", "image", "inspect", imageName]
	}

	nonisolated static func imageBuildArguments(imageName: String, context: URL) -> [String] {
		["container", "build", "--tag", imageName, context.path()]
	}
}

struct ContainerRuntimeCommandResult: Sendable {
	let result: ProcessResult?
	let failureReason: String?
}
