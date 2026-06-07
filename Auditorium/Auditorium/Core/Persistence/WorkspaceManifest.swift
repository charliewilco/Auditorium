import Foundation

struct WorkspaceManifest: Codable, Equatable, Sendable {
	let projectID: UUID
	let runID: UUID
	let ticketRunID: UUID
	let ticketID: UUID
	let ticketExternalID: String
	let repository: String
	let workspacePath: String
	let branchName: String
	let runtimeProvider: String
	let agentProvider: String
	let createdAt: Date
}

extension ApplicationWorkspaceService {
	func workspaceManifestPath(workspace: URL) -> URL {
		workspace.appending(path: "workspace-manifest.json")
	}

	func writeWorkspaceManifest(_ manifest: WorkspaceManifest, workspace: URL) throws -> URL {
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let data = try encoder.encode(manifest)
		let url = workspaceManifestPath(workspace: workspace)
		try data.write(to: url, options: .atomic)
		return url
	}
}
