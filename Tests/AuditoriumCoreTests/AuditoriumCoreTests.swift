import Foundation
import SwiftData
import Testing

@testable import AuditoriumCore

@MainActor
struct AuditoriumCoreTests {
	@Test func workflowPolicyParserReadsCorePolicyValues() throws {
		let policy = try WorkflowPolicyParser().parse(
			"""
			---
			concurrency: 4
			max_retries: 3
			max_retry_backoff_ms: 8000
			branch_prefix: "codex"
			run_tests: false
			open_pull_request: true
			handoff_status: "Needs Review"
			update_issue_labels: true
			---
			Implement the issue.
			"""
		)

		#expect(policy.concurrency == 4)
		#expect(policy.maxRetries == 3)
		#expect(policy.maxRetryBackoffMilliseconds == 8_000)
		#expect(policy.branchPrefix == "codex")
		#expect(policy.runTests == false)
		#expect(policy.openPullRequest)
		#expect(policy.handoffStatus == "Needs Review")
		#expect(policy.updateIssueLabels)
		#expect(policy.prompt == "Implement the issue.")
	}

	@Test func workflowPolicyParserRejectsInvalidBooleanValues() {
		do {
			_ = try WorkflowPolicyParser().parse(
				"""
				---
				run_tests: maybe
				---
				Implement the issue.
				"""
			)
		}
		catch {
			#expect(error.localizedDescription == "run_tests must be a boolean.")
			return
		}
		Issue.record("Expected invalid boolean policy value to throw.")
	}

	@Test func workflowPolicyParserRejectsBlankBranchPrefix() {
		do {
			_ = try WorkflowPolicyParser().parse(
				"""
				---
				branch_prefix: ""
				---
				Implement the issue.
				"""
			)
		}
		catch {
			#expect(error.localizedDescription == "branch_prefix must not be empty.")
			return
		}
		Issue.record("Expected blank branch prefix to throw.")
	}

	@Test func orchestrationRunPlanSnapshotsEnabledQueueInOrder() {
		let projectID = UUID()
		let first = QueueItemRecord(
			ticketID: UUID(),
			projectID: projectID,
			position: 2,
			priority: .high,
			isEnabled: true,
			concurrencyGroup: "ui"
		)
		let disabled = QueueItemRecord(ticketID: UUID(), projectID: projectID, position: 1, priority: .low, isEnabled: false)
		let second = QueueItemRecord(
			ticketID: UUID(),
			projectID: projectID,
			position: 0,
			priority: .urgent,
			isEnabled: true,
			concurrencyGroup: "auth"
		)

		let plan = OrchestrationRunPlan.make(
			queueItems: [first, disabled, second],
			requestedConcurrency: 2,
			workflowPolicyMarkdown: WorkflowPolicy.defaultMarkdown
		)

		#expect(plan.concurrency == 2)
		#expect(plan.queueSnapshot.map(\.ticketID) == [second.ticketID, first.ticketID])
		#expect(plan.queueSnapshot.map(\.concurrencyGroup) == ["auth", "ui"])
		#expect(plan.batches.map(\.count) == [2])
	}

	@Test func runRecordPersistsQueueSnapshotJSON() {
		let first = QueueRunSnapshot(id: UUID(), ticketID: UUID(), position: 0, priority: .high, concurrencyGroup: "ui")
		let second = QueueRunSnapshot(id: UUID(), ticketID: UUID(), position: 1, priority: .low, concurrencyGroup: "backend")
		let run = RunRecord(projectID: UUID())

		run.queueSnapshot = [first, second]

		#expect(run.queueSnapshotJSON.contains(first.ticketID.uuidString))
		#expect(run.queueSnapshot == [first, second])
	}

	@Test func workspaceCleanupRemovesOnlyOwnedTerminalWorkspaces() throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCoreTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let service = ApplicationWorkspaceService(rootDirectory: root)
		let projectID = UUID()
		let failedWorkspace = service.workspacePath(projectID: projectID, ticketExternalID: "CORE-101")
		let reviewWorkspace = service.workspacePath(projectID: projectID, ticketExternalID: "CORE-102")
		for workspace in [failedWorkspace, reviewWorkspace] {
			try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		}
		let unsafePath = root.deletingLastPathComponent().appending(path: "outside-auditorium").path()
		let ticketRuns = [
			TicketRunRecord(runID: UUID(), ticketID: UUID(), workspacePath: failedWorkspace.path(), status: .failed),
			TicketRunRecord(
				runID: UUID(),
				ticketID: UUID(),
				workspacePath: reviewWorkspace.path(),
				status: .needsReview,
				pullRequestURL: "https://github.com/charliewilco/Auditorium/pull/102"
			),
			TicketRunRecord(runID: UUID(), ticketID: UUID(), workspacePath: unsafePath, status: .canceled),
		]

