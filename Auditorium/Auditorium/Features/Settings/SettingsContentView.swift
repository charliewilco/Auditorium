import AppKit
import SwiftData
import SwiftUI

struct SettingsSceneView: View {
	@State private var runtimeHealth: [RuntimeHealthCheck] = []
	@Environment(\.appServices) private var services

	var body: some View {
		SettingsContentView(runtimeHealth: runtimeHealth)
			.frame(minWidth: 620, minHeight: 520)
			.task {
				runtimeHealth = await services.runtimeDetection.detect()
			}
	}
}

struct SettingsContentView: View {
	let runtimeHealth: [RuntimeHealthCheck]
	@Environment(\.modelContext) private var modelContext
	@Environment(\.appServices) private var services
	@Query(sort: \ProviderAccountRecord.updatedAt, order: .reverse) private var providerAccounts: [ProviderAccountRecord]
	@AppStorage("requireRunConfirmation") private var requireRunConfirmation = true
	@AppStorage("requirePROpenConfirmation") private var requirePROpenConfirmation = true
	@AppStorage("allowNetworkAccess") private var allowNetworkAccess = false
	@AppStorage("allowFilesystemWrite") private var allowFilesystemWrite = true
	@AppStorage("runtimeIsolationLevel") private var runtimeIsolationLevel = "Mock isolated workspace"
	@AppStorage("reportAutoSave") private var reportAutoSave = true
	@AppStorage("logRetentionDays") private var logRetentionDays = 30

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				Text("Settings")
					.font(.largeTitle.weight(.semibold))
				settingsSection("Accounts") {
					Text("Credential metadata is stored in SwiftData. Secret values are stored in Keychain under co.charliewil.Auditorium.")
						.foregroundStyle(.secondary)
					if providerAccounts.isEmpty {
						Text("No connected provider accounts.")
							.foregroundStyle(.secondary)
					} else {
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
					ForEach(runtimeHealth) { health in
						HStack {
							VStack(alignment: .leading) {
								Text(health.name)
								Text(health.detail)
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							Spacer()
							StatusBadge(title: health.state.title, tint: health.state.tint)
						}
					}
				}
				settingsSection("Security") {
					Toggle("Require confirmation before starting runs", isOn: $requireRunConfirmation)
					Toggle("Require confirmation before opening PRs", isOn: $requirePROpenConfirmation)
					Toggle("Allow network access", isOn: $allowNetworkAccess)
					Toggle("Allow filesystem write", isOn: $allowFilesystemWrite)
					TextField("Runtime isolation level", text: $runtimeIsolationLevel)
				}
				settingsSection("Concurrency") {
					Text("Per-project queue concurrency is controlled from the Queue screen.")
						.foregroundStyle(.secondary)
				}
				settingsSection("Reports") {
					Toggle("Save reports to project history", isOn: $reportAutoSave)
				}
				settingsSection("Logs") {
					Stepper("Retain logs for \(logRetentionDays) days", value: $logRetentionDays, in: 1...365)
				}
			}
			.padding()
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

	private func clearGitHubCredentials() {
		do {
			try services.providerRegistry.clearGitHubCredentials(context: modelContext)
		} catch {
			NSAlert(error: error).runModal()
		}
	}
}
