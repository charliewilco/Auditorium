import Foundation

struct WorkspaceLocationState: Equatable {
	struct Item: Identifiable, Equatable {
		let id: String
		let title: String
		let url: URL

		var path: String {
			url.path()
		}
	}

	let items: [Item]

	init(project: Project, repository: RepositoryRecord?, workspaceService: ApplicationWorkspaceService) {
		let projectDirectory = workspaceService.projectDirectory(projectID: project.id)
		let repositoryDirectory: URL
		if let localPath = repository?.localPath, localPath.isEmpty == false {
			repositoryDirectory = URL(fileURLWithPath: localPath)
		}
		else {
			repositoryDirectory = workspaceService.repositoryDirectory(projectID: project.id)
		}
		items = [
			Item(id: "project", title: "Project", url: projectDirectory),
			Item(id: "repository", title: "Repository", url: repositoryDirectory),
			Item(id: "workspaces", title: "Workspaces", url: workspaceService.workspacesDirectory(projectID: project.id)),
		]
	}
}
