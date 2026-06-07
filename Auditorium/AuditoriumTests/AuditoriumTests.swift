import Foundation
import SwiftData
import Testing
@testable import Auditorium

@MainActor
struct AuditoriumTests {
	@Test func workspacePathsAreDeterministicAndSanitized() {
		let service = ApplicationWorkspaceService()
		let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
		let first = service.workspacePath(projectID: projectID, ticketExternalID: "BUR-101 Fix OAuth")
		let second = service.workspacePath(projectID: projectID, ticketExternalID: "BUR-101 Fix OAuth")

		#expect(first == second)
		#expect(first.path().contains("bur-101-fix-oauth"))
	}

	@Test func workspaceManifestPersistsInspectableJSON() throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let service = ApplicationWorkspaceService(rootDirectory: root)
		let projectID = UUID()
		let runID = UUID()
		let ticketRunID = UUID()
		let ticketID = UUID()
		let workspace = service.workspacePath(projectID: projectID, ticketExternalID: "MAN-101")
		let manifest = WorkspaceManifest(
			projectID: projectID,
			runID: runID,
			ticketRunID: ticketRunID,
			ticketID: ticketID,
			ticketExternalID: "MAN-101",
			repository: "charliewilco/Auditorium",
			workspacePath: workspace.path(),
			branchName: "auditorium/man-101",
			runtimeProvider: RuntimeProviderKind.mockRuntime.rawValue,
			agentProvider: AgentProviderKind.mockAgent.rawValue,
			createdAt: Date(timeIntervalSince1970: 1_780_000_000)
		)

		let url = try service.writeWorkspaceManifest(manifest, workspace: workspace)
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let decoded = try decoder.decode(WorkspaceManifest.self, from: Data(contentsOf: url))

