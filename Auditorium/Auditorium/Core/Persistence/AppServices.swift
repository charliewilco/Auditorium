import Foundation
import SwiftUI

struct AppServices {
	let keychain: KeychainService
	let workspace: ApplicationWorkspaceService
	let runtimeDetection: RuntimeDetectionService
	let reportGenerator: ReportGenerator
	let projectCreation: ProjectCreationService
	let symphony: SymphonyCLIProcessRunner

	init(environment: [String: String] = ProcessInfo.processInfo.environment) {
		keychain = KeychainService(service: environment["AUDITORIUM_KEYCHAIN_SERVICE"] ?? "co.charliewil.Auditorium")
		workspace = ApplicationWorkspaceService()
		runtimeDetection = RuntimeDetectionService()
		reportGenerator = ReportGenerator()
		projectCreation = ProjectCreationService()
		symphony = SymphonyCLIProcessRunner()
	}

	@MainActor var projectEnvironmentSecrets: ProjectEnvironmentSecretService {
		ProjectEnvironmentSecretService(keychain: keychain)
	}

	@MainActor var providerRegistry: ProviderRegistry {
		ProviderRegistry(keychainService: keychain)
	}
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
