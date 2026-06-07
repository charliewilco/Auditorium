import SwiftUI

struct AppServices {
	let keychain = KeychainService()
	let workspace = ApplicationWorkspaceService()
	let runtimeDetection = RuntimeDetectionService()
	let reportGenerator = ReportGenerator()
	let projectCreation = ProjectCreationService()
}

private struct AppServicesKey: EnvironmentKey {
	static let defaultValue = AppServices()
}

extension EnvironmentValues {
	var appServices: AppServices {
		get { self[AppServicesKey.self] }
		set { self[AppServicesKey.self] = newValue }
	}
}