		let result = try service.cleanupTicketWorkspaces(
			projectID: projectID,
			ticketRuns: ticketRuns,
			policy: .removeCanceledAndTerminalWithoutReview
		)

		#expect(result.removed == 1)
		#expect(result.preserved == 2)
		#expect(result.skippedUnsafePaths == [unsafePath])
		#expect(FileManager.default.fileExists(atPath: failedWorkspace.path()) == false)
		#expect(FileManager.default.fileExists(atPath: reviewWorkspace.path()))
	}

	@Test func gitBranchNameSanitizesTicketFields() {
		let ticket = TicketDescriptor(
			provider: .githubIssues,
			externalID: "ISSUE 42",
			title: "Fix OAuth / callback!",
			body: "Body",
			status: .ready,
			labels: [],
			assignee: nil,
			priority: .medium,
			webURL: nil,
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			blockedBy: []
		)

		let branch = GitBranchName.make(prefix: "auditorium", ticketExternalID: ticket.externalID, ticketTitle: ticket.title)

		#expect(branch == "auditorium/issue-42-fix-oauth-callback")
	}

	@Test func githubIssueFilterOptionsDeriveQueriesFromRealIssueMetadata() {
		let options = GitHubIssueFilterOption.options(from: [
			ticket(number: 1, labels: ["Ready for agent", "Bug"], assignee: "charlie"),
			ticket(number: 2, labels: ["ready for agent"], assignee: "charlie"),
			ticket(number: 3, labels: ["Enhancement"], assignee: "octo"),
		])

		#expect(options.map(\.rawValue).prefix(2) == ["state:open", "state:all"])
		#expect(options.contains { $0.title == "Ready for agent" && $0.rawValue == #"state:open label:"Ready for agent""# })
		#expect(options.contains { $0.title == "@charlie" && $0.rawValue == "state:open assignee:charlie" })
		#expect(options.first { $0.title == "Ready for agent" }?.subtitle == "2 issues with this label")
		#expect(options.first { $0.title == "@octo" }?.subtitle == "1 assigned issue")
	}

	@Test func githubCredentialSelectionOnlyIncludesAccountsWithSecrets() throws {
		let keychain = KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		let connected = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub Connected",
			keychainAccount: "connected-\(UUID().uuidString)"
		)
		let missingSecret = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub Missing",
			keychainAccount: "missing-\(UUID().uuidString)"
		)
		let unsupported = ProviderAccountRecord(
			providerKindRaw: "linear",
			displayName: "Linear",
			keychainAccount: "linear-\(UUID().uuidString)"
		)
		try keychain.storeSecret("gho_connected", account: connected.keychainAccount)
		defer { try? keychain.deleteSecret(account: connected.keychainAccount) }

		let selections = GitHubCredentialSelectionService().availableAccounts(
			from: [missingSecret, unsupported, connected]
		) { account in
			try keychain.readSecret(account: account)
		}

		#expect(selections.map(\.id) == [connected.id])
		#expect(selections.first?.displayName == "GitHub Connected")
	}

	@Test func projectCreationReusesSelectedGitHubAccount() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCoreTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let keychain = KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		let account = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub Existing",
			keychainAccount: "existing-\(UUID().uuidString)"
		)
		try keychain.storeSecret("gho_existing", account: account.keychainAccount)
		defer { try? keychain.deleteSecret(account: account.keychainAccount) }
		context.insert(account)
		try context.save()
		let draft = ProjectDraft()
		draft.name = "Existing Account"
		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = "main"
		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.selectedRepositoryAccountID = account.id
		draft.importDemoTickets = false

		let projectID = try ProjectCreationService().createProject(
			from: draft,
			context: context,
			workspaceService: ApplicationWorkspaceService(rootDirectory: root),
			keychainService: keychain
		)

		let accounts = try context.fetch(FetchDescriptor<ProviderAccountRecord>())
		let repository = try #require(context.fetch(FetchDescriptor<RepositoryRecord>()).first { $0.projectID == projectID })
		let issueTracker = try #require(context.fetch(FetchDescriptor<IssueTrackerRecord>()).first { $0.projectID == projectID })
		#expect(accounts.map(\.id) == [account.id])
		#expect(repository.providerAccountID == account.id)
		#expect(issueTracker.providerAccountID == account.id)
	}

	@Test func oauthTokenMetadataNormalizesScopesAndExpiry() {
		let issuedAt = Date(timeIntervalSince1970: 1_000)
		let response = GitHubOAuthTokenResponse(
			accessToken: "gho_access",
			scope: "read:user, repo",
			tokenType: "bearer",
			expiresIn: 3_600,
			refreshToken: "ghr_refresh",
			refreshTokenExpiresIn: 7_200
		)
		let metadata = GitHubOAuthTokenMetadata(response: response, oauthClientID: "client-123", issuedAt: issuedAt)

		#expect(metadata.accessToken == "gho_access")
		#expect(metadata.oauthClientID == "client-123")
		#expect(metadata.grantedScopesRaw == "read:user,repo")
		#expect(metadata.tokenType == "bearer")
		#expect(metadata.accessTokenExpiresAt == Date(timeIntervalSince1970: 4_600))
		#expect(metadata.refreshToken == "ghr_refresh")
		#expect(metadata.refreshTokenExpiresAt == Date(timeIntervalSince1970: 8_200))
	}

	@Test func projectCreationStoresOAuthMetadataAndRefreshSecret() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumCoreTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let keychain = KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		let issuedAt = Date(timeIntervalSince1970: 1_000)
		let draft = ProjectDraft()
		draft.name = "OAuth Metadata"
		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = "main"
		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.importDemoTickets = false
		draft.applyGitHubOAuthTokenResponse(
			GitHubOAuthTokenResponse(
				accessToken: "gho_access",
				scope: "repo,read:user",
				tokenType: "bearer",
				expiresIn: 3_600,
				refreshToken: "ghr_refresh",
				refreshTokenExpiresIn: 7_200
			),
			clientID: "client-123",
			issuedAt: issuedAt
		)

		_ = try ProjectCreationService().createProject(
			from: draft,
			context: context,
			workspaceService: ApplicationWorkspaceService(rootDirectory: root),
			keychainService: keychain
		)

		let account = try #require(context.fetch(FetchDescriptor<ProviderAccountRecord>()).first)
		let refreshTokenAccount = try #require(account.refreshTokenKeychainAccount)
		#expect(account.oauthClientID == "client-123")
		#expect(account.grantedScopes == ["repo", "read:user"])
		#expect(account.tokenType == "bearer")
		#expect(account.accessTokenExpiresAt == Date(timeIntervalSince1970: 4_600))
		#expect(account.refreshTokenExpiresAt == Date(timeIntervalSince1970: 8_200))
		#expect(try keychain.readSecret(account: account.keychainAccount) == "gho_access")
		#expect(try keychain.readSecret(account: refreshTokenAccount) == "ghr_refresh")

		try ProviderRegistry(keychainService: keychain).clearGitHubCredentials(context: context)

		#expect(try keychain.readSecret(account: account.keychainAccount) == nil)
		#expect(try keychain.readSecret(account: refreshTokenAccount) == nil)
	}

	@Test func providerRegistryRefreshesExpiredGitHubToken() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let keychain = KeychainService(service: "co.charliewil.Auditorium.coretests.\(UUID().uuidString)")
		let now = Date(timeIntervalSince1970: 10_000)
		let project = Project(
			name: "Refresh",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
		let accessAccount = "access-\(UUID().uuidString)"
		let refreshAccount = "refresh-\(UUID().uuidString)"
		let account = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub Refresh",
			keychainAccount: accessAccount,
			oauthClientID: "client-123",
			grantedScopesRaw: "repo",
			tokenType: "bearer",
			accessTokenExpiresAt: now.addingTimeInterval(-1),
			refreshTokenKeychainAccount: refreshAccount,
			refreshTokenExpiresAt: now.addingTimeInterval(3_600)
		)
		try keychain.storeSecret("old-access", account: accessAccount)
		try keychain.storeSecret("old-refresh", account: refreshAccount)
		defer {
			try? keychain.deleteSecret(account: accessAccount)
			try? keychain.deleteSecret(account: refreshAccount)
		}
		context.insert(project)
		context.insert(
			RepositoryRecord(
				provider: .github,
				owner: "charliewilco",
				name: "Auditorium",
				fullName: "charliewilco/Auditorium",
				cloneURL: "https://github.com/charliewilco/Auditorium.git",
				webURL: "https://github.com/charliewilco/Auditorium",
				defaultBranch: "main",
				providerAccountID: account.id,
				projectID: project.id
			)
		)
		context.insert(account)
		try context.save()
		let payload = """
			{
				"access_token": "new-access",
				"scope": "repo,read:user",
				"token_type": "bearer",
				"expires_in": 900,
				"refresh_token": "new-refresh",
				"refresh_token_expires_in": 1800
			}
			"""
		let registry = ProviderRegistry(
			keychainService: keychain,
			githubOAuthService: GitHubOAuthDeviceFlowService(transport: MockGitHubTransport(payload: payload)),
			refreshSkew: 60,
			now: { now }
		)

		let token = try await registry.requireGitHubToken(for: project, context: context, operation: "testing refresh")

		#expect(token == "new-access")
		#expect(try keychain.readSecret(account: accessAccount) == "new-access")
		#expect(try keychain.readSecret(account: refreshAccount) == "new-refresh")
		#expect(account.grantedScopes == ["repo", "read:user"])
		#expect(account.accessTokenExpiresAt == now.addingTimeInterval(900))
		#expect(account.refreshTokenExpiresAt == now.addingTimeInterval(1_800))
		#expect(account.lastValidatedAt == now)
	}

	@Test func modelIntegrityValidatorRejectsPersistedSecretMaterial() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		context.insert(
			Project(
				name: "Secret Project",
				repositoryProviderKind: .github,
				repositoryName: "charliewilco/Auditorium",
				repositoryURL: "https://github.com/charliewilco/Auditorium?token=ghp_abcdefghijklmnopqrstuvwxyz",
				defaultBranch: "main",
				issueProviderKind: .githubIssues,
				runtimeProviderKind: .mockRuntime,
				agentProviderKind: .mockAgent
			)
		)

		let issues = try ModelIntegrityValidator.validate(context: context)

		#expect(issues.contains { $0.model == "Project" && $0.field == "repositoryURL" })
	}

	@Test func projectSetupStepValidationBlocksMissingCredentialsAndRequiredFields() {
		let draft = ProjectDraft()

		#expect(ProjectSetupStep.repositoryProvider.validationMessage(for: draft) == nil)
		#expect(ProjectSetupStep.repositoryCredentials.validationMessage(for: draft)?.contains("Connect GitHub") == true)

		draft.repositoryCredential = "gho_example"
		#expect(ProjectSetupStep.issueCredentials.validationMessage(for: draft) == nil)

		draft.name = " "
		#expect(ProjectSetupStep.repository.validationMessage(for: draft) == "Project name is required.")

		draft.name = "Auditorium"
		draft.repositoryName = " "
		#expect(ProjectSetupStep.repository.validationMessage(for: draft) == "Repository is required.")

		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = " "
		#expect(ProjectSetupStep.repository.validationMessage(for: draft) == "Repository URL is required.")

		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = " "
		#expect(ProjectSetupStep.repository.validationMessage(for: draft) == "Default branch is required.")
	}

	@Test func projectSetupStepValidationAcceptsCompleteRealGitHubDraft() {
		let draft = ProjectDraft()
		draft.name = "Auditorium"
		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = "main"
		draft.repositoryCredential = "gho_example"
		draft.issueCredential = "gho_example"
		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.issueTrackerURL = "https://github.com/charliewilco/Auditorium/issues"
		draft.importGitHubIssues = true
		draft.branchPrefix = "codex"

		for step in ProjectSetupStep.allCases {
			#expect(step.validationMessage(for: draft) == nil)
		}
	}

	@Test func projectSetupStepValidationChecksIssueSourceAndRunDefaults() {
		let draft = ProjectDraft()
		draft.issueCredential = "gho_example"
		draft.issueSourceName = " "

		#expect(ProjectSetupStep.issueSource.validationMessage(for: draft) == "Issue source name is required.")

		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = " "
		#expect(ProjectSetupStep.issueSource.validationMessage(for: draft) == "Issue source identifier is required.")

		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.issueTrackerURL = " "
		draft.importGitHubIssues = true
		#expect(ProjectSetupStep.issueSource.validationMessage(for: draft) == "Issue tracker URL is required when importing GitHub issues.")

		draft.issueTrackerURL = "https://github.com/charliewilco/Auditorium/issues"
		draft.concurrency = 0
		#expect(ProjectSetupStep.runDefaults.validationMessage(for: draft) == "Concurrency must be at least 1.")

		draft.concurrency = 1
		draft.maxRetries = -1
		#expect(ProjectSetupStep.runDefaults.validationMessage(for: draft) == "Max retries cannot be negative.")

		draft.maxRetries = 0
		draft.branchPrefix = " "
		#expect(ProjectSetupStep.runDefaults.validationMessage(for: draft) == "Branch prefix is required.")
	}

	private func ticket(number: Int, labels: [String], assignee: String?) -> TicketDescriptor {
		TicketDescriptor(
			provider: .githubIssues,
			externalID: "\(number)",
			title: "Issue \(number)",
			body: "Body",
			status: .ready,
			labels: labels,
			assignee: assignee,
			priority: .medium,
			webURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/\(number)"),
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 0),
			estimatedComplexity: 1,
			blockedBy: []
		)
	}
}

private struct MockGitHubTransport: GitHubAPITransport {
	let payload: String
	let statusCode: Int
	let headers: [String: String]

	init(payload: String, statusCode: Int = 200, headers: [String: String] = [:]) {
		self.payload = payload
		self.statusCode = statusCode
		self.headers = headers
	}

	func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
		return (Data(payload.utf8), response)
	}
}
