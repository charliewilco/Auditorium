import Foundation

struct LocalProcessRuntimeProvider: RuntimeProvider {
	let workspaceService: ApplicationWorkspaceService
	let projectID: UUID
	let sourceProvider: any SourceCodeProvider
	let branchPrefix: String

	init(
		workspaceService: ApplicationWorkspaceService,
		projectID: UUID,
		sourceProvider: any SourceCodeProvider,
		branchPrefix: String = "auditorium"
	) {
		self.workspaceService = workspaceService
		self.projectID = projectID
		self.sourceProvider = sourceProvider
		self.branchPrefix = branchPrefix
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
			runtimeID: "local-\(workspaceService.sanitize(ticket.externalID))",
			branchName: branchName
		)
	}

	func startExecution(_ request: RuntimeExecutionRequest) async throws -> RuntimeExecutionHandle {
		try Task.checkCancellation()
		guard FileManager.default.fileExists(atPath: request.workspace.path.path()) else {
			throw ProviderError.unavailable("Local workspace does not exist at \(request.workspace.path.path()).")
		}
		let handle = RuntimeExecutionHandle(id: request.workspace.runtimeID, workspacePath: request.workspace.path)
		let metadata = LocalRuntimeHandleMetadata(
			id: handle.id,
			workspacePath: handle.workspacePath.path(),
			branchName: request.workspace.branchName,
			ticketExternalID: request.ticket.externalID,
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
		try Task.checkCancellation()
		try FileManager.default.createDirectory(at: metadataDirectory(for: handle.workspacePath), withIntermediateDirectories: true)
		try "stopped\n".write(
			to: metadataDirectory(for: handle.workspacePath).appending(path: "runtime-stopped"),
			atomically: true,
			encoding: .utf8
		)
	}

	func runtimeHandlePath(for workspace: URL) -> URL {
		metadataDirectory(for: workspace).appending(path: "runtime-handle.json")
	}

	private func metadataDirectory(for workspace: URL) -> URL {
		workspace.appending(path: ".auditorium")
	}
}

private struct LocalRuntimeHandleMetadata: Codable {
	let id: String
	let workspacePath: String
	let branchName: String
	let ticketExternalID: String
	let startedAt: Date
}
