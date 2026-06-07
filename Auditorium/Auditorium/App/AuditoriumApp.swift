import SwiftData
import SwiftUI

@main
struct AuditoriumApp: App {
	@State private var appState = AppState()
	private let services = AppServices()
	private let modelContainer: ModelContainer

	init() {
		do {
			modelContainer = try AppSchema.makeModelContainer()
		} catch {
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
				Button("New Project") {
					appState.isShowingProjectWizard = true
				}
				.keyboardShortcut("n", modifiers: .command)
			}
			CommandMenu("Auditorium") {
				Button("Run Queue") {
					NotificationCenter.default.post(name: .runQueueCommand, object: nil)
				}
				.keyboardShortcut("r", modifiers: .command)
				Button("Dry Run") {
					NotificationCenter.default.post(name: .dryRunCommand, object: nil)
				}
				.keyboardShortcut("r", modifiers: [.command, .shift])
				Button("Find Tickets") {
					appState.selectedDestination = .tickets
					NotificationCenter.default.post(name: .focusTicketSearchCommand, object: nil)
				}
				.keyboardShortcut("f", modifiers: .command)
				Button("Inspect Selected Ticket") {
					NotificationCenter.default.post(name: .inspectTicketCommand, object: nil)
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
}

extension Notification.Name {
	static let runQueueCommand = Notification.Name("RunQueueCommand")
	static let dryRunCommand = Notification.Name("DryRunCommand")
	static let focusTicketSearchCommand = Notification.Name("FocusTicketSearchCommand")
	static let inspectTicketCommand = Notification.Name("InspectTicketCommand")
}
