import SwiftData
import SwiftUI

@main
struct AuditoriumApp: App {
	@State private var appState = AppState()
	private let services = AppServices()
	private let modelContainer: ModelContainer

	init() {
		do {
			let environment = ProcessInfo.processInfo.environment
			let shouldUseEphemeralStore =
				environment["XCTestConfigurationFilePath"] != nil
				|| environment["CI"] == "true"
				|| environment["AUDITORIUM_EXPORT_SCREENSHOTS"] != nil
			modelContainer = try AppSchema.makeModelContainer(inMemory: shouldUseEphemeralStore)
		}
		catch {
			fatalError("Could not create ModelContainer: \(error)")
		}
		if ProcessInfo.processInfo.environment["AUDITORIUM_EXPORT_SCREENSHOTS"] != nil {
			Task { @MainActor in
				ScreenshotExporter.exportAndExit()
			}
		}
	}

	var body: some Scene {
		WindowGroup {
			RootView()
				.environment(appState)
				.environment(\.appServices, services)
		}
		.modelContainer(modelContainer)
		.commands {
			CommandGroup(replacing: .newItem) {
				Button(AppCommand.newProject.title) {
					appState.handle(.newProject)
				}
				.keyboardShortcut("n", modifiers: .command)
			}
			CommandMenu("Auditorium") {
				Button(AppCommand.runQueue.title) {
					post(.runQueue)
				}
				.keyboardShortcut("r", modifiers: .command)
				Button(AppCommand.dryRun.title) {
					post(.dryRun)
				}
				.keyboardShortcut("r", modifiers: [.command, .shift])
				Button(AppCommand.findTickets.title) {
					post(.findTickets)
				}
				.keyboardShortcut("f", modifiers: .command)
				Button(AppCommand.inspectSelectedTicket.title) {
					post(.inspectSelectedTicket)
				}
				.keyboardShortcut(.space, modifiers: [])
			}
		}

		Settings {
			SettingsSceneView()
				.environment(appState)
				.environment(\.appServices, services)
				.modelContainer(modelContainer)
		}
	}

	private func post(_ command: AppCommand) {
		guard let notificationName = command.notificationName else { return }
		NotificationCenter.default.post(name: notificationName, object: nil)
	}
}
