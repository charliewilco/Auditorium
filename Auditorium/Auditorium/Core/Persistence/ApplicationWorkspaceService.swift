import Foundation

struct ApplicationWorkspaceService {
	let rootDirectory: URL
	private let pathSettings: @Sendable () -> ApplicationPathSettings

	init(rootDirectory: URL? = nil, pathSettings: @escaping @Sendable () -> ApplicationPathSettings = { ApplicationPathSettings.load() }) {
		if let rootDirectory {
			self.rootDirectory = rootDirectory
		}
		else {
			let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			self.rootDirectory = base.appending(path: "Auditorium")
		}
		self.pathSettings = pathSettings
	}

	func projectDirectory(projectID: UUID) -> URL {
		rootDirectory.appending(path: "Projects").appending(path: projectID.uuidString)
	}

	func repositoryDirectory(projectID: UUID) -> URL {
		projectDirectory(projectID: projectID).appending(path: "Repositories")
	}

	func workspacesDirectory(projectID: UUID) -> URL {
		projectDirectory(projectID: projectID).appending(path: "Workspaces")
	}

	func workspacePath(projectID: UUID, ticketExternalID: String) -> URL {
		workspacesDirectory(projectID: projectID).appending(path: sanitize(ticketExternalID))
	}

	func logsDirectory(projectID: UUID) -> URL {
		pathSettings().logsDirectory(defaultDirectory: projectDirectory(projectID: projectID).appending(path: "Logs"), projectID: projectID)
	}

	func reportDirectory(projectID: UUID) -> URL {
		pathSettings().reportsDirectory(
			defaultDirectory: projectDirectory(projectID: projectID).appending(path: "Reports"),
			projectID: projectID
		)
	}

	func reportPath(projectID: UUID, runID: UUID) -> URL {
		reportDirectory(projectID: projectID).appending(path: "run-\(runID.uuidString.prefix(8)).md")
	}

	func ensureProjectLayout(projectID: UUID) throws {
		let directories = [
			repositoryDirectory(projectID: projectID),
			workspacesDirectory(projectID: projectID),
			logsDirectory(projectID: projectID),
			reportDirectory(projectID: projectID),
		]
		for directory in directories {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		}
	}

	func sanitize(_ input: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
		let scalars = input.unicodeScalars.map { scalar in
			allowed.contains(scalar) ? Character(scalar) : "-"
		}
		let value = String(scalars).lowercased()
		return value.replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
	}
}