		#expect(url == service.workspaceManifestPath(workspace: workspace))
		#expect(decoded == manifest)
	}

	@Test func queueOrderingMovesItems() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let projectID = UUID()
		let first = QueueItemRecord(ticketID: UUID(), projectID: projectID, position: 0, priority: .high)
		let second = QueueItemRecord(ticketID: UUID(), projectID: projectID, position: 1, priority: .medium)
		context.insert(first)
		context.insert(second)
		try context.save()

		try QueueService().moveQueueItems(from: IndexSet(integer: 0), to: 2, projectID: projectID, context: context)
		let ordered = try context.fetch(FetchDescriptor<QueueItemRecord>()).sorted { $0.position < $1.position }

		#expect(ordered.map(\.ticketID) == [second.ticketID, first.ticketID])
	}

	@Test func queueServiceAddsSelectedTicketsAndAvoidsDuplicates() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let projectID = UUID()
		let first = TicketRecord(
			provider: .githubIssues,
			externalID: "1",
			title: "First issue",
			body: "",
			status: .ready,
			labels: [],
			assignee: nil,
			priority: .high,
			webURL: "",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			sourceProjectID: projectID
		)
		let second = TicketRecord(
			provider: .githubIssues,
			externalID: "2",
			title: "Second issue",
			body: "",
			status: .ready,
			labels: [],
			assignee: nil,
			priority: .medium,
			webURL: "",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			sourceProjectID: projectID
		)
		context.insert(first)
		context.insert(second)
		try context.save()

		try QueueService().addTickets([first.id, second.id], projectID: projectID, context: context)
		try QueueService().addTickets([first.id], projectID: projectID, context: context)
		let queueItems = try context.fetch(FetchDescriptor<QueueItemRecord>()).sorted { $0.position < $1.position }

		#expect(queueItems.count == 2)
		#expect(Set(queueItems.map(\.ticketID)) == Set([first.id, second.id]))
		#expect(Set(queueItems.map(\.position)) == Set([0, 1]))
		#expect(first.status == .queued)
		#expect(second.status == .queued)
	}

	@Test func projectCreationCommitsRepositoryIssueTrackerTicketsAndNoRuns() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = ApplicationWorkspaceService(rootDirectory: root)
		let draft = ProjectDraft()
		draft.name = "Creation Test"
		draft.repositoryName = "charlie/creation-test"
		draft.repositoryURL = "https://github.com/charlie/creation-test"
		draft.defaultBranch = "next"
		draft.issueSourceName = "Creation Team"
		draft.issueSourceIdentifier = "creation-team"
		draft.issueFilterName = "Ready"
		draft.concurrency = 5
		draft.maxRetries = 1

		let projectID = try ProjectCreationService().createProject(from: draft, context: context, workspaceService: workspace)
		let projects = try context.fetch(FetchDescriptor<Project>())
		let repositories = try context.fetch(FetchDescriptor<RepositoryRecord>())
		let issueTrackers = try context.fetch(FetchDescriptor<IssueTrackerRecord>())
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		let runs = try context.fetch(FetchDescriptor<RunRecord>())

		#expect(projects.map(\.id) == [projectID])
		#expect(projects.first?.workflowPolicyMarkdown.contains("concurrency: 5") == true)
		#expect(projects.first?.workflowPolicyMarkdown.contains("max_retries: 1") == true)
		#expect(repositories.count == 1)
		#expect(repositories.first?.projectID == projectID)
		#expect(repositories.first?.defaultBranch == "next")
		#expect(issueTrackers.count == 1)
		#expect(issueTrackers.first?.projectID == projectID)
		#expect(issueTrackers.first?.displayName == "Creation Team")
		#expect(tickets.count == DemoTickets.all.count)
		#expect(runs.isEmpty)
		#expect(FileManager.default.fileExists(atPath: workspace.repositoryDirectory(projectID: projectID).path()))
	}

	@Test func invalidProjectDraftDoesNotPersistRows() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let draft = ProjectDraft()
		draft.name = " "
		var didThrow = false

		do {
			_ = try ProjectCreationService().createProject(from: draft, context: context, workspaceService: ApplicationWorkspaceService(rootDirectory: root))
		} catch ProjectCreationError.invalidDraft {
			didThrow = true
		}

		#expect(didThrow)
		#expect(try context.fetch(FetchDescriptor<Project>()).isEmpty)
		#expect(try context.fetch(FetchDescriptor<RepositoryRecord>()).isEmpty)
		#expect(try context.fetch(FetchDescriptor<IssueTrackerRecord>()).isEmpty)
	}

	@Test func modelIntegrityValidatorAcceptsValidProjectCreationRows() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let draft = ProjectDraft()
		draft.name = "Integrity Test"
		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = "main"
		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.importDemoTickets = false

		_ = try ProjectCreationService().createProject(from: draft, context: context, workspaceService: ApplicationWorkspaceService(rootDirectory: root))

		#expect(try ModelIntegrityValidator.validate(context: context).isEmpty)
	}

	@Test func existingAppDataSurvivesSchemaMigration() throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumMigrationTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let storeURL = root.appending(path: "Auditorium.store")
		let ids = try writeLegacyV1Store(at: storeURL)

		let container = try AppSchema.makeModelContainer(storeURL: storeURL)
		let context = container.mainContext
		let projects = try context.fetch(FetchDescriptor<Project>())
		let repositories = try context.fetch(FetchDescriptor<RepositoryRecord>())
		let issueTrackers = try context.fetch(FetchDescriptor<IssueTrackerRecord>())
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())
		let queueItems = try context.fetch(FetchDescriptor<QueueItemRecord>())
		let runs = try context.fetch(FetchDescriptor<RunRecord>())
		let ticketRuns = try context.fetch(FetchDescriptor<TicketRunRecord>())
		let pullRequests = try context.fetch(FetchDescriptor<PullRequestRecord>())
		let events = try context.fetch(FetchDescriptor<RuntimeEventRecord>())
		let reports = try context.fetch(FetchDescriptor<ReportRecord>())
		let accounts = try context.fetch(FetchDescriptor<ProviderAccountRecord>())

		#expect(AppSchema.MigrationPlan.schemas.count == 2)
		#expect(AppSchema.MigrationPlan.stages.count == 1)
		#expect(projects.map(\.id) == [ids.projectID])
		#expect(projects.first?.name == "Migrated Project")
		#expect(repositories.first?.projectID == ids.projectID)
		#expect(issueTrackers.first?.projectID == ids.projectID)
		#expect(tickets.first?.sourceProjectID == ids.projectID)
		#expect(queueItems.first?.ticketID == ids.ticketID)
		#expect(runs.first?.id == ids.runID)
		#expect(ticketRuns.first?.runID == ids.runID)
		#expect(pullRequests.first?.ticketRunID == ids.ticketRunID)
		#expect(events.first?.runID == ids.runID)
		#expect(reports.first?.runID == ids.runID)
		#expect(accounts.first?.displayName == "GitHub")
		#expect(try ModelIntegrityValidator.validate(context: context).isEmpty)
	}

	@Test func modelIntegrityValidatorFlagsCorruptPersistedRows() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Corrupt",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
		project.name = " "
		project.repositoryProviderKindRaw = "dropbox"
		let event = RuntimeEventRecord(runID: UUID(), level: .info, category: .orchestration, message: "Event", metadataJSON: "{")
		event.levelRaw = "verbose"
		let ticketRun = TicketRunRecord(runID: UUID(), ticketID: UUID(), status: .running, retryCount: -1, confidence: 1.5)
		context.insert(project)
		context.insert(event)
		context.insert(ticketRun)
		try context.save()

		let issues = try ModelIntegrityValidator.validate(context: context)
		let fields = Set(issues.map { "\($0.model).\($0.field)" })

		#expect(fields.contains("Project.name"))
		#expect(fields.contains("Project.repositoryProviderKindRaw"))
		#expect(fields.contains("RuntimeEventRecord.levelRaw"))
		#expect(fields.contains("RuntimeEventRecord.metadataJSON"))
		#expect(fields.contains("TicketRunRecord.retryCount"))
		#expect(fields.contains("TicketRunRecord.confidence"))
	}

	@Test func modelIntegrityValidatorDetectsSecretMaterialInPersistedRows() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let projectID = UUID()
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "SEC-1",
			title: "Do not persist tokens",
			body: "Leaked token github_pat_1234567890abcdefghijklmnopqrst",
			status: .ready,
			labels: [],
			assignee: nil,
			priority: .high,
			webURL: "https://github.com/charliewilco/Auditorium/issues/1",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			sourceProjectID: projectID
		)
		let account = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub",
			keychainAccount: "gho_1234567890abcdefghijklmnopqrst"
		)
		context.insert(ticket)
		context.insert(account)
		try context.save()

		let issues = try ModelIntegrityValidator.validate(context: context)
		let secretFields = Set(issues.filter { $0.reason.contains("secret") }.map { "\($0.model).\($0.field)" })

		#expect(secretFields == Set(["TicketRecord.body", "ProviderAccountRecord.keychainAccount"]))
	}

	@Test func projectCreationRejectsPersistedSecretMaterial() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let draft = ProjectDraft()
		draft.name = "Secret Project"
		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = "https://github.com/charliewilco/Auditorium?token=github_pat_1234567890abcdefghijklmnopqrst"
		draft.defaultBranch = "main"
		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.importDemoTickets = false
		var rejectedFields: Set<String> = []

		do {
			_ = try ProjectCreationService().createProject(from: draft, context: context, workspaceService: ApplicationWorkspaceService(rootDirectory: root))
		} catch ModelIntegrityError.invalidRows(let issues) {
			rejectedFields = Set(issues.map { "\($0.model).\($0.field)" })
		}

		#expect(rejectedFields.contains("Project.repositoryURL"))
		#expect(rejectedFields.contains("RepositoryRecord.cloneURL"))
	}

	@Test func issueImportRejectsPersistedSecretMaterial() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let draft = ProjectDraft()
		draft.name = "Import Secret Test"
		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = "main"
		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.importDemoTickets = false
		let projectID = try ProjectCreationService().createProject(from: draft, context: context, workspaceService: ApplicationWorkspaceService(rootDirectory: root))
		let project = try #require(try context.fetch(FetchDescriptor<Project>()).first { $0.id == projectID })
		let provider = StaticIssueTrackerProvider(tickets: [
			TicketDescriptor(
				provider: .githubIssues,
				externalID: "SEC-2",
				title: "Import should reject secret",
				body: "Leaked bearer Bearer abcdefghijklmnopqrstuvwx1234567890",
				status: .ready,
				labels: [],
				assignee: nil,
				priority: .high,
				webURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/2"),
				createdAt: .now,
				updatedAt: .now,
				estimatedComplexity: 1,
				blockedBy: []
			)
		])
		var rejectedFields: Set<String> = []

		do {
			_ = try await ProjectIssueImportService().importTickets(for: project, context: context, provider: provider)
		} catch ModelIntegrityError.invalidRows(let issues) {
			rejectedFields = Set(issues.map { "\($0.model).\($0.field)" })
		}

		#expect(rejectedFields == Set(["TicketRecord.body"]))
	}

	@Test func ticketDescriptorNormalizesProviderFields() {
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "BUR-999",
			title: "Test ticket",
			body: "Body",
			status: .ready,
			labels: ["tests"],
			assignee: nil,
			priority: .urgent,
			webURL: "https://github.com/charlie/burton-ios/issues/999",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 5,
			sourceProjectID: UUID()
		)

		#expect(ticket.descriptor.provider == .githubIssues)
		#expect(ticket.descriptor.priority == .urgent)
		#expect(ticket.descriptor.externalID == "BUR-999")
	}

	@Test func mockOutcomePolicyIsDeterministic() {
		#expect(MockOutcomePolicy.outcome(for: "BUR-101") == .completed)
		#expect(MockOutcomePolicy.outcome(for: "BUR-103") == .blocked)
		#expect(MockOutcomePolicy.outcome(for: "BUR-106") == .failed)
	}

	@Test func githubAdaptersUseRepeatableOAuthProviderShape() {
		let sourceCodeProvider: any SourceCodeProvider = GitHubRepositoryProvider()
		let issueTrackerProvider: any IssueTrackerProvider = GitHubIssueTrackerProvider()

		#expect(sourceCodeProvider.kind == .github)
		#expect(issueTrackerProvider.kind == .githubIssues)
		#expect(sourceCodeProvider.authentication.method == .oauth)
		#expect(issueTrackerProvider.authentication.method == .oauth)
		#expect(sourceCodeProvider.authentication.oauth?.authorizationEndpoint.absoluteString == "https://github.com/login/oauth/authorize")
		#expect(issueTrackerProvider.authentication.oauth?.scopes.contains("repo") == true)
	}

	@Test func githubAuthenticationStateReflectsKeychainBackedConnection() {
		let account = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub OAuth for charliewilco/Auditorium",
			keychainAccount: "project-github-oauth"
		)

		let connected = GitHubAuthenticationState(providerAccounts: [account]) { keychainAccount in
			keychainAccount == "project-github-oauth" ? "gho_token" : nil
		}
		let missingSecret = GitHubAuthenticationState(providerAccounts: [account]) { _ in nil }
		let disconnected = GitHubAuthenticationState(providerAccounts: []) { _ in "unused" }

		#expect(connected.status == .connected)
		#expect(connected.isConnected)
		#expect(connected.displayName == "GitHub OAuth for charliewilco/Auditorium")
		#expect(connected.detail.contains("Keychain"))
		#expect(missingSecret.status == .missingSecret)
		#expect(disconnected.status == .disconnected)
	}

	@Test func githubRepositoryProviderListsRepositoriesFromAPI() async throws {
		let payload = """
		[
			{
				"name": "Auditorium",
				"full_name": "charliewilco/Auditorium",
				"clone_url": "https://github.com/charliewilco/Auditorium.git",
				"html_url": "https://github.com/charliewilco/Auditorium",
				"default_branch": "main",
				"owner": { "login": "charliewilco" }
			}
		]
		"""
		let transport = RecordingGitHubTransport(responses: [MockGitHubResponse(payload: payload)])
		let client = GitHubAPIClient(token: "test", transport: transport)
		let provider = GitHubRepositoryProvider(client: client)

		let repositories = try await provider.listRepositories()
		let requestURLs = await transport.requestedURLs()
		let firstQuery = URLComponents(url: try #require(requestURLs.first), resolvingAgainstBaseURL: false)?.queryItems ?? []

		#expect(repositories.map(\.fullName) == ["charliewilco/Auditorium"])
		#expect(repositories.first?.defaultBranch == "main")
		#expect(firstQuery.first(named: "per_page")?.value == "100")
		#expect(firstQuery.first(named: "sort")?.value == "pushed")
	}

	@Test func githubRepositoryProviderFetchesRepositoryMetadata() async throws {
		let payload = """
		{
			"name": "Auditorium",
			"full_name": "charliewilco/Auditorium",
			"clone_url": "https://github.com/charliewilco/Auditorium.git",
			"html_url": "https://github.com/charliewilco/Auditorium",
			"default_branch": "main",
			"owner": { "login": "charliewilco" }
		}
		"""
		let transport = RecordingGitHubTransport(responses: [MockGitHubResponse(payload: payload)])
		let client = GitHubAPIClient(token: "test", transport: transport)
		let provider = GitHubRepositoryProvider(client: client)

		let repository = try await provider.fetchRepository(fullName: "charliewilco/Auditorium")
		let requestURLs = await transport.requestedURLs()

		#expect(repository.fullName == "charliewilco/Auditorium")
		#expect(repository.defaultBranch == "main")
		#expect(requestURLs.first?.path == "/repos/charliewilco/Auditorium")
	}

	@Test func sourceProviderCreatesDeterministicTicketBranchNames() {
		let provider = GitHubRepositoryProvider()
		let ticket = TicketDescriptor(
			provider: .githubIssues,
			externalID: "ISSUE #42",
			title: "Fix OAuth Refresh Race!",
			body: "",
			status: .ready,
			labels: [],
			assignee: nil,
			priority: .medium,
			webURL: nil,
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 0),
			estimatedComplexity: 1,
			blockedBy: []
		)

		let first = provider.ticketBranchName(for: ticket, prefix: "Auditorium Tickets")
		let second = provider.ticketBranchName(for: ticket, prefix: "Auditorium Tickets")

		#expect(first == second)
		#expect(first == "auditorium-tickets/issue-42-fix-oauth-refresh-race")
	}

	@Test func githubRepositoryProviderCommitsAndPushesBranchWithoutForce() async throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumGitTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let remote = root.appending(path: "remote.git")
		let local = root.appending(path: "local")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try await git(["init", "--bare", "--initial-branch=main", remote.path()])
		try await git(["clone", remote.path(), local.path()])
		try await git(["config", "user.name", "Auditorium Tests"], in: local)
		try await git(["config", "user.email", "auditorium-tests@local.invalid"], in: local)
		try "initial\n".write(to: local.appending(path: "README.md"), atomically: true, encoding: .utf8)
		try await git(["add", "README.md"], in: local)
		try await git(["commit", "-m", "Initial commit"], in: local)
		try await git(["push", "-u", "origin", "main"], in: local)
		let provider = GitHubRepositoryProvider()
		let branch = "auditorium/issue-42-test-branch"

		try await provider.createBranch(named: branch, in: local)
		try "changed\n".write(to: local.appending(path: "CHANGELOG.md"), atomically: true, encoding: .utf8)
		let committed = try await provider.commitChanges(in: local, message: "Apply test change")
		try await provider.pushBranch(named: branch, from: local)
		let remoteBranches = try await git(["--git-dir", remote.path(), "branch", "--list", branch])

		#expect(committed)
		#expect(remoteBranches.standardOutput.contains(branch))
		#expect(GitHubRepositoryProvider.pushArguments(branchName: branch).contains("--force") == false)
	}

	@Test func githubRepositoryProviderFetchesOpenPullRequestCheckStatus() async throws {
		let pullRequestPayload = """
		{
			"number": 12,
			"title": "ISSUE-12: Ship work",
			"html_url": "https://github.com/charliewilco/Auditorium/pull/12",
			"state": "open",
			"draft": false,
			"merged": false,
			"head": { "ref": "auditorium/issue-12", "sha": "abc123" },
			"base": { "ref": "main", "sha": "def456" }
		}
		"""
		let statusPayload = """
		{
			"state": "success"
		}
		"""
		let checkRunsPayload = """
		{
			"check_runs": [
				{ "status": "completed", "conclusion": "success" }
			]
		}
		"""
		let transport = RecordingGitHubTransport(responses: [
			MockGitHubResponse(payload: pullRequestPayload),
			MockGitHubResponse(payload: statusPayload),
			MockGitHubResponse(payload: checkRunsPayload)
		])
		let provider = GitHubRepositoryProvider(client: GitHubAPIClient(token: "test", transport: transport))

		let pullRequest = try await provider.fetchPullRequest(repositoryFullName: "charliewilco/Auditorium", number: 12)
		let requestURLs = await transport.requestedURLs()

		#expect(pullRequest.status == .open)
		#expect(pullRequest.checksStatus == .passed)
		#expect(pullRequest.branchName == "auditorium/issue-12")
		#expect(pullRequest.targetBranch == "main")
		#expect(requestURLs.map(\.path) == [
			"/repos/charliewilco/Auditorium/pulls/12",
			"/repos/charliewilco/Auditorium/commits/abc123/status",
			"/repos/charliewilco/Auditorium/commits/abc123/check-runs"
		])
		#expect(requestURLs.last?.query == "per_page=100")
	}

	@Test func githubRepositoryProviderMapsClosedPullRequestAndFailedCheckRuns() async throws {
		let pullRequestPayload = """
		{
			"number": 13,
			"title": "ISSUE-13: Failed work",
			"html_url": "https://github.com/charliewilco/Auditorium/pull/13",
			"state": "closed",
			"draft": false,
			"merged": false,
			"head": { "ref": "auditorium/issue-13", "sha": "badcafe" },
			"base": { "ref": "main", "sha": "def456" }
		}
		"""
		let statusPayload = """
		{
			"state": "success"
		}
		"""
		let checkRunsPayload = """
		{
			"check_runs": [
				{ "status": "completed", "conclusion": "failure" }
			]
		}
		"""
		let transport = RecordingGitHubTransport(responses: [
			MockGitHubResponse(payload: pullRequestPayload),
			MockGitHubResponse(payload: statusPayload),
			MockGitHubResponse(payload: checkRunsPayload)
		])
		let provider = GitHubRepositoryProvider(client: GitHubAPIClient(token: "test", transport: transport))

		let pullRequest = try await provider.fetchPullRequest(repositoryFullName: "charliewilco/Auditorium", number: 13)

		#expect(pullRequest.status == .closed)
		#expect(pullRequest.checksStatus == .failed)
	}

	@Test func githubIssueProviderNormalizesIssuesAndSkipsPullRequests() async throws {
		let payload = """
		[
			{
				"id": 123,
				"node_id": "I_kwDO",
				"number": 42,
				"title": "Implement runner",
				"body": "Ship the flow",
				"html_url": "https://github.com/charliewilco/Auditorium/issues/42",
				"state": "open",
				"labels": [{ "name": "agent" }],
				"assignees": [{ "login": "charliewilco" }],
				"created_at": "2026-06-06T12:00:00Z",
				"updated_at": "2026-06-06T13:00:00Z"
			},
			{
				"id": 124,
				"number": 43,
				"title": "A pull request",
				"body": "",
				"html_url": "https://github.com/charliewilco/Auditorium/pull/43",
				"state": "open",
				"labels": [],
				"assignees": [],
				"created_at": "2026-06-06T12:00:00Z",
				"updated_at": "2026-06-06T13:00:00Z",
				"pull_request": {}
			}
		]
		"""
		let client = GitHubAPIClient(token: "test", transport: MockGitHubTransport(payload: payload))
		let provider = GitHubIssueTrackerProvider(repositoryFullName: "charliewilco/Auditorium", client: client)

		let tickets = try await provider.listTickets(projectID: "ignored")

		#expect(tickets.count == 1)
		#expect(tickets.first?.externalID == "42")
		#expect(tickets.first?.labels == ["agent"])
		#expect(tickets.first?.assignee == "charliewilco")
	}

	@Test func githubIssueProviderAppliesFilterAndPaginatesIssues() async throws {
		let pageOne = """
		[
			{
				"id": 123,
				"number": 42,
				"title": "Implement runner",
				"body": "Ship the flow",
				"html_url": "https://github.com/charliewilco/Auditorium/issues/42",
				"state": "open",
				"labels": [{ "name": "ready for agent" }],
				"assignees": [{ "login": "octo" }],
				"created_at": "2026-06-06T12:00:00Z",
				"updated_at": "2026-06-06T13:00:00Z"
			}
		]
		"""
		let pageTwo = """
		[
			{
				"id": 124,
				"number": 43,
				"title": "Second issue",
				"body": "Continue the flow",
				"html_url": "https://github.com/charliewilco/Auditorium/issues/43",
				"state": "closed",
				"labels": [{ "name": "ready for agent" }],
				"assignees": [],
				"created_at": "2026-06-06T12:00:00Z",
				"updated_at": "2026-06-06T13:00:00Z"
			},
			{
				"id": 125,
				"number": 44,
				"title": "Pull request",
				"body": "",
				"html_url": "https://github.com/charliewilco/Auditorium/pull/44",
				"state": "open",
				"labels": [],
				"assignees": [],
				"created_at": "2026-06-06T12:00:00Z",
				"updated_at": "2026-06-06T13:00:00Z",
				"pull_request": {}
			}
		]
		"""
		let transport = RecordingGitHubTransport(responses: [
			MockGitHubResponse(payload: pageOne, headers: ["Link": "<https://api.github.com/repos/charliewilco/Auditorium/issues?page=2>; rel=\"next\""]),
			MockGitHubResponse(payload: pageTwo)
		])
		let client = GitHubAPIClient(token: "test", transport: transport)
		let provider = GitHubIssueTrackerProvider(
			repositoryFullName: "charliewilco/Auditorium",
			issueFilter: GitHubIssueFilter(rawValue: "state:all label:\"ready for agent\" assignee:octo sort:updated direction:asc"),
			client: client
		)

		let tickets = try await provider.listTickets(projectID: "ignored")
		let requestURLs = await transport.requestedURLs()
		let firstQuery = URLComponents(url: try #require(requestURLs.first), resolvingAgainstBaseURL: false)?.queryItems ?? []

		#expect(tickets.map(\.externalID) == ["42", "43"])
		#expect(requestURLs.count == 2)
		#expect(firstQuery.first(named: "state")?.value == "all")
		#expect(firstQuery.first(named: "labels")?.value == "ready for agent")
		#expect(firstQuery.first(named: "assignee")?.value == "octo")
		#expect(firstQuery.first(named: "sort")?.value == "updated")
		#expect(firstQuery.first(named: "direction")?.value == "asc")
		#expect(firstQuery.first(named: "page")?.value == "1")
	}

	@Test func githubIssueProviderFetchesIssueDetails() async throws {
		let payload = """
		{
			"id": 123,
			"number": 42,
			"title": "Implement runner",
			"body": "Ship the flow",
			"html_url": "https://github.com/charliewilco/Auditorium/issues/42",
			"state": "open",
			"labels": [{ "name": "agent" }],
			"assignees": [{ "login": "charliewilco" }],
			"created_at": "2026-06-06T12:00:00Z",
			"updated_at": "2026-06-06T13:00:00Z"
		}
		"""
		let client = GitHubAPIClient(token: "test", transport: MockGitHubTransport(payload: payload))
		let provider = GitHubIssueTrackerProvider(repositoryFullName: "charliewilco/Auditorium", client: client)

		let ticket = try await provider.fetchTicket(projectID: "ignored", ticketID: "42")

		#expect(ticket.externalID == "42")
		#expect(ticket.title == "Implement runner")
		#expect(ticket.webURL?.absoluteString == "https://github.com/charliewilco/Auditorium/issues/42")
	}

	@Test func githubAPIClientReportsRateLimitErrors() async {
		let reset = String(Int(Date(timeIntervalSince1970: 1_780_000_000).timeIntervalSince1970))
		let client = GitHubAPIClient(
			token: "test",
			transport: MockGitHubTransport(payload: "{}", statusCode: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset])
		)
		var message = ""

		do {
			_ = try await client.listIssues(repositoryFullName: "charliewilco/Auditorium")
		} catch {
			message = error.localizedDescription
		}

		#expect(message.contains("rate limit"))
		#expect(message.contains("2026"))
	}

	@Test func githubIssueProviderAppliesWorkflowHandoffLabelOnlyWhenEnabled() async throws {
		let disabledPolicy = try WorkflowPolicyParser().parse("""
		---
		handoff_status: "Needs Review"
		update_issue_labels: false
		---
		Prompt
		""")
		let disabledTransport = RecordingGitHubTransport(responses: [MockGitHubResponse(payload: "[]")])
		let disabledProvider = GitHubIssueTrackerProvider(repositoryFullName: "charliewilco/Auditorium", client: GitHubAPIClient(token: "test", transport: disabledTransport))

		try await disabledProvider.applyWorkflowHandoffLabel(ticketID: "42", policy: disabledPolicy)

		#expect(await disabledTransport.requestedURLs().isEmpty)

		let enabledPolicy = try WorkflowPolicyParser().parse("""
		---
		handoff_status: "Needs Review"
		update_issue_labels: true
		---
		Prompt
		""")
		let enabledTransport = RecordingGitHubTransport(responses: [MockGitHubResponse(payload: #"[{ "name": "Needs Review" }]"#)])
		let enabledProvider = GitHubIssueTrackerProvider(repositoryFullName: "charliewilco/Auditorium", client: GitHubAPIClient(token: "test", transport: enabledTransport))

		try await enabledProvider.applyWorkflowHandoffLabel(ticketID: "42", policy: enabledPolicy)
		let requestURLs = await enabledTransport.requestedURLs()
		let requestMethods = await enabledTransport.requestedMethods()
		let requestBodies = await enabledTransport.requestedBodyStrings()

		#expect(requestURLs.first?.path == "/repos/charliewilco/Auditorium/issues/42/labels")
		#expect(requestMethods.first == "POST")
		#expect(requestBodies.first?.contains("Needs Review") == true)
	}

	@Test func projectIssueImportCreatesAndUpdatesTicketsWithoutDuplicates() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let project = Project(
			name: "Auditorium",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
		context.insert(project)
		try context.save()
		let createdAt = Date(timeIntervalSince1970: 1_780_000_000)
		let provider = StaticIssueTrackerProvider(tickets: [
			TicketDescriptor(
				provider: .githubIssues,
				externalID: "42",
				title: "Import issues",
				body: "Original body",
				status: .ready,
				labels: ["agent"],
				assignee: "charliewilco",
				priority: .medium,
				webURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/42"),
				createdAt: createdAt,
				updatedAt: createdAt,
				estimatedComplexity: 3,
				blockedBy: []
			)
		])

		let imported = try await ProjectIssueImportService().importTickets(for: project, context: context, provider: provider)

		#expect(imported == 1)
		#expect(try context.fetch(FetchDescriptor<TicketRecord>()).count == 1)

		let updateProvider = StaticIssueTrackerProvider(tickets: [
			TicketDescriptor(
				provider: .githubIssues,
				externalID: "42",
				title: "Import issues from GitHub",
				body: "Updated body",
				status: .ready,
				labels: ["agent", "github"],
				assignee: nil,
				priority: .high,
				webURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/42"),
				createdAt: createdAt,
				updatedAt: createdAt.addingTimeInterval(60),
				estimatedComplexity: 5,
				blockedBy: []
			)
		])

		let updated = try await ProjectIssueImportService().importTickets(for: project, context: context, provider: updateProvider)
		let tickets = try context.fetch(FetchDescriptor<TicketRecord>())

		#expect(updated == 1)
		#expect(tickets.count == 1)
		#expect(tickets.first?.title == "Import issues from GitHub")
		#expect(tickets.first?.labels == ["agent", "github"])
		#expect(tickets.first?.priority == .high)
	}

	@Test func githubCredentialLifecycleStoresSecretAndClearsMetadata() throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let keychain = KeychainService(service: "co.charliewil.Auditorium.tests.\(UUID().uuidString)")
		let draft = ProjectDraft()
		draft.name = "Credential Test"
		draft.repositoryName = "charliewilco/Auditorium"
		draft.repositoryURL = "https://github.com/charliewilco/Auditorium"
		draft.defaultBranch = "main"
		draft.issueSourceName = "charliewilco/Auditorium"
		draft.issueSourceIdentifier = "charliewilco/Auditorium"
		draft.repositoryCredential = "test-token"
		draft.issueCredential = "test-token"
		draft.importDemoTickets = false

		_ = try ProjectCreationService().createProject(from: draft, context: context, workspaceService: ApplicationWorkspaceService(rootDirectory: root), keychainService: keychain)
		let accounts = try context.fetch(FetchDescriptor<ProviderAccountRecord>())
		let keychainAccount = try #require(accounts.first?.keychainAccount)

		#expect(accounts.count == 1)
		#expect(try keychain.readSecret(account: keychainAccount) == "test-token")

		try ProviderRegistry(keychainService: keychain).clearGitHubCredentials(context: context)

		#expect(try context.fetch(FetchDescriptor<ProviderAccountRecord>()).isEmpty)
		#expect(try keychain.readSecret(account: keychainAccount) == nil)
	}

	@Test func githubDeviceFlowRequestsUserCode() async throws {
		let payload = """
		{
			"device_code": "device-123",
			"user_code": "ABCD-EFGH",
			"verification_uri": "https://github.com/login/device",
			"verification_uri_complete": "https://github.com/login/device?user_code=ABCD-EFGH",
			"expires_in": 900,
			"interval": 5
		}
		"""
		let service = GitHubOAuthDeviceFlowService(transport: MockGitHubTransport(payload: payload))

		let code = try await service.requestDeviceCode(clientID: "client-123")

		#expect(code.deviceCode == "device-123")
		#expect(code.userCode == "ABCD-EFGH")
		#expect(code.verificationURI.absoluteString == "https://github.com/login/device")
		#expect(code.verificationURIComplete?.absoluteString == "https://github.com/login/device?user_code=ABCD-EFGH")
	}

	@Test func githubDeviceFlowExchangesDeviceCodeForToken() async throws {
		let payload = """
		{
			"access_token": "gho_test",
			"scope": "repo,read:user",
			"token_type": "bearer"
		}
		"""
		let service = GitHubOAuthDeviceFlowService(transport: MockGitHubTransport(payload: payload))

		let token = try await service.requestToken(clientID: "client-123", deviceCode: "device-123")

		#expect(token.accessToken == "gho_test")
		#expect(token.scope == "repo,read:user")
		#expect(token.tokenType == "bearer")
	}

	@Test func githubDeviceFlowReportsPendingAuthorization() async throws {
		let payload = """
		{
			"error": "authorization_pending",
			"error_description": "The authorization request is still pending."
		}
		"""
		let service = GitHubOAuthDeviceFlowService(transport: MockGitHubTransport(payload: payload))
		var isPending = false

		do {
			_ = try await service.requestToken(clientID: "client-123", deviceCode: "device-123")
		} catch GitHubOAuthDeviceFlowError.unsupportedResponse(let response) where response == "authorization_pending" {
			isPending = true
		}

		#expect(isPending)
	}

	@Test func projectDraftDefaultsToGitHubForSourceAndIssues() {
		let draft = ProjectDraft()

		#expect(draft.repositoryProviderKind == .github)
		#expect(draft.issueProviderKind == .githubIssues)
		#expect(draft.issueTrackerURL.contains("github.com"))
	}

	@Test func reportGenerationContainsCoreSections() throws {
		let project = Project(
			name: "Burton Demo",
			repositoryProviderKind: .github,
			repositoryName: "charlie/burton-ios",
			repositoryURL: "https://github.com/charlie/burton-ios",
			defaultBranch: "next",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
		let run = RunRecord(projectID: project.id, status: .completed, totalTickets: 1, completedTickets: 1, pullRequestsCreated: 1)
		run.endedAt = .now
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "BUR-101",
			title: "Fix OAuth refresh race condition",
			body: "Body",
			status: .needsReview,
			labels: ["auth"],
			assignee: "Charlie",
			priority: .urgent,
			webURL: "",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 8,
			sourceProjectID: project.id
		)
		let ticketRun = TicketRunRecord(runID: run.id, ticketID: ticket.id, branchName: "auditorium/bur-101", status: .needsReview, pullRequestURL: "https://example.com/pr/101", summary: "Done", confidence: 0.9)
		let markdown = ReportGenerator().generate(project: project, run: run, ticketRuns: [ticketRun], tickets: [ticket], pullRequests: [], events: [])

		#expect(markdown.contains("# Auditorium Run Report"))
		#expect(markdown.contains("## Pull Requests"))
		#expect(markdown.contains("BUR-101"))
		#expect(markdown.contains("https://example.com/pr/101"))
	}

	@Test func ticketInspectorStateReflectsCurrentRunState() {
		let projectID = UUID()
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "101",
			title: "Inspector state",
			body: "Body",
			status: .needsReview,
			labels: ["ui"],
			assignee: "Charlie",
			priority: .high,
			webURL: "https://github.com/charliewilco/Auditorium/issues/101",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 3,
			sourceProjectID: projectID
		)
		let queueItem = QueueItemRecord(ticketID: ticket.id, projectID: projectID, position: 2, priority: .high)
		let run = RunRecord(projectID: projectID, status: .completed, totalTickets: 1)
		let ticketRun = TicketRunRecord(
			runID: run.id,
			ticketID: ticket.id,
			workspacePath: "/tmp/auditorium/workspace",
			containerID: "local",
			branchName: "auditorium/issue-101",
			status: .needsReview,
			pullRequestURL: "https://github.com/charliewilco/Auditorium/pull/101",
			summary: "Ready for review.",
			confidence: 0.91
		)
		let events = [
			RuntimeEventRecord(runID: run.id, ticketRunID: ticketRun.id, timestamp: Date(timeIntervalSince1970: 2), level: .info, category: .agent, message: "Second"),
			RuntimeEventRecord(runID: run.id, ticketRunID: ticketRun.id, timestamp: Date(timeIntervalSince1970: 1), level: .info, category: .agent, message: "First")
		]

		let state = TicketInspectorState(ticket: ticket, queueItem: queueItem, latestRun: ticketRun, events: events)

		#expect(state.queueState == "Position 3")
		#expect(state.latestRunState == "Needs Review")
		#expect(state.workspace == "/tmp/auditorium/workspace")
		#expect(state.container == "local")
		#expect(state.branch == "auditorium/issue-101")
		#expect(state.pullRequest == "https://github.com/charliewilco/Auditorium/pull/101")
		#expect(state.confidence == "91%")
		#expect(state.nextAction == "Review the pull request and merge if acceptable.")
		#expect(state.timelineMessages == ["First", "Second"])
	}

	@Test func workflowPolicyParserReadsFrontMatter() throws {
		let policy = try WorkflowPolicyParser().parse(WorkflowPolicy.defaultMarkdown)

		#expect(policy.concurrency == 3)
		#expect(policy.maxRetries == 2)
		#expect(policy.maxRetryBackoffMilliseconds == 300_000)
		#expect(policy.branchPrefix == "auditorium")
		#expect(policy.runTests)
		#expect(policy.openPullRequest)
		#expect(policy.handoffStatus == "Needs Review")
		#expect(policy.updateIssueLabels == false)
		#expect(policy.prompt.contains("autonomous coding agent"))
	}

	@Test func workflowPolicyParserReadsRetryBackoff() throws {
		let policy = try WorkflowPolicyParser().parse("""
		---
		concurrency: 4
		max_retries: 3
		max_retry_backoff_ms: 8000
		---
		Prompt
		""")

		#expect(policy.concurrency == 4)
		#expect(policy.maxRetries == 3)
		#expect(policy.maxRetryBackoffMilliseconds == 8_000)
	}

	@Test func orchestrationPlanSnapshotsEnabledQueueIntoBoundedBatches() {
		let projectID = UUID()
		let firstTicketID = UUID()
		let secondTicketID = UUID()
		let thirdTicketID = UUID()
		let disabledTicketID = UUID()
		let queueItems = [
			QueueItemRecord(ticketID: thirdTicketID, projectID: projectID, position: 30, priority: .low),
			QueueItemRecord(ticketID: disabledTicketID, projectID: projectID, position: 5, priority: .high, isEnabled: false),
			QueueItemRecord(ticketID: firstTicketID, projectID: projectID, position: 10, priority: .high, concurrencyGroup: "ui"),
			QueueItemRecord(ticketID: secondTicketID, projectID: projectID, position: 20, priority: .medium, concurrencyGroup: "backend")
		]

		let plan = OrchestrationRunPlan.make(
			queueItems: queueItems,
			requestedConcurrency: 2,
			workflowPolicyMarkdown: WorkflowPolicy.defaultMarkdown
		)

		#expect(plan.concurrency == 2)
		#expect(plan.workflowPolicyMarkdown == WorkflowPolicy.defaultMarkdown)
		#expect(plan.queueSnapshot.map(\.ticketID) == [firstTicketID, secondTicketID, thirdTicketID])
		#expect(plan.queueSnapshot.map(\.concurrencyGroup) == ["ui", "backend", "default"])
		#expect(plan.batches.map { $0.map(\.ticketID) } == [[firstTicketID, secondTicketID], [thirdTicketID]])
	}

	@Test func orchestrationPlanUsesWorkflowConcurrencyWhenRunOverrideIsInvalid() {
		let projectID = UUID()
		let queueItems = [
			QueueItemRecord(ticketID: UUID(), projectID: projectID, position: 0, priority: .medium),
			QueueItemRecord(ticketID: UUID(), projectID: projectID, position: 1, priority: .medium),
			QueueItemRecord(ticketID: UUID(), projectID: projectID, position: 2, priority: .medium)
		]
		let policy = """
		---
		concurrency: 3
		max_retries: 1
		max_retry_backoff_ms: 16000
		---
		Prompt
		"""

		let plan = OrchestrationRunPlan.make(queueItems: queueItems, requestedConcurrency: 0, workflowPolicyMarkdown: policy)

		#expect(plan.concurrency == 3)
		#expect(plan.batches.count == 1)
		#expect(plan.retryPolicy == RetryPolicy(maxRetries: 1, maxRetryBackoffMilliseconds: 16_000))
	}

	@Test func retryPolicyRetriesOnlyFailedRunsWithinLimit() {
		let policy = RetryPolicy(maxRetries: 2, maxRetryBackoffMilliseconds: 8_000)

		#expect(policy.shouldRetry(status: .failed, retryCount: 0))
		#expect(policy.shouldRetry(status: .failed, retryCount: 1))
		#expect(policy.shouldRetry(status: .failed, retryCount: 2) == false)
		#expect(policy.shouldRetry(status: .blocked, retryCount: 0) == false)
		#expect(policy.shouldRetry(status: .canceled, retryCount: 0) == false)
		#expect(policy.shouldRetry(status: .completed, retryCount: 0) == false)
		#expect(policy.backoffMilliseconds(for: 0) == 1_000)
		#expect(policy.backoffMilliseconds(for: 1) == 2_000)
		#expect(policy.backoffMilliseconds(for: 10) == 8_000)
	}

	@Test func symphonyRunnerDecodesEventsAndSummary() throws {
		let output = """
		{"level":"info","category":"orchestration","message":"run_started","timestamp":"2026-06-06T12:00:00Z","metadata":{"issue":"#42"}}
		{"run_id":"run-1","repo":"charliewilco/Auditorium","workspace_path":"/tmp/work","branch_name":"auditorium/issue-42","status":"completed","pull_request_url":"https://github.com/charliewilco/Auditorium/pull/1","report_path":"/tmp/report.md"}
		"""

		let result = try SymphonyCLIProcessRunner().decode(output: output)

		#expect(result.events.count == 1)
		#expect(result.events.first?.message == "run_started")
		#expect(result.summary?.branchName == "auditorium/issue-42")
		#expect(result.summary?.pullRequestURL == "https://github.com/charliewilco/Auditorium/pull/1")
	}

	@Test func symphonyRunnerDecodesStreamingEventLine() throws {
		let line = """
		{"level":"success","category":"agent","message":"agent_finished","timestamp":"2026-06-06T12:00:01Z","metadata":{"ticket":"42"}}
		"""

		let event = try SymphonyCLIProcessRunner().decodeEvent(line: line)

		#expect(event.level == "success")
		#expect(event.category == "agent")
		#expect(event.message == "agent_finished")
		#expect(event.metadataJSON.contains("ticket"))
	}

	@Test func symphonyRunnerDecodesDoctorStatus() {
		let output = """
		{
		  "ok": true,
		  "workflow": {
		    "ok": true,
		    "workspaceRoot": "/tmp/auditorium",
		    "trackerKind": "github",
		    "maxConcurrentAgents": 3
		  },
		  "checks": [
		    { "name": "git --version", "ok": true, "detail": "git version 2.50.0" },
		    { "name": "codex --version", "ok": true, "detail": "codex 0.1.0" }
		  ]
		}
		"""

		let status = SymphonyCLIProcessRunner().decodeDoctor(output: output, exitCode: 0, stderr: "")

		#expect(status.state == .available)
		#expect(status.detail == "symphony doctor passed 2 checks.")
		#expect(status.workflowDetail.contains("github"))
		#expect(status.workflowDetail.contains("max agents 3"))
		#expect(status.checks.map(\.name) == ["git --version", "codex --version"])
		#expect(status.checks.allSatisfy { $0.isOK })
	}

	@Test func symphonyRunnerDecodesFailingDoctorStatus() {
		let output = """
		{
		  "ok": false,
		  "workflow": {
		    "ok": false,
		    "code": "missing_workflow_file",
		    "message": "workflow file was not found"
		  },
		  "checks": [
		    { "name": "git --version", "ok": true, "detail": "git version 2.50.0" },
		    { "name": "codex --version", "ok": false, "code": "command_failed", "detail": "codex was not found" }
		  ]
		}
		"""

		let status = SymphonyCLIProcessRunner().decodeDoctor(output: output, exitCode: 22, stderr: "invalid_config")

		#expect(status.state == .unavailable)
		#expect(status.detail == "symphony doctor found 1 failing checks.")
		#expect(status.workflowDetail.contains("missing_workflow_file"))
		#expect(status.checks.last?.code == "command_failed")
	}

	@Test func processCommandCanReturnNonZeroResultForStructuredOutput() async throws {
		let result = try await ProcessCommand.runStreaming(
			executable: "/bin/sh",
			arguments: ["-lc", "printf '{\"ok\":false}\\n'; printf 'failed' >&2; exit 22"],
			allowsNonZeroExit: true
		)

		#expect(result.exitCode == 22)
		#expect(result.standardOutput == "{\"ok\":false}\n")
		#expect(result.standardError == "failed")
	}

	@Test func processCommandStreamsStandardOutputLines() async throws {
		var lines: [String] = []

		let result = try await ProcessCommand.runStreaming(
			executable: "/bin/sh",
			arguments: ["-lc", "printf 'one\\n'; sleep 0.1; printf 'two\\n'"],
			onStandardOutputLine: { line in
				lines.append(line)
			}
		)

		#expect(result.standardOutput == "one\ntwo\n")
		#expect(lines == ["one", "two"])
	}

	@Test func codexAgentProviderStreamsOutputAndWritesLog() async throws {
		let root = try makeAgentWorkspace()
		defer { try? FileManager.default.removeItem(at: root) }
		let provider = CodexCLIProcessAgentProvider(
			executablePath: "/bin/sh",
			arguments: ["-lc", "case \"$0\" in *\"Stream Codex output\"*) printf 'prompt-ok\\n' ;; *) printf 'missing prompt\\n' >&2; exit 9 ;; esac; printf 'stderr-line\\n' >&2"]
		)
		let stream = try await provider.runAgent(makeAgentRunRequest(workspace: root, title: "Stream Codex output"))
		var events: [AgentEvent] = []

		for try await event in stream {
			events.append(event)
		}

		let messages = events.map(\.message)
		let log = try String(contentsOf: root.appending(path: ".auditorium/codex.log"), encoding: .utf8)
		#expect(messages.contains("codex_started"))
		#expect(messages.contains("codex_stdout: prompt-ok"))
		#expect(messages.contains("codex_stderr: stderr-line"))
		#expect(events.last?.outcome == .completed)
		#expect(events.last?.logPath == root.appending(path: ".auditorium/codex.log").path())
		#expect(log.contains("Exit code: 0"))
		#expect(log.contains("prompt-ok"))
		#expect(log.contains("stderr-line"))
	}

	@Test func codexAgentProviderMapsNonZeroExitToFailedOutcome() async throws {
		let root = try makeAgentWorkspace()
		defer { try? FileManager.default.removeItem(at: root) }
		let provider = CodexCLIProcessAgentProvider(
			executablePath: "/bin/sh",
			arguments: ["-lc", "printf 'partial-output\\n'; printf 'failure-detail\\n' >&2; exit 7"]
		)
		let stream = try await provider.runAgent(makeAgentRunRequest(workspace: root, title: "Fail Codex output"))
		var events: [AgentEvent] = []

		for try await event in stream {
			events.append(event)
		}

		#expect(events.contains { $0.message == "codex_stdout: partial-output" })
		#expect(events.contains { $0.message == "codex_stderr: failure-detail" })
		#expect(events.last?.message == "codex_failed")
		#expect(events.last?.summary == "Codex CLI exited with status 7.")
		#expect(events.last?.outcome == .failed)
		#expect(events.last?.logPath == root.appending(path: ".auditorium/codex.log").path())
	}

	@Test func codexAgentProviderCancelsRunningProcessWhenStreamConsumerCancels() async throws {
		let root = try makeAgentWorkspace()
		defer { try? FileManager.default.removeItem(at: root) }
		let donePath = root.appending(path: "finished")
		let provider = CodexCLIProcessAgentProvider(
			executablePath: "/bin/sh",
			arguments: ["-lc", "printf 'started\\n'; sleep 5; touch '\(donePath.path())'"]
		)
		let stream = try await provider.runAgent(makeAgentRunRequest(workspace: root, title: "Cancel Codex output"))
		let task = Task {
			for try await _ in stream {}
		}

		try await Task.sleep(nanoseconds: 200_000_000)
		task.cancel()
		_ = try? await task.value
		try await Task.sleep(nanoseconds: 300_000_000)

		#expect(FileManager.default.fileExists(atPath: donePath.path()) == false)
	}

	@Test func genericCLIConfigurationParsesQuotedCommand() throws {
		let configuration = try GenericCLIAgentConfiguration(commandLine: #"agent --name "two words" 'single quoted' escaped\ value"#)

		#expect(configuration.executablePath == "/usr/bin/env")
		#expect(configuration.arguments == ["agent", "--name", "two words", "single quoted", "escaped value"])
	}

	@Test func genericCLIConfigurationRejectsInvalidCommands() {
		#expect(throws: GenericCLIAgentConfigurationError.emptyCommand) {
			try GenericCLIAgentConfiguration(commandLine: "   ")
		}
		#expect(throws: GenericCLIAgentConfigurationError.unterminatedQuote) {
			try GenericCLIAgentConfiguration(commandLine: #"agent "unterminated"#)
		}
	}

	@Test func genericShellAgentProviderStreamsOutputAndWritesLog() async throws {
		let root = try makeAgentWorkspace()
		defer { try? FileManager.default.removeItem(at: root) }
		let script = root.appending(path: "generic-agent")
		try """
		#!/bin/sh
		case "$1" in
		  *"Generic CLI output"*) printf 'generic-ok\\n' ;;
		  *) printf 'missing prompt\\n' >&2; exit 9 ;;
		esac
		printf 'generic-err\\n' >&2
		""".write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path())
		let provider = try GenericShellAgentProvider(commandLine: script.path())
		let stream = try await provider.runAgent(makeAgentRunRequest(workspace: root, title: "Generic CLI output"))
		var events: [AgentEvent] = []

		for try await event in stream {
			events.append(event)
		}

		let messages = events.map(\.message)
		let logPath = root.appending(path: ".auditorium/generic-cli.log").path()
		let log = try String(contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8)
		#expect(messages.contains("generic_cli_started"))
		#expect(messages.contains("generic_cli_stdout: generic-ok"))
		#expect(messages.contains("generic_cli_stderr: generic-err"))
		#expect(events.last?.outcome == .completed)
		#expect(events.last?.logPath == logPath)
		#expect(log.contains("Command: \(script.path())"))
		#expect(log.contains("generic-ok"))
		#expect(log.contains("generic-err"))
	}

	@Test func localProcessRuntimeClonesRepositoryCreatesBranchAndWritesHandle() async throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspaceService = ApplicationWorkspaceService(rootDirectory: root)
		let projectID = UUID()
		let sourceProvider = StaticSourceCodeProvider(kind: .github)
		let runtime = LocalProcessRuntimeProvider(
			workspaceService: workspaceService,
			projectID: projectID,
			sourceProvider: sourceProvider,
			branchPrefix: "auditorium"
		)
		let ticket = TicketDescriptor(
			provider: .githubIssues,
			externalID: "ISSUE-42",
			title: "Fix Local Runtime",
			body: "Create a real local workspace.",
			status: .ready,
			labels: ["runtime"],
			assignee: nil,
			priority: .medium,
			webURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/42"),
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 2,
			blockedBy: []
		)
		let repository = RepositoryDescriptor(
			provider: .github,
			owner: "charliewilco",
			name: "Auditorium",
			fullName: "charliewilco/Auditorium",
			cloneURL: URL(string: "https://github.com/charliewilco/Auditorium.git")!,
			webURL: URL(string: "https://github.com/charliewilco/Auditorium")!,
			defaultBranch: "main"
		)

		let workspace = try await runtime.prepareWorkspace(for: ticket, repository: repository)
		let handle = try await runtime.startExecution(RuntimeExecutionRequest(ticket: ticket, workspace: workspace, policyMarkdown: WorkflowPolicy.defaultMarkdown))
		try await runtime.stopExecution(handle: handle)
		let handleData = try Data(contentsOf: runtime.runtimeHandlePath(for: workspace.path))
		let handleJSON = try #require(String(data: handleData, encoding: .utf8))

		#expect(workspace.path == workspaceService.workspacePath(projectID: projectID, ticketExternalID: "ISSUE-42"))
		#expect(workspace.containerID == "local-issue-42")
		#expect(workspace.branchName == "auditorium/issue-42-fix-local-runtime")
		#expect(sourceProvider.clonePaths == [workspace.path])
		#expect(sourceProvider.createdBranches.map { $0.name } == ["auditorium/issue-42-fix-local-runtime"])
		#expect(sourceProvider.createdBranches.map { $0.repositoryPath } == [workspace.path])
		#expect(handle.id == "local-issue-42")
		#expect(handle.workspacePath == workspace.path)
		#expect(handleJSON.contains(#""ticketExternalID" : "ISSUE-42""#))
		#expect(FileManager.default.fileExists(atPath: workspace.path.appending(path: ".auditorium/runtime-stopped").path()))
	}

	@Test func orchestratorPersistsSymphonyEventsWhileProcessRuns() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let fakeSymphony = root.appending(path: "fake-symphony")
		let reportPath = root.appending(path: "report.md").path()
		let workspacePath = root.appending(path: "workspace").path()
		let releasePath = root.appending(path: "release-symphony").path()
		let script = """
		#!/bin/sh
		printf '%s\\n' '{"level":"info","category":"agent","message":"streamed_before_exit","timestamp":"2026-06-06T12:00:00Z","metadata":{"ticket":"7"}}'
		while [ ! -f '\(releasePath)' ]; do
			sleep 0.05
		done
		mkdir -p '\(workspacePath)'
		printf '# Fake Report\\n' > '\(reportPath)'
		printf '%s\\n' '{"run_id":"run-1","repo":"charliewilco/Auditorium","workspace_path":"\(workspacePath)","branch_name":"auditorium/issue-7","status":"completed","pull_request_url":"https://github.com/charliewilco/Auditorium/pull/7","report_path":"\(reportPath)"}'
		"""
		try script.write(to: fakeSymphony, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSymphony.path())
		let project = Project(
			name: "Streaming",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "7",
			title: "Stream events",
			body: "Verify live event persistence.",
			status: .ready,
			labels: ["test"],
			assignee: nil,
			priority: .medium,
			webURL: "https://github.com/charliewilco/Auditorium/issues/7",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 2,
			sourceProjectID: project.id
		)
		context.insert(project)
		context.insert(ticket)
		context.insert(QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .medium))
		try context.save()
		let detection = RuntimeDetectionService(staticChecks: [
			RuntimeHealthCheck(id: "git", name: "Git", state: .available, detail: "/usr/bin/git", version: nil),
			RuntimeHealthCheck(id: "codex", name: "Codex CLI", state: .available, detail: "/usr/local/bin/codex", version: nil)
		])
		let orchestrator = Orchestrator(
			workspaceService: ApplicationWorkspaceService(rootDirectory: root.appending(path: "app")),
			runtimeDetection: detection,
			reportGenerator: ReportGenerator(),
			symphonyRunner: SymphonyCLIProcessRunner(executablePath: fakeSymphony.path())
		)

		var taskCompleted = false
		let task = Task { @MainActor in
			defer { taskCompleted = true }
			try await orchestrator.execute(projectID: project.id, concurrency: 1, context: context)
		}
		var earlyEvents: [RuntimeEventRecord] = []
		for _ in 0..<100 {
			earlyEvents = try context.fetch(FetchDescriptor<RuntimeEventRecord>())
			if earlyEvents.contains(where: { $0.message == "streamed_before_exit" }) {
				break
			}
			try await Task.sleep(nanoseconds: 50_000_000)
		}
		_ = FileManager.default.createFile(atPath: releasePath, contents: Data())

		#expect(earlyEvents.contains { $0.message == "streamed_before_exit" })
		#expect(taskCompleted == false)

		try await task.value
		let runs = try context.fetch(FetchDescriptor<RunRecord>())
		let ticketRun = try #require(context.fetch(FetchDescriptor<TicketRunRecord>()).first)
		let reports = try context.fetch(FetchDescriptor<ReportRecord>())

		#expect(runs.count == 1)
		#expect(runs.first?.totalTickets == 1)
		#expect(runs.first?.status == .completed)
		#expect(ticket.status == .needsReview)
		#expect(ticketRun.status == .needsReview)
		#expect(ticketRun.pullRequestURL == "https://github.com/charliewilco/Auditorium/pull/7")
		#expect(reports.contains { $0.filePath == reportPath })
	}

	@Test func mockOrchestratorWritesWorkspaceManifestPerTicketRun() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = ApplicationWorkspaceService(rootDirectory: root)
		let project = Project(
			name: "Manifest",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "MAN-101",
			title: "Write manifest",
			body: "Persist a workspace manifest.",
			status: .ready,
			labels: ["workspace"],
			assignee: nil,
			priority: .medium,
			webURL: "https://github.com/charliewilco/Auditorium/issues/101",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			sourceProjectID: project.id
		)
		context.insert(project)
		context.insert(ticket)
		context.insert(QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .medium))
		try context.save()
		let orchestrator = Orchestrator(workspaceService: workspace, runtimeDetection: RuntimeDetectionService(staticChecks: []), reportGenerator: ReportGenerator())

		try await orchestrator.execute(projectID: project.id, concurrency: 1, context: context)
		let run = try #require(context.fetch(FetchDescriptor<RunRecord>()).first)
		let ticketRun = try #require(context.fetch(FetchDescriptor<TicketRunRecord>()).first)
		let manifestURL = workspace.workspaceManifestPath(workspace: URL(fileURLWithPath: ticketRun.workspacePath))
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let manifest = try decoder.decode(WorkspaceManifest.self, from: Data(contentsOf: manifestURL))

		#expect(FileManager.default.fileExists(atPath: manifestURL.path()))
		#expect(manifest.projectID == project.id)
		#expect(manifest.runID == run.id)
		#expect(manifest.ticketRunID == ticketRun.id)
		#expect(manifest.ticketID == ticket.id)
		#expect(manifest.ticketExternalID == "MAN-101")
		#expect(manifest.repository == "charliewilco/Auditorium")
		#expect(manifest.branchName == ticketRun.branchName)
	}

	@Test func mockOrchestratorUsesInjectedSourceProviderForPullRequests() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = ApplicationWorkspaceService(rootDirectory: root)
		let sourceProvider = StaticSourceCodeProvider(kind: .genericGit)
		let project = Project(
			name: "Protocol Source",
			repositoryProviderKind: .genericGit,
			repositoryName: "local/protocol-source",
			repositoryURL: "file:///tmp/protocol-source",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "SRC-101",
			title: "Use injected source provider",
			body: "The orchestrator should create PRs through the source provider protocol.",
			status: .ready,
			labels: ["providers"],
			assignee: nil,
			priority: .medium,
			webURL: "https://github.com/charliewilco/Auditorium/issues/101",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			sourceProjectID: project.id
		)
		context.insert(project)
		context.insert(ticket)
		context.insert(QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .medium))
		try context.save()
		let orchestrator = Orchestrator(
			workspaceService: workspace,
			runtimeDetection: RuntimeDetectionService(staticChecks: []),
			reportGenerator: ReportGenerator(),
			mockSourceProvider: sourceProvider
		)

		try await orchestrator.execute(projectID: project.id, concurrency: 1, context: context)
		let pullRequest = try #require(context.fetch(FetchDescriptor<PullRequestRecord>()).first)

		#expect(pullRequest.provider == .genericGit)
		#expect(pullRequest.url == "https://example.com/local/protocol-source/pull/source-provider")
		#expect(sourceProvider.createdPullRequestTitles == ["SRC-101: Use injected source provider"])
	}

	@Test func mockOrchestratorPersistsInjectedAgentMetadataAndLogPath() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = ApplicationWorkspaceService(rootDirectory: root)
		let sourceProvider = StaticSourceCodeProvider(kind: .github)
		let logPath = root.appending(path: "codex.log").path()
		let agentProvider = StaticAgentProvider(events: [
			AgentEvent(level: .info, category: .agent, message: "agent streamed output", metadataJSON: #"{"stream":"stdout"}"#),
			AgentEvent(level: .success, category: .agent, message: "agent completed", summary: "Agent finished through injected provider.", outcome: .completed, logPath: logPath)
		])
		let project = Project(
			name: "Injected Agent",
			repositoryProviderKind: .github,
			repositoryName: "local/injected-agent",
			repositoryURL: "file:///tmp/injected-agent",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "AGT-101",
			title: "Persist injected agent events",
			body: "The orchestrator should persist agent metadata and log paths.",
			status: .ready,
			labels: ["agent"],
			assignee: nil,
			priority: .medium,
			webURL: "https://github.com/charliewilco/Auditorium/issues/102",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 1,
			sourceProjectID: project.id
		)
		context.insert(project)
		context.insert(ticket)
		context.insert(QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .medium))
		try context.save()
		let orchestrator = Orchestrator(
			workspaceService: workspace,
			runtimeDetection: RuntimeDetectionService(staticChecks: []),
			reportGenerator: ReportGenerator(),
			mockSourceProvider: sourceProvider,
			mockAgentProvider: agentProvider
		)

		try await orchestrator.execute(projectID: project.id, concurrency: 1, context: context)
		let ticketRun = try #require(context.fetch(FetchDescriptor<TicketRunRecord>()).first)
		let agentEvent = try #require(context.fetch(FetchDescriptor<RuntimeEventRecord>()).first { $0.message == "agent streamed output" })

		#expect(ticketRun.status == .needsReview)
		#expect(ticketRun.logPath == logPath)
		#expect(agentEvent.metadataJSON == #"{"stream":"stdout"}"#)
	}

	@Test func processCommandCancelsRunningProcess() async {
		let task = Task {
			try await ProcessCommand.run(executable: "/bin/sh", arguments: ["-lc", "sleep 5"])
		}
		try? await Task.sleep(nanoseconds: 200_000_000)
		task.cancel()
		var didCancel = false

		do {
			_ = try await task.value
		} catch ProcessCommandError.canceled {
			didCancel = true
		} catch {}

		#expect(didCancel)
	}

	@Test func runSecurityPolicyBlocksRealRunsWhenNetworkIsDisabled() throws {
		let project = Project(
			name: "Real Run",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .localWorkspace,
			agentProviderKind: .codex
		)
		let preferences = RunSecurityPreferences(
			allowNetworkAccess: false,
			allowFilesystemWrite: true,
			requireRunConfirmation: true,
			requirePullRequestConfirmation: true
		)

		#expect(throws: RunSecurityPolicyError.networkAccessDisabled) {
			try RunSecurityPolicy().validate(project: project, preferences: preferences)
		}
	}

	@Test func runSecurityPolicyAllowsOfflineMockRunWithoutNetwork() throws {
		let project = Project(
			name: "Mock Run",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
		let preferences = RunSecurityPreferences(
			allowNetworkAccess: false,
			allowFilesystemWrite: true,
			requireRunConfirmation: true,
			requirePullRequestConfirmation: true
		)

		try RunSecurityPolicy().validate(project: project, preferences: preferences)
	}

	@Test func runSecurityPolicyBlocksRunsWhenFilesystemWritesAreDisabled() throws {
		let project = Project(
			name: "No Writes",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
		let preferences = RunSecurityPreferences(
			allowNetworkAccess: true,
			allowFilesystemWrite: false,
			requireRunConfirmation: true,
			requirePullRequestConfirmation: true
		)

		#expect(throws: RunSecurityPolicyError.filesystemWriteDisabled) {
			try RunSecurityPolicy().validate(project: project, preferences: preferences)
		}
	}

	@Test func runtimeDetectionReturnsExpectedChecks() async {
		let checks = await RuntimeDetectionService().detect()
		let ids = Set(checks.map(\.id))

		#expect(ids.contains("apple-container"))
		#expect(ids.contains("docker"))
		#expect(ids.contains("git"))
		#expect(ids.contains("codex"))
		#expect(ids.contains("gh"))
	}

	@Test func appleContainerVersionParsingUsesCLIComponent() {
		let json = """
		[
			{
				"appName": "container",
				"buildType": "release",
				"commit": "abcdef1",
				"version": "0.12.3"
			},
			{
				"appName": "container-apiserver",
				"buildType": "release",
				"commit": "1234abc",
				"version": "container-apiserver version 0.12.3"
			}
		]
		"""

		#expect(RuntimeDetectionService.containerCLIVersion(from: json) == "0.12.3")
	}

	@Test func mockAgentHealthIsAvailableOffline() async {
		let health = await RuntimeDetectionService(staticChecks: []).health(for: .mockAgent)

		#expect(health.state == .available)
	}

	@Test func unavailableAppleContainerBlocksWorkspaceCreation() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = ApplicationWorkspaceService(rootDirectory: root)
		let project = Project(
			name: "Container Preflight",
			repositoryProviderKind: .github,
			repositoryName: "charlie/container-preflight",
			repositoryURL: "https://github.com/charlie/container-preflight",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .appleContainer,
			agentProviderKind: .mockAgent
		)
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "CON-101",
			title: "Run in Apple Container",
			body: "Validate runtime preflight.",
			status: .ready,
			labels: ["runtime"],
			assignee: nil,
			priority: .high,
			webURL: "",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 3,
			sourceProjectID: project.id
		)
		let queueItem = QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .high)
		context.insert(project)
		context.insert(ticket)
		context.insert(queueItem)
		try context.save()

		let detection = RuntimeDetectionService(staticChecks: [
			RuntimeHealthCheck(id: "apple-container", name: "Apple Container", state: .needsSetup, detail: "container CLI was not found.", version: nil)
		])
		let orchestrator = Orchestrator(workspaceService: workspace, runtimeDetection: detection, reportGenerator: ReportGenerator())
		var didThrow = false

		do {
			try await orchestrator.execute(projectID: project.id, concurrency: 1, context: context)
		} catch {
			didThrow = true
		}

		#expect(didThrow)
		#expect(try context.fetch(FetchDescriptor<TicketRunRecord>()).isEmpty)
		#expect(try context.fetch(FetchDescriptor<RunRecord>()).isEmpty)
		#expect(!FileManager.default.fileExists(atPath: workspace.workspacesDirectory(projectID: project.id).path()))
	}

	@Test func unavailableCodexCLIBlocksWorkspaceCreation() async throws {
		let container = try AppSchema.makeModelContainer(inMemory: true)
		let context = container.mainContext
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = ApplicationWorkspaceService(rootDirectory: root)
		let project = Project(
			name: "Codex Preflight",
			repositoryProviderKind: .github,
			repositoryName: "charlie/codex-preflight",
			repositoryURL: "https://github.com/charlie/codex-preflight",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .codex
		)
		let ticket = TicketRecord(
			provider: .githubIssues,
			externalID: "COD-101",
			title: "Run with Codex CLI",
			body: "Validate agent preflight.",
			status: .ready,
			labels: ["agent"],
			assignee: nil,
			priority: .high,
			webURL: "",
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 3,
			sourceProjectID: project.id
		)
		let queueItem = QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: 0, priority: .high)
		context.insert(project)
		context.insert(ticket)
		context.insert(queueItem)
		try context.save()

		let detection = RuntimeDetectionService(staticChecks: [
			RuntimeHealthCheck(id: "codex", name: "Codex CLI", state: .needsSetup, detail: "Codex CLI was not found.", version: nil)
		])
		let orchestrator = Orchestrator(workspaceService: workspace, runtimeDetection: detection, reportGenerator: ReportGenerator())
		var didThrow = false

		do {
			try await orchestrator.execute(projectID: project.id, concurrency: 1, context: context)
		} catch {
			didThrow = true
		}

		#expect(didThrow)
		#expect(try context.fetch(FetchDescriptor<TicketRunRecord>()).isEmpty)
		#expect(try context.fetch(FetchDescriptor<RunRecord>()).isEmpty)
		#expect(!FileManager.default.fileExists(atPath: workspace.workspacesDirectory(projectID: project.id).path()))
	}
}

