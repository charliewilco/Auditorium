import AppKit
import SwiftData
import SwiftUI

struct ProjectSetupWizard: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.modelContext) private var modelContext
	@Environment(\.appServices) private var services
	let onCreate: (UUID) -> Void
	@State private var step = 0
	@State private var draft = ProjectDraft()
	@State private var availableRepositories: [RepositoryDescriptor] = []
	@State private var repositoryLoadMessage = ""
	@State private var isLoadingRepositories = false
	@State private var isCreating = false
	@State private var oauthMessage = ""
	@State private var isAuthorizingGitHub = false
	@AppStorage("githubOAuthClientID") private var githubOAuthClientID = ""

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				VStack(alignment: .leading) {
					Text("Create Project")
						.font(.title2.weight(.semibold))
					Text(stepTitle)
						.foregroundStyle(.secondary)
				}
				Spacer()
				Text("\(step + 1) / \(steps.count)")
					.foregroundStyle(.secondary)
			}
			.padding()
			Divider()
			content
				.padding()
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			Divider()
			HStack {
				Button("Cancel") { dismiss() }
				Spacer()
				Button("Back") { step -= 1 }
					.disabled(step == 0)
				Button(step == steps.count - 1 ? "Create Project" : "Next") {
					if step == steps.count - 1 {
						Task { await createProject() }
					} else {
						step += 1
					}
				}
				.buttonStyle(.borderedProminent)
				.disabled((step == steps.count - 1 && !draft.canCreate) || isCreating)
			}
			.padding()
		}
	}

	@ViewBuilder
	private var content: some View {
		switch step {
		case 0:
			providerGrid([RepositoryProviderKind.github], selected: draft.repositoryProviderKind) { kind in
				draft.repositoryProviderKind = kind
			}
		case 1:
			oauthForm(
				title: "\(draft.repositoryProviderKind.title) Credentials",
				placeholder: "GitHub OAuth access token",
				text: Binding(get: { draft.repositoryCredential }, set: { draft.repositoryCredential = $0 }),
				connect: { Task { await connectGitHub() } }
			)
		case 2:
			VStack(alignment: .leading, spacing: 14) {
				Text("Select Repository")
					.font(.headline)
				HStack {
					Button("Load Repositories") {
						Task { await loadRepositories() }
					}
					.disabled(draft.repositoryCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoadingRepositories)
					if isLoadingRepositories {
						ProgressView()
							.controlSize(.small)
					}
					if !repositoryLoadMessage.isEmpty {
						Text(repositoryLoadMessage)
							.foregroundStyle(.secondary)
					}
				}
				if !availableRepositories.isEmpty {
					List(availableRepositories) { repository in
						Button {
							selectRepository(repository)
						} label: {
							HStack {
								VStack(alignment: .leading, spacing: 2) {
									Text(repository.fullName)
										.font(.subheadline.weight(.medium))
									Text(repository.webURL.absoluteString)
										.foregroundStyle(.secondary)
								}
								Spacer()
								Text(repository.defaultBranch)
									.foregroundStyle(.secondary)
							}
						}
						.buttonStyle(.plain)
					}
					.frame(minHeight: 180)
				}
				TextField("Project Name", text: Binding(get: { draft.name }, set: { draft.name = $0 }))
				TextField("Repository", text: Binding(get: { draft.repositoryName }, set: { draft.repositoryName = $0 }))
				TextField("Clone/Web URL", text: Binding(get: { draft.repositoryURL }, set: { draft.repositoryURL = $0 }))
				TextField("Default Branch", text: Binding(get: { draft.defaultBranch }, set: { draft.defaultBranch = $0 }))
			}
		case 3:
			providerGrid([IssueProviderKind.githubIssues], selected: draft.issueProviderKind) { kind in
				draft.issueProviderKind = kind
			}
		case 4:
			oauthForm(
				title: "\(draft.issueProviderKind.title) Credentials",
				placeholder: "GitHub OAuth access token",
				text: Binding(get: { draft.issueCredential }, set: { draft.issueCredential = $0 }),
				connect: { Task { await connectGitHub() } }
			)
		case 5:
			VStack(alignment: .leading, spacing: 14) {
				Text("Issue Source")
					.font(.headline)
				TextField("Team / Project", text: Binding(get: { draft.issueSourceName }, set: { draft.issueSourceName = $0 }))
				TextField("Source Identifier", text: Binding(get: { draft.issueSourceIdentifier }, set: { draft.issueSourceIdentifier = $0 }))
				TextField("Filter", text: Binding(get: { draft.issueFilterName }, set: { draft.issueFilterName = $0 }))
				TextField("Issue Tracker URL", text: Binding(get: { draft.issueTrackerURL }, set: { draft.issueTrackerURL = $0 }))
				Toggle("Import open GitHub issues", isOn: Binding(get: { draft.importGitHubIssues }, set: { draft.importGitHubIssues = $0 }))
				Toggle("Import demo tickets", isOn: Binding(get: { draft.importDemoTickets }, set: { draft.importDemoTickets = $0 }))
			}
		case 6:
			providerGrid(RuntimeProviderKind.allCases, selected: draft.runtimeProviderKind) { kind in
				draft.runtimeProviderKind = kind
			}
		case 7:
			providerGrid(AgentProviderKind.allCases, selected: draft.agentProviderKind) { kind in
				draft.agentProviderKind = kind
			}
		case 8:
			VStack(alignment: .leading, spacing: 14) {
				Text("Run Defaults")
					.font(.headline)
				Stepper("Concurrency \(draft.concurrency)", value: Binding(get: { draft.concurrency }, set: { draft.concurrency = $0 }), in: 1...8)
				Stepper("Max retries \(draft.maxRetries)", value: Binding(get: { draft.maxRetries }, set: { draft.maxRetries = $0 }), in: 0...5)
				TextField("Branch Prefix", text: Binding(get: { draft.branchPrefix }, set: { draft.branchPrefix = $0 }))
				Toggle("Run tests", isOn: Binding(get: { draft.runTests }, set: { draft.runTests = $0 }))
				Toggle("Open pull requests", isOn: Binding(get: { draft.openPullRequest }, set: { draft.openPullRequest = $0 }))
				Text("Runs are not created during setup. These defaults are stored in the project workflow policy and used when Play starts a run.")
					.foregroundStyle(.secondary)
			}
		default:
			VStack(alignment: .leading, spacing: 12) {
				Text("Review Project")
					.font(.headline)
				LabeledContent("Project", value: draft.name)
				LabeledContent("Repository", value: draft.repositoryName)
				LabeledContent("Default Branch", value: draft.defaultBranch)
				LabeledContent("Issue Source", value: "\(draft.issueProviderKind.title) · \(draft.issueSourceName)")
				LabeledContent("Runtime", value: draft.runtimeProviderKind.title)
				LabeledContent("Agent", value: draft.agentProviderKind.title)
				LabeledContent("Concurrency", value: "\(draft.concurrency)")
				LabeledContent("Import Issues", value: draft.importGitHubIssues ? "GitHub open issues" : "No GitHub import")
				LabeledContent("Initial Runs", value: "None")
			}
		}
	}

	private var steps: [String] {
		["Repository Provider", "Repository Credentials", "Repository", "Issue Source", "Issue Credentials", "Issue Filter", "Runtime", "Agent", "Run Defaults", "Review"]
	}

	private var stepTitle: String {
		steps[step]
	}

	private func providerGrid<T: Identifiable & Hashable>(_ values: [T], selected: T, choose: @escaping (T) -> Void) -> some View {
		let columns = [GridItem(.adaptive(minimum: 240), spacing: 12)]
		return LazyVGrid(columns: columns, spacing: 12) {
			ForEach(values) { value in
				let info = providerInfo(value)
				ProviderCard(title: info.title, subtitle: info.subtitle, symbol: info.symbol, isSelected: value == selected)
					.onTapGesture { choose(value) }
			}
		}
	}

	private func tokenForm(title: String, placeholder: String, text: Binding<String>) -> some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(title)
				.font(.headline)
			SecureField(placeholder, text: text)
			Text("Secrets will be stored in Keychain. SwiftData only stores account metadata.")
				.foregroundStyle(.secondary)
		}
	}

	private func oauthForm(title: String, placeholder: String, text: Binding<String>, connect: @escaping () -> Void) -> some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(title)
				.font(.headline)
			Label("GitHub OAuth", systemImage: "person.crop.circle.badge.checkmark")
				.font(.subheadline.weight(.semibold))
			Text("Auditorium uses one GitHub OAuth connection for source code and issues.")
				.foregroundStyle(.secondary)
			TextField("GitHub OAuth Client ID", text: $githubOAuthClientID)
			HStack {
				Button("Connect with GitHub") {
					connect()
				}
				.disabled(githubOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAuthorizingGitHub)
				if isAuthorizingGitHub {
					ProgressView()
						.controlSize(.small)
				}
			}
			if !oauthMessage.isEmpty {
				Text(oauthMessage)
					.foregroundStyle(.secondary)
			}
			Divider()
			SecureField(placeholder, text: text)
			Text("Requested scopes: \(GitHubOAuth.descriptor.scopes.joined(separator: ", "))")
				.foregroundStyle(.secondary)
		}
	}

	private func providerInfo<T>(_ value: T) -> (title: String, subtitle: String, symbol: String) {
		if let value = value as? RepositoryProviderKind {
			return (value.title, "Repository provider", value.symbol)
		}
		if let value = value as? IssueProviderKind {
			return (value.title, "Issue provider", value.symbol)
		}
		if let value = value as? RuntimeProviderKind {
			return (value.title, "Workspace runtime", value.symbol)
		}
		if let value = value as? AgentProviderKind {
			return (value.title, "Coding agent", value.symbol)
		}
		return ("Provider", "Provider", "square")
	}

	private func connectGitHub() async {
		let clientID = githubOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !clientID.isEmpty else {
			return
		}
		isAuthorizingGitHub = true
		oauthMessage = ""
		defer { isAuthorizingGitHub = false }

		do {
			let service = GitHubOAuthDeviceFlowService()
			let deviceCode = try await service.requestDeviceCode(clientID: clientID)
			let verificationURL = deviceCode.verificationURIComplete ?? deviceCode.verificationURI
			oauthMessage = "Enter code \(deviceCode.userCode) in GitHub, then return here."
			NSWorkspace.shared.open(verificationURL)
			let token = try await service.pollToken(clientID: clientID, deviceCode: deviceCode)
			draft.repositoryCredential = token.accessToken
			draft.issueCredential = token.accessToken
			oauthMessage = "GitHub connected with scopes: \(token.scope)"
		} catch {
			oauthMessage = error.localizedDescription
		}
	}

	private func loadRepositories() async {
		let token = draft.repositoryCredential.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !token.isEmpty else {
			return
		}
		isLoadingRepositories = true
		repositoryLoadMessage = ""
		defer { isLoadingRepositories = false }

		do {
			let provider = GitHubRepositoryProvider(token: token)
			availableRepositories = try await provider.listRepositories()
			repositoryLoadMessage = "\(availableRepositories.count) repositories"
		} catch {
			repositoryLoadMessage = error.localizedDescription
		}
	}

	private func selectRepository(_ repository: RepositoryDescriptor) {
		draft.name = repository.name
		draft.repositoryName = repository.fullName
		draft.repositoryURL = repository.webURL.absoluteString
		draft.defaultBranch = repository.defaultBranch
		draft.issueSourceName = repository.fullName
		draft.issueSourceIdentifier = repository.fullName
		draft.issueTrackerURL = repository.webURL.appending(path: "issues").absoluteString
		if draft.issueCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			draft.issueCredential = draft.repositoryCredential
		}
		draft.importDemoTickets = false
		draft.importGitHubIssues = true
	}

	private func createProject() async {
		isCreating = true
		defer { isCreating = false }
		do {
			let projectID = try services.projectCreation.createProject(
				from: draft,
				context: modelContext,
				workspaceService: services.workspace,
				keychainService: services.keychain
			)
			if draft.importGitHubIssues {
				_ = try await ProjectIssueImportService().importTickets(projectID: projectID, context: modelContext, providerRegistry: services.providerRegistry)
			}
			onCreate(projectID)
			dismiss()
		} catch {
			NSAlert(error: error).runModal()
		}
	}
}
