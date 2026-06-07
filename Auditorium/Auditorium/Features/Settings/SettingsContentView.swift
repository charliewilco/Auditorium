import AppKit
import SwiftData
import SwiftUI

struct SettingsSceneView: View {
	@State private var runtimeHealth: [RuntimeHealthCheck] = []
	@State private var symphonyDoctorStatus: SymphonyDoctorStatus?
	@Environment(\.appServices) private var services

	var body: some View {
		SettingsContentView(runtimeHealth: runtimeHealth, symphonyDoctorStatus: symphonyDoctorStatus)
			.frame(minWidth: 620, minHeight: 520)
			.task {
				runtimeHealth = await services.runtimeDetection.detect()
				symphonyDoctorStatus = await services.symphony.doctor()
			}
	}
}

struct SettingsContentView: View {
	let project: Project?
	let runtimeHealth: [RuntimeHealthCheck]
	let symphonyDoctorStatus: SymphonyDoctorStatus?
	@Environment(\.modelContext) private var modelContext
	@Environment(\.appServices) private var services
	@Query(sort: \ProviderAccountRecord.updatedAt, order: .reverse) private var providerAccounts: [ProviderAccountRecord]
	@Query(sort: \ProjectEnvironmentSecretRecord.name) private var environmentSecrets: [ProjectEnvironmentSecretRecord]
	@AppStorage("githubOAuthClientID") private var githubOAuthClientID = ""
	@AppStorage("requireRunConfirmation") private var requireRunConfirmation = true
	@AppStorage("requirePROpenConfirmation") private var requirePROpenConfirmation = true
	@AppStorage("allowNetworkAccess") private var allowNetworkAccess = false
	@AppStorage("allowFilesystemWrite") private var allowFilesystemWrite = true
	@AppStorage(ApplicationSettingsKeys.logsDirectoryPath) private var logsDirectoryPath = ""
	@AppStorage(ApplicationSettingsKeys.reportsDirectoryPath) private var reportsDirectoryPath = ""
	@State private var environmentSecretName = ""
	@State private var environmentSecretValue = ""