private struct MigrationFixtureIDs {
	let projectID: UUID
	let ticketID: UUID
	let runID: UUID
	let ticketRunID: UUID
}

@MainActor
private extension AuditoriumTests {
	func makeAgentWorkspace() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appending(path: "AuditoriumTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	func makeAgentRunRequest(workspace: URL, title: String) -> AgentRunRequest {
		let ticket = TicketDescriptor(
			provider: .githubIssues,
			externalID: "COD-101",
			title: title,
			body: "Verify Codex CLI process provider behavior.",
			status: .ready,
			labels: ["agent"],
			assignee: nil,
			priority: .medium,
			webURL: URL(string: "https://github.com/charliewilco/Auditorium/issues/101"),
			createdAt: .now,
			updatedAt: .now,
			estimatedComplexity: 2,
			blockedBy: []
		)
		let repository = RepositoryDescriptor(
			provider: .github,
			owner: "charliewilco",
			name: "Auditorium",
			fullName: "charliewilco/Auditorium",
			cloneURL: URL(string: "https://github.com/charliewilco/Auditorium.git")!,
			webURL: URL(string: "https://github.com/charliewilco/Auditorium")!,
			defaultBranch: "main"
		)
		let workspace = WorkspaceDescriptor(path: workspace, containerID: "local-test", branchName: "auditorium/cod-101")
		return AgentRunRequest(ticket: ticket, repository: repository, workspace: workspace, policyMarkdown: WorkflowPolicy.defaultMarkdown)
	}

