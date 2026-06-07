import SwiftUI

struct SidebarView: View {
	@Environment(AppState.self) private var appState
	let projects: [Project]

	var body: some View {
		@Bindable var appState = appState
		List(selection: $appState.selectedDestination) {
			Section("Projects") {
				ForEach(projects) { project in
					Button {
						appState.selectProject(project.id)
						appState.selectedDestination = .dashboard
					} label: {
						Label(project.name, systemImage: "music.quarternote.3")
					}
					.buttonStyle(.plain)
					.foregroundStyle(project.id == appState.selectedProjectID ? .primary : .secondary)
				}
			}
			Section("Navigation") {
				ForEach(SidebarDestination.allCases) { destination in
					Label(destination.title, systemImage: destination.symbol)
						.tag(destination)
				}
			}
		}
		.listStyle(.sidebar)
		.navigationSplitViewColumnWidth(min: 190, ideal: 220)
		.toolbar {
			ToolbarItem {
				Button {
					appState.isShowingProjectWizard = true
				} label: {
					Label("New Project", systemImage: "plus")
				}
			}
		}
	}
}
