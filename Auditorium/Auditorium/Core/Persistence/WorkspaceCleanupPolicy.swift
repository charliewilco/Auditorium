import Foundation

struct WorkspaceCleanupPolicy: Equatable, Sendable {
	static let preserveAll = WorkspaceCleanupPolicy(removableStatuses: [])
	static let removeCanceledAndTerminalWithoutReview = WorkspaceCleanupPolicy(
		removableStatuses: [.blocked, .completed, .failed, .canceled],
		preservePullRequestWorkspaces: true
	)

	let removableStatuses: Set<TicketRunStatus>
	let preservePullRequestWorkspaces: Bool

	init(removableStatuses: Set<TicketRunStatus>, preservePullRequestWorkspaces: Bool = true) {
		self.removableStatuses = removableStatuses
		self.preservePullRequestWorkspaces = preservePullRequestWorkspaces
	}

	func shouldRemove(_ ticketRun: TicketRunRecord) -> Bool {
		guard removableStatuses.contains(ticketRun.status) else {
			return false
		}
		if preservePullRequestWorkspaces, ticketRun.pullRequestURL?.isEmpty == false {
			return false
		}
		return ticketRun.workspacePath.isEmpty == false
	}
}

struct WorkspaceCleanupResult: Equatable {
	let scanned: Int
	let removed: Int
	let preserved: Int
	let skippedUnsafePaths: [String]
}

extension ApplicationWorkspaceService {
	func cleanupTicketWorkspaces(projectID: UUID, ticketRuns: [TicketRunRecord], policy: WorkspaceCleanupPolicy) throws -> WorkspaceCleanupResult {
		let workspacesRoot = workspacesDirectory(projectID: projectID).standardizedFileURL
		var removed = 0
		var preserved = 0
		var skippedUnsafePaths: [String] = []

		for ticketRun in ticketRuns {
			guard policy.shouldRemove(ticketRun) else {
				preserved += 1
				continue
			}
			let workspace = URL(fileURLWithPath: ticketRun.workspacePath).standardizedFileURL
			guard isDescendant(workspace, of: workspacesRoot) else {
				preserved += 1
				skippedUnsafePaths.append(ticketRun.workspacePath)
				continue
			}
			if FileManager.default.fileExists(atPath: workspace.path()) {
				try FileManager.default.removeItem(at: workspace)
				removed += 1
			} else {
				preserved += 1
			}
		}

		return WorkspaceCleanupResult(
			scanned: ticketRuns.count,
			removed: removed,
			preserved: preserved,
			skippedUnsafePaths: skippedUnsafePaths
		)
	}

	private func isDescendant(_ url: URL, of root: URL) -> Bool {
		let rootPath = root.path().hasSuffix("/") ? root.path() : "\(root.path())/"
		return url.path().hasPrefix(rootPath)
	}
}
