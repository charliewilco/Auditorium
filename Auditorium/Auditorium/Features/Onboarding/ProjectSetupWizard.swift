import AppKit
import SwiftData
import SwiftUI

struct ProjectSetupWizard: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.modelContext) private var modelContext
	@Environment(\.appServices) private var services
	let onCreate: (UUID) -> Void
	@Query(sort: \ProviderAccountRecord.updatedAt, order: .reverse) private var providerAccounts: [ProviderAccountRecord]
	@State private var step = 0
	@State private var draft = ProjectDraft()
	@State private var availableRepositories: [RepositoryDescriptor] = []
	@State private var availableIssueFilterOptions: [GitHubIssueFilterOption] = []
	@State private var availableIssuePreview: [TicketDescriptor] = []
	@State private var repositoryLoadMessage = ""
	@State private var issueFilterLoadMessage = ""
	@State private var isLoadingRepositories = false
	@State private var isLoadingIssueFilters = false
	@State private var isCreating = false
	@State private var creationErrorMessage: String?
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
			if let currentValidationMessage {
				Label(currentValidationMessage, systemImage: "exclamationmark.triangle")
					.foregroundStyle(.orange)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal)
					.padding(.top, 10)
			}
			if let creationErrorMessage {
				VStack(alignment: .leading, spacing: 6) {
					Label("Project could not be created", systemImage: "xmark.octagon")
						.font(.subheadline.weight(.semibold))
					Text(creationErrorMessage)
					Button("Dismiss") {
						self.creationErrorMessage = nil
					}
					.controlSize(.small)
				}
				.foregroundStyle(.red)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal)
				.padding(.top, 10)
			}
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
					creationErrorMessage = nil
					if step == steps.count - 1 {
						Task { await createProject() }
					}
					else {
						step += 1
					}
				}
				.buttonStyle(.borderedProminent)
				.disabled(currentValidationMessage != nil || isCreating)
			}
			.padding()
		}
	}

	@ViewBuilder
	private var content: some View {
		switch currentStep {
		case .repositoryProvider:
			providerGrid([RepositoryProviderKind.github], selected: draft.repositoryProviderKind) { kind in
				draft.repositoryProviderKind = kind
			}
		case .repositoryCredentials:
			oauthForm(
				title: "\(draft.repositoryProviderKind.title) Credentials",
				placeholder: "GitHub OAuth access token",
				text: Binding(get: { draft.repositoryCredential }, set: { draft.repositoryCredential = $0 }),
				selectedAccountID: draft.selectedRepositoryAccountID,
				connect: { Task { await connectGitHub() } },
				selectAccount: { selectSavedGitHubAccount($0, useForRepository: true) }
			)
		case .repository:
			VStack(alignment: .leading, spacing: 14) {
				Text("Select Repository")
					.font(.headline)
				HStack {
					Button("Load Repositories") {
						Task { await loadRepositories() }
					}
					.disabled(
						draft.repositoryCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
							|| isLoadingRepositories
					)
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
		case .issueProvider:
			providerGrid([IssueProviderKind.githubIssues], selected: draft.issueProviderKind) { kind in
				draft.issueProviderKind = kind
			}
		case .issueCredentials:
			oauthForm(
				title: "\(draft.issueProviderKind.title) Credentials",
				placeholder: "GitHub OAuth access token",
				text: Binding(get: { draft.issueCredential }, set: { draft.issueCredential = $0 }),
				selectedAccountID: draft.selectedIssueAccountID,
				connect: { Task { await connectGitHub() } },
				selectAccount: { selectSavedGitHubAccount($0, useForRepository: false) }
			)
		case .issueSource:
			VStack(alignment: .leading, spacing: 14) {
				Text("Issue Source")
					.font(.headline)
				HStack {
					Button("Load Issue Filters") {
						Task { await loadIssueFilters() }
					}
					.disabled(loadIssueFiltersDisabled)
					if isLoadingIssueFilters {
						ProgressView()
							.controlSize(.small)
					}
					if !issueFilterLoadMessage.isEmpty {
						Text(issueFilterLoadMessage)
							.foregroundStyle(.secondary)
					}
				}
				if !availableIssueFilterOptions.isEmpty {
					Picker(
						"GitHub Issue Query",
						selection: Binding(get: { draft.issueFilterName }, set: { draft.issueFilterName = $0 })
					) {
						ForEach(availableIssueFilterOptions) { option in
							Text("\(option.title) · \(option.subtitle)")
								.tag(option.rawValue)
						}
					}
					.pickerStyle(.menu)
				}
				if !availableIssuePreview.isEmpty {
					List(availableIssuePreview) { ticket in
						VStack(alignment: .leading, spacing: 3) {
							Text("#\(ticket.externalID) \(ticket.title)")
								.font(.subheadline.weight(.medium))
							Text(ticket.labels.joined(separator: ", "))
								.foregroundStyle(.secondary)
						}
					}
					.frame(minHeight: 140)
				}
				TextField("Team / Project", text: Binding(get: { draft.issueSourceName }, set: { draft.issueSourceName = $0 }))
				TextField(
					"Source Identifier",
					text: Binding(get: { draft.issueSourceIdentifier }, set: { draft.issueSourceIdentifier = $0 })
				)
				TextField("Filter", text: Binding(get: { draft.issueFilterName }, set: { draft.issueFilterName = $0 }))
				TextField("Issue Tracker URL", text: Binding(get: { draft.issueTrackerURL }, set: { draft.issueTrackerURL = $0 }))
				Toggle(
					"Import open GitHub issues",
					isOn: Binding(get: { draft.importGitHubIssues }, set: { draft.importGitHubIssues = $0 })
				)
				Toggle("Import demo tickets", isOn: Binding(get: { draft.importDemoTickets }, set: { draft.importDemoTickets = $0 }))
			}
		case .runtime:
			providerGrid(RuntimeProviderKind.allCases, selected: draft.runtimeProviderKind) { kind in
				draft.runtimeProviderKind = kind
			}
		case .agent:
			providerGrid(AgentProviderKind.allCases, selected: draft.agentProviderKind) { kind in
				draft.agentProviderKind = kind
			}
		case .runDefaults:
			VStack(alignment: .leading, spacing: 14) {
				Text("Run Defaults")
					.font(.headline)
				Stepper(
					"Concurrency \(draft.concurrency)",
					value: Binding(get: { draft.concurrency }, set: { draft.concurrency = $0 }),
					in: 1...8
				)
				Stepper(
					"Max retries \(draft.maxRetries)",
					value: Binding(get: { draft.maxRetries }, set: { draft.maxRetries = $0 }),
					in: 0...5
				)
				TextField("Branch Prefix", text: Binding(get: { draft.branchPrefix }, set: { draft.branchPrefix = $0 }))
				Toggle("Run tests", isOn: Binding(get: { draft.runTests }, set: { draft.runTests = $0 }))
				Toggle("Open pull requests", isOn: Binding(get: { draft.openPullRequest }, set: { draft.openPullRequest = $0 }))
				Text(
					"Runs are not created during setup. These defaults are stored in the project workflow policy and used when Play starts a run."
				)
				.foregroundStyle(.secondary)
			}
		case .review:
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

	private var steps: [ProjectSetupStep] {
		ProjectSetupStep.allCases
	}

	private var currentStep: ProjectSetupStep {
		steps[step]
	}

	private var stepTitle: String {
		currentStep.title
	}

	private var currentValidationMessage: String? {
		currentStep.validationMessage(for: draft)
	}

	private var loadIssueFiltersDisabled: Bool {
		isLoadingIssueFilters || draft.hasGitHubCredential == false || draft.trimmedIssueSourceIdentifier.isEmpty
	}

	private var githubAccountSelections: [GitHubAccountSelection] {
		GitHubCredentialSelectionService().availableAccounts(from: providerAccounts) { account in
			try services.keychain.readSecret(account: account)
		}
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

	private func oauthForm(
		title: String,
		placeholder: String,
		text: Binding<String>,
		selectedAccountID: UUID?,
		connect: @escaping () -> Void,
		selectAccount: @escaping (GitHubAccountSelection) -> Void
	) -> some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(title)
				.font(.headline)
			Label("GitHub OAuth", systemImage: "person.crop.circle.badge.checkmark")
				.font(.subheadline.weight(.semibold))
			Text("Auditorium uses one GitHub OAuth connection for source code and issues.")
				.foregroundStyle(.secondary)
			if !githubAccountSelections.isEmpty {
				HStack {
					Menu("Use Saved GitHub Account") {
						ForEach(githubAccountSelections) { selection in
							Button(selection.displayName) {
								selectAccount(selection)
							}
						}
					}
					if let selectedAccount = githubAccountSelections.first(where: { $0.id == selectedAccountID }) {
						Text("Selected \(selectedAccount.displayName)")
							.foregroundStyle(.secondary)
					}
				}
			}
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
			draft.selectedRepositoryAccountID = nil
			draft.selectedIssueAccountID = nil
			oauthMessage = "GitHub connected with scopes: \(token.scope)"
		}
		catch {
			oauthMessage = error.localizedDescription
		}
	}

	private func selectSavedGitHubAccount(_ selection: GitHubAccountSelection, useForRepository: Bool) {
		do {
			let token =
				try services.keychain.readSecret(account: selection.keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines)
				?? ""
			guard token.isEmpty == false else {
				oauthMessage = "Selected GitHub account is missing its Keychain secret."
				return
			}
			if useForRepository {
				draft.repositoryCredential = token
				draft.selectedRepositoryAccountID = selection.id
				if draft.trimmedIssueCredential.isEmpty {
					draft.issueCredential = token
					draft.selectedIssueAccountID = selection.id
				}
			}
			else {
				draft.issueCredential = token
				draft.selectedIssueAccountID = selection.id
				if draft.trimmedRepositoryCredential.isEmpty {
					draft.repositoryCredential = token
					draft.selectedRepositoryAccountID = selection.id
				}
			}
			oauthMessage = "Using saved GitHub account \(selection.displayName)."
		}
		catch {
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
		}
		catch {
			repositoryLoadMessage = error.localizedDescription
		}
	}

	private func loadIssueFilters() async {
		let token = draft.trimmedIssueCredential.isEmpty ? draft.trimmedRepositoryCredential : draft.trimmedIssueCredential
		let sourceIdentifier = draft.trimmedIssueSourceIdentifier
		guard token.isEmpty == false, sourceIdentifier.isEmpty == false else {
			return
		}
		isLoadingIssueFilters = true
		issueFilterLoadMessage = ""
		defer { isLoadingIssueFilters = false }

		do {
			let provider = GitHubIssueTrackerProvider(
				repositoryFullName: sourceIdentifier,
				issueFilter: GitHubIssueFilter(state: "all"),
				token: token
			)
			let tickets = try await provider.listTickets(projectID: sourceIdentifier)
			availableIssueFilterOptions = GitHubIssueFilterOption.options(from: tickets)
			availableIssuePreview = Array(tickets.prefix(6))
			if draft.issueFilterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				draft.issueFilterName = availableIssueFilterOptions.first?.rawValue ?? "state:open"
			}
			issueFilterLoadMessage = "\(tickets.count) GitHub issues inspected"
		}
		catch {
			availableIssueFilterOptions = []
			availableIssuePreview = []
			issueFilterLoadMessage = error.localizedDescription
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
		availableIssueFilterOptions = []
		availableIssuePreview = []
		issueFilterLoadMessage = ""
	}

	private func createProject() async {
		if let message = ProjectSetupStep.review.validationMessage(for: draft) {
			creationErrorMessage = message
			return
		}
		isCreating = true
		creationErrorMessage = nil
		defer { isCreating = false }
		do {
			let projectID = try services.projectCreation.createProject(
				from: draft,
				context: modelContext,
				workspaceService: services.workspace,
				keychainService: services.keychain
			)
			if draft.importGitHubIssues {
				_ = try await ProjectIssueImportService().importTickets(
					projectID: projectID,
					context: modelContext,
					providerRegistry: services.providerRegistry
				)
			}
			onCreate(projectID)
			dismiss()
		}
		catch {
			creationErrorMessage = ProjectSetupWizard.creationErrorMessage(for: error)
		}
	}

	static func creationErrorMessage(for error: any Error) -> String {
		if let localizedError = error as? LocalizedError,
			let description = localizedError.errorDescription,
			description.isEmpty == false
		{
			return description
		}
		return error.localizedDescription
	}
}