	func writeLegacyV1Store(at storeURL: URL) throws -> MigrationFixtureIDs {
		let schema = Schema(AppSchema.modelTypes, version: AppSchema.V1.versionIdentifier)
		let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
		let container = try ModelContainer(for: schema, configurations: [configuration])
		let context = container.mainContext
		let projectID = UUID()
		let ticketID = UUID()
		let runID = UUID()
		let ticketRunID = UUID()
		let project = Project(
			id: projectID,
			name: "Migrated Project",
			repositoryProviderKind: .github,
			repositoryName: "charliewilco/Auditorium",
			repositoryURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent,
			createdAt: Date(timeIntervalSince1970: 1_780_000_000),
			updatedAt: Date(timeIntervalSince1970: 1_780_000_001)
		)
		let repository = RepositoryRecord(
			provider: .github,
			owner: "charliewilco",
			name: "Auditorium",
			fullName: "charliewilco/Auditorium",
			cloneURL: "https://github.com/charliewilco/Auditorium.git",
			webURL: "https://github.com/charliewilco/Auditorium",
			defaultBranch: "main",
			localPath: "/tmp/auditorium",
			projectID: projectID
		)
		let issueTracker = IssueTrackerRecord(
			provider: .githubIssues,
			displayName: "charliewilco/Auditorium",
			sourceIdentifier: "charliewilco/Auditorium",
			filterName: "Ready",
			webURL: "https://github.com/charliewilco/Auditorium/issues",
			projectID: projectID
		)
		let ticket = TicketRecord(
			id: ticketID,
			provider: .githubIssues,
			externalID: "101",
			title: "Migrate persisted ticket",
			body: "Verify existing issue data survives migration.",
			status: .queued,
			labels: ["migration"],
			assignee: "charlie",
			priority: .high,
			webURL: "https://github.com/charliewilco/Auditorium/issues/101",
			createdAt: Date(timeIntervalSince1970: 1_780_000_002),
			updatedAt: Date(timeIntervalSince1970: 1_780_000_003),
			estimatedComplexity: 3,
			sourceProjectID: projectID
		)
		let queueItem = QueueItemRecord(ticketID: ticketID, projectID: projectID, position: 0, priority: .high)
		let run = RunRecord(id: runID, projectID: projectID, status: .completed, totalTickets: 1, completedTickets: 1, summary: "Migrated run")
		let ticketRun = TicketRunRecord(
			id: ticketRunID,
			runID: runID,
			ticketID: ticketID,
			workspacePath: "/tmp/auditorium/workspaces/101",
			containerID: "mock-runtime",
			branchName: "auditorium/101-migrate-persisted-ticket",
			status: .completed,
			retryCount: 0,
			logPath: "/tmp/auditorium/logs/101.log",
			pullRequestURL: "https://github.com/charliewilco/Auditorium/pull/101",
			summary: "Completed",
			confidence: 0.9
		)
		let pullRequest = PullRequestRecord(
			provider: .github,
			ticketRunID: ticketRunID,
			title: "Migrate persisted ticket",
			url: "https://github.com/charliewilco/Auditorium/pull/101",
			branchName: "auditorium/101-migrate-persisted-ticket",
			targetBranch: "main",
			status: .open,
			checksStatus: .passed
		)
		let event = RuntimeEventRecord(runID: runID, ticketRunID: ticketRunID, level: .info, category: .orchestration, message: "Migration fixture created")
		let report = ReportRecord(
			projectID: projectID,
			runID: runID,
			title: "Migration Fixture Report",
			markdown: "# Migration Fixture Report\n\nPersisted data survived migration.",
			filePath: "/tmp/auditorium/reports/run.md"
		)
		let account = ProviderAccountRecord(
			providerKindRaw: RepositoryProviderKind.github.rawValue,
			displayName: "GitHub",
			keychainAccount: "auditorium-github-account"
		)
		context.insert(project)
		context.insert(repository)
		context.insert(issueTracker)
		context.insert(ticket)
		context.insert(queueItem)
		context.insert(run)
		context.insert(ticketRun)
		context.insert(pullRequest)
		context.insert(event)
		context.insert(report)
		context.insert(account)
		try context.save()
		return MigrationFixtureIDs(projectID: projectID, ticketID: ticketID, runID: runID, ticketRunID: ticketRunID)
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
		let response = HTTPURLResponse(
			url: request.url ?? URL(string: "https://api.github.com")!,
			statusCode: statusCode,
			httpVersion: nil,
			headerFields: headers
		)!
		return (Data(payload.utf8), response)
	}
}