	init(project: Project? = nil, runtimeHealth: [RuntimeHealthCheck], symphonyDoctorStatus: SymphonyDoctorStatus?) {
		self.project = project
		self.runtimeHealth = runtimeHealth
		self.symphonyDoctorStatus = symphonyDoctorStatus
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				Text("Settings")
					.font(.largeTitle.weight(.semibold))
				settingsSection("Accounts") {
					Text(
						"Credential metadata is stored in SwiftData. Secret values are stored in Keychain under co.charliewil.Auditorium."
					)
					.foregroundStyle(.secondary)
					TextField("GitHub OAuth Client ID", text: $githubOAuthClientID)
					githubAccountStateView
					if providerAccounts.isEmpty {
						Text("No connected provider accounts.")
							.foregroundStyle(.secondary)
					}
					else {
						ForEach(providerAccounts) { account in
							LabeledContent(account.displayName, value: account.providerKindRaw)
						}
					}
					Button("Clear GitHub Credentials", role: .destructive) {
						clearGitHubCredentials()
					}
					.disabled(providerAccounts.isEmpty)
				}
				settingsSection("Repository Providers") {
					providerList(ProviderStateSummaries.repositoryProviders())
				}
				settingsSection("Issue Providers") {
					providerList(ProviderStateSummaries.issueProviders())
				}
				settingsSection("Agent Providers") {
					providerList(ProviderStateSummaries.agentProviders())
				}
				settingsSection("Runtime Providers") {
					SymphonyDoctorStatusView(status: symphonyDoctorStatus)
					ForEach(runtimeProviderStatuses) { status in
						HStack(alignment: .top) {
							VStack(alignment: .leading, spacing: 4) {
								Text(status.kind.title)
								Text(status.detection.detail)
									.font(.caption)
									.foregroundStyle(.secondary)
								Text(status.implementationDetail)
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							Spacer()
							HStack(spacing: 6) {
								StatusBadge(title: status.detection.state.title, tint: status.detection.state.tint)
								StatusBadge(
									title: status.implementationState.title,
									tint: implementationStatusTint(status.implementationState)
								)
							}
						}
					}
				}
				settingsSection("Security") {
					Toggle("Require confirmation before starting runs", isOn: $requireRunConfirmation)
					Toggle("Require confirmation before opening PRs", isOn: $requirePROpenConfirmation)
					Toggle("Allow network access", isOn: $allowNetworkAccess)
					Toggle("Allow filesystem write", isOn: $allowFilesystemWrite)
				}
				settingsSection("Runtime Environment") {
					runtimeEnvironmentSection
				}
				settingsSection("Concurrency") {
					Text("Per-project queue concurrency is controlled from the Queue screen.")
						.foregroundStyle(.secondary)
				}
				settingsSection("Workflow") {
					WorkflowPolicyEditorView(project: project)
				}
				settingsSection("Reports") {
					pathField(
						title: "Reports root",
						path: $reportsDirectoryPath,
						fallback: "Application Support/Auditorium/Projects/<project>/Reports",
						choose: { chooseDirectory(for: $reportsDirectoryPath) }
					)
				}
				settingsSection("Logs") {
					pathField(
						title: "Logs root",
						path: $logsDirectoryPath,
						fallback: "Application Support/Auditorium/Projects/<project>/Logs",
						choose: { chooseDirectory(for: $logsDirectoryPath) }
					)
				}
			}
			.padding()
		}
	}

	private var runtimeProviderStatuses: [RuntimeProviderStatus] {
		RuntimeDetectionService.runtimeProviderStatuses(from: runtimeHealth)
	}

	private var projectEnvironmentSecrets: [ProjectEnvironmentSecretRecord] {
		guard let project else { return [] }
		return environmentSecrets.filter { $0.projectID == project.id }.sorted { $0.name < $1.name }
	}

	private var githubAuthenticationState: GitHubAuthenticationState {
		GitHubAuthenticationState(providerAccounts: providerAccounts) { account in
			try services.keychain.readSecret(account: account)
		}
	}

	private var githubAccountStateView: some View {
		let state = githubAuthenticationState
		return HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(state.displayName)
					.font(.subheadline.weight(.semibold))
				Text(state.detail)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			StatusBadge(title: githubStatusTitle(state.status), tint: githubStatusTint(state.status))
		}
	}

	@ViewBuilder
	private var runtimeEnvironmentSection: some View {
		if let project {
			Text("Values are stored in Keychain and injected only into runtime containers immediately before execution.")
				.foregroundStyle(.secondary)
			HStack {
				TextField("ENV_NAME", text: $environmentSecretName)
					.textFieldStyle(.roundedBorder)
				SecureField("Value", text: $environmentSecretValue)
					.textFieldStyle(.roundedBorder)
				Button {
					saveEnvironmentSecret(projectID: project.id)
				} label: {
					Label("Add or Replace", systemImage: "key.fill")
				}
				.disabled(
					environmentSecretName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
						|| environmentSecretValue.isEmpty
				)
			}
			if projectEnvironmentSecrets.isEmpty {
				Text("No runtime environment secrets saved for this project.")
					.foregroundStyle(.secondary)
			}
			else {
				ForEach(projectEnvironmentSecrets) { secret in
					HStack(alignment: .firstTextBaseline, spacing: 12) {
						VStack(alignment: .leading, spacing: 4) {
							Text(secret.name)
								.font(.callout.weight(.medium))
							Text(
								"Created \(secret.createdAt, format: .dateTime.month().day().hour().minute()) - Updated \(secret.updatedAt, format: .dateTime.month().day().hour().minute())"
							)
							.font(.caption)
							.foregroundStyle(.secondary)
						}
						Spacer()
						Toggle(
							secret.isEnabled ? "Enabled" : "Disabled",
							isOn: Binding(
								get: { secret.isEnabled },
								set: { setEnvironmentSecret(secret, enabled: $0) }
							)
						)
						.toggleStyle(.switch)
						Button(role: .destructive) {
							deleteEnvironmentSecret(secret)
						} label: {
							Label("Delete", systemImage: "trash")
						}
					}
				}
			}
		}
		else {
			Text("Select a project to manage runtime environment secrets.")
				.foregroundStyle(.secondary)
		}
	}

	private func githubStatusTitle(_ status: GitHubAuthenticationState.Status) -> String {
		switch status {
		case .disconnected: "Disconnected"
		case .missingSecret: "Needs Repair"
		case .connected: "Connected"
		}
	}

	private func githubStatusTint(_ status: GitHubAuthenticationState.Status) -> Color {
		switch status {
		case .disconnected: .secondary
		case .missingSecret: .orange
		case .connected: .green
		}
	}

	private func implementationStatusTint(_ state: ProviderImplementationState) -> Color {
		switch state {
		case .detected: .blue
		case .authenticated: .indigo
		case .authorized: .purple
		case .implemented: .green
		case .unavailable: .secondary
		}
	}

	private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(title)
				.font(.headline)
			content()
		}
		.padding()
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private func providerList(_ providers: [ProviderStateSummary]) -> some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
			ForEach(providers) { provider in
				VStack(alignment: .leading, spacing: 6) {
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Image(systemName: provider.isAvailable ? "checkmark.circle.fill" : "circle.slash")
							.foregroundStyle(implementationStatusTint(provider.state))
						Text(provider.title)
							.font(.subheadline.weight(.medium))
						Spacer()
						StatusBadge(title: provider.state.title, tint: implementationStatusTint(provider.state))
					}
					Text(provider.detail)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				.padding(8)
				.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
			}
		}
	}

	private func pathField(title: String, path: Binding<String>, fallback: String, choose: @escaping () -> Void) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				TextField(fallback, text: path)
				Button(action: choose) {
					Label("Choose", systemImage: "folder")
				}
			}
			Text(
				path.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
					? "Default: \(fallback)" : "\(title): \(path.wrappedValue)"
			)
			.font(.caption)
			.foregroundStyle(.secondary)
		}
	}

	private func chooseDirectory(for path: Binding<String>) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = true
		if panel.runModal() == .OK, let url = panel.url {
			path.wrappedValue = url.path()
		}
	}

	private func clearGitHubCredentials() {
		do {
			try services.providerRegistry.clearGitHubCredentials(context: modelContext)
		}
		catch {
			NSAlert(error: error).runModal()
		}
	}

	private func saveEnvironmentSecret(projectID: UUID) {
		do {
			try services.projectEnvironmentSecrets.upsertSecret(
				projectID: projectID,
				name: environmentSecretName,
				value: environmentSecretValue,
				context: modelContext
			)
			environmentSecretName = ""
			environmentSecretValue = ""
		}
		catch {
			NSAlert(error: error).runModal()
		}
	}

	private func setEnvironmentSecret(_ secret: ProjectEnvironmentSecretRecord, enabled: Bool) {
		do {
			try services.projectEnvironmentSecrets.setEnabled(enabled, record: secret, context: modelContext)
		}
		catch {
			NSAlert(error: error).runModal()
		}
	}

	private func deleteEnvironmentSecret(_ secret: ProjectEnvironmentSecretRecord) {
		do {
			try services.projectEnvironmentSecrets.deleteSecret(secret, context: modelContext)
		}
		catch {
			NSAlert(error: error).runModal()
		}
	}
}
