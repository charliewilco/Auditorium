import Foundation

struct ContainerWorkspaceRuntimeProvider: RuntimeProvider {
	let workspaceService: ApplicationWorkspaceService
	let projectID: UUID
	let sourceProvider: any SourceCodeProvider
	let branchPrefix: String
	let containerControl: ContainerRuntimeControl

	init(
		workspaceService: ApplicationWorkspaceService,
		projectID: UUID,
		sourceProvider: any SourceCodeProvider,
		branchPrefix: String = "auditorium",
		containerControl: ContainerRuntimeControl = ContainerRuntimeControl()
	) {
		self.workspaceService = workspaceService
		self.projectID = projectID
		self.sourceProvider = sourceProvider
		self.branchPrefix = branchPrefix
		self.containerControl = containerControl
	}

	func prepareWorkspace(for ticket: TicketDescriptor, repository: RepositoryDescriptor) async throws -> WorkspaceDescriptor {
		try Task.checkCancellation()
		try workspaceService.ensureProjectLayout(projectID: projectID)
		let workspace = workspaceService.workspacePath(projectID: projectID, ticketExternalID: ticket.externalID)
		try FileManager.default.createDirectory(at: workspace.deletingLastPathComponent(), withIntermediateDirectories: true)
		try await sourceProvider.cloneOrUpdate(repository: repository, into: workspace)
		try Task.checkCancellation()
		let branchName = sourceProvider.ticketBranchName(for: ticket, prefix: branchPrefix)
		try await sourceProvider.createBranch(named: branchName, in: workspace)
		try FileManager.default.createDirectory(at: metadataDirectory(for: workspace), withIntermediateDirectories: true)
		return WorkspaceDescriptor(
			path: workspace,
			runtimeID: "container-\(workspaceService.sanitize(ticket.externalID))",
			branchName: branchName
		)
	}

	func startExecution(_ request: RuntimeExecutionRequest) async throws -> RuntimeExecutionHandle {
		try Task.checkCancellation()
		guard FileManager.default.fileExists(atPath: request.workspace.path.path()) else {
			throw ProviderError.unavailable("Container workspace does not exist at \(request.workspace.path.path()).")
		}
		let handle = RuntimeExecutionHandle(id: request.workspace.runtimeID, workspacePath: request.workspace.path)
		let metadata = ContainerRuntimeHandleMetadata(
			id: handle.id,
			workspacePath: handle.workspacePath.path(),
			branchName: request.workspace.branchName,
			ticketExternalID: request.ticket.externalID,
			injectedVariableCount: request.environment.count,
			startedAt: .now
		)
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let data = try encoder.encode(metadata)
		try FileManager.default.createDirectory(at: metadataDirectory(for: request.workspace.path), withIntermediateDirectories: true)
		try data.write(to: runtimeHandlePath(for: request.workspace.path), options: .atomic)
		return handle
	}

	func stopExecution(handle: RuntimeExecutionHandle) async throws {
		let containerName = ContainerRuntimeControl.containerName(forRuntimeID: handle.id)
		let killResult = await containerControl.killContainer(named: containerName)
		let metadata = ContainerRuntimeStopMetadata(
			id: handle.id,
			containerName: containerName,
			workspacePath: handle.workspacePath.path(),
			stoppedAt: .now,
			killExitCode: killResult.result?.exitCode,
			killFailureReason: killResult.failureReason
		)
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let metadataDirectory = metadataDirectory(for: handle.workspacePath)
		try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
		try encoder.encode(metadata).write(
			to: metadataDirectory.appending(path: "container-runtime-stopped"),
			options: .atomic
		)
	}

	func runtimeHandlePath(for workspace: URL) -> URL {
		metadataDirectory(for: workspace).appending(path: "container-runtime-handle.json")
	}

	private func metadataDirectory(for workspace: URL) -> URL {
		workspace.appending(path: ".auditorium")
	}

}

private struct ContainerRuntimeHandleMetadata: Codable {
	let id: String
	let workspacePath: String
	let branchName: String
	let ticketExternalID: String
	let injectedVariableCount: Int
	let startedAt: Date
}

private struct ContainerRuntimeStopMetadata: Codable {
	let id: String
	let containerName: String
	let workspacePath: String
	let stoppedAt: Date
	let killExitCode: Int32?
	let killFailureReason: String?
}
