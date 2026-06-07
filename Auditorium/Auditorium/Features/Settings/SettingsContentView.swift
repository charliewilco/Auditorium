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
	@AppStorage("githubOAuthClientID") private var githubOAuthClientID = ""
	@AppStorage("requireRunConfirmation") private var requireRunConfirmation = true
	@AppStorage("requirePROpenConfirmation") private var requirePROpenConfirmation = true
	@AppStorage("allowNetworkAccess") private var allowNetworkAccess = false
	@AppStorage("allowFilesystemWrite") private var allowFilesystemWrite = true
	@AppStorage(ApplicationSettingsKeys.runtimeIsolationLevel) private var runtimeIsolationLevelRaw = RuntimeIsolationLevel.localWorkspace
		.rawValue
	@AppStorage("reportAutoSave") private var reportAutoSave = true
	@AppStorage("logRetentionDays") private var logRetentionDays = 30
	@AppStorage(ApplicationSettingsKeys.logsDirectoryPath) private var logsDirectoryPath = ""
	@AppStorage(ApplicationSettingsKeys.reportsDirectoryPath) private var reportsDirectoryPath = ""

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
					providerList(RepositoryProviderKind.allCases.map(\.title))
				}
				settingsSection("Issue Providers") {
					providerList(IssueProviderKind.allCases.map(\.title))
				}
				settingsSection("Agent Providers") {
					providerList(AgentProviderKind.allCases.map(\.title))
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
					Picker("Runtime isolation", selection: $runtimeIsolationLevelRaw) {
						ForEach(RuntimeIsolationLevel.allCases) { level in
							Text(level.title).tag(level.rawValue)
						}
					}
					Text(selectedRuntimeIsolationLevel.detail)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				settingsSection("Concurrency") {
					Text("Per-project queue concurrency is controlled from the Queue screen.")
						.foregroundStyle(.secondary)
				}
				settingsSection("Workflow") {
					WorkflowPolicyEditorView(project: project)
				}
				settingsSection("Reports") {
					Toggle("Save reports to project history", isOn: $reportAutoSave)
					pathField(
						title: "Reports root",
						path: $reportsDirectoryPath,
						fallback: "Application Support/Auditorium/Projects/<project>/Reports",
						choose: { chooseDirectory(for: $reportsDirectoryPath) }
					)
				}
				settingsSection("Logs") {
					Stepper("Retain logs for \(logRetentionDays) days", value: $logRetentionDays, in: 1...365)
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

	private var selectedRuntimeIsolationLevel: RuntimeIsolationLevel {
		RuntimeIsolationLevel(rawValue: runtimeIsolationLevelRaw) ?? .localWorkspace
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

	private func providerList(_ providers: [String]) -> some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], alignment: .leading, spacing: 8) {
			ForEach(providers, id: \.self) { provider in
				HStack {
					Image(systemName: "checkmark.circle")
						.foregroundStyle(.secondary)
					Text(provider)
				}
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
}