private struct MockGitHubResponse: Sendable {
	let payload: String
	let statusCode: Int
	let headers: [String: String]

	init(payload: String, statusCode: Int = 200, headers: [String: String] = [:]) {
		self.payload = payload
		self.statusCode = statusCode
		self.headers = headers
	}
}

private final class StaticSourceCodeProvider: SourceCodeProvider {
	let kind: RepositoryProviderKind
	let authentication = ProviderAuthenticationDescriptor(method: .none, displayName: "Static Source", oauth: nil)
	private(set) var createdPullRequestTitles: [String] = []
	private(set) var clonePaths: [URL] = []
	private(set) var createdBranches: [(name: String, repositoryPath: URL)] = []

	init(kind: RepositoryProviderKind) {
		self.kind = kind
	}

	func listRepositories() async throws -> [RepositoryDescriptor] {
		[]
	}

	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws {
		clonePaths.append(path)
		try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
	}

	func createBranch(named branchName: String, in repositoryPath: URL) async throws {
		createdBranches.append((branchName, repositoryPath))
	}

	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor {
		createdPullRequestTitles.append(request.title)
		return PullRequestDescriptor(
			title: request.title,
			url: URL(string: "https://example.com/\(request.repository.fullName)/pull/source-provider")!,
			branchName: request.branchName,
			targetBranch: request.targetBranch,
			status: .open,
			checksStatus: .passed
		)
	}
}

private struct StaticAgentProvider: AgentProvider {
	let events: [AgentEvent]

	func runAgent(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
		AsyncThrowingStream { continuation in
			for event in events {
				continuation.yield(event)
			}
			continuation.finish()
		}
	}
}

private actor RecordingGitHubTransport: GitHubAPITransport {
	private var responses: [MockGitHubResponse]
	private var urls: [URL] = []
	private var methods: [String] = []
	private var bodyStrings: [String] = []

	init(responses: [MockGitHubResponse]) {
		self.responses = responses
	}

	func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		if let url = request.url {
			urls.append(url)
		}
		methods.append(request.httpMethod ?? "GET")
		bodyStrings.append(request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "")
		let response = responses.isEmpty ? MockGitHubResponse(payload: "[]", statusCode: 500) : responses.removeFirst()
		let httpResponse = HTTPURLResponse(
			url: request.url ?? URL(string: "https://api.github.com")!,
			statusCode: response.statusCode,
			httpVersion: nil,
			headerFields: response.headers
		)!
		return (Data(response.payload.utf8), httpResponse)
	}

	func requestedURLs() -> [URL] {
		urls
	}

	func requestedMethods() -> [String] {
		methods
	}

	func requestedBodyStrings() -> [String] {
		bodyStrings
	}
}

@discardableResult
private func git(_ arguments: [String], in workingDirectory: URL? = nil) async throws -> ProcessResult {
	try await ProcessCommand.run(executable: "/usr/bin/git", arguments: arguments, workingDirectory: workingDirectory)
}

private extension [URLQueryItem] {
	func first(named name: String) -> URLQueryItem? {
		first { $0.name == name }
	}
}

private struct StaticIssueTrackerProvider: IssueTrackerProvider {
	let kind = IssueProviderKind.githubIssues
	let tickets: [TicketDescriptor]

	func listTickets(projectID: String) async throws -> [TicketDescriptor] {
		tickets
	}

	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws {}
	func addComment(ticketID: String, body: String) async throws {}
}
