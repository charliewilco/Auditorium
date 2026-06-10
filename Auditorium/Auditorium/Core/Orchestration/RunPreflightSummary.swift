import Foundation

struct RunPreflightSummary: Equatable {
	enum CheckState: String, Equatable {
		case passed
		case warning
		case blocked

		var title: String {
			switch self {
			case .passed: "Ready"
			case .warning: "Review"
			case .blocked: "Blocked"
			}
		}
	}

	struct Check: Identifiable, Equatable {
		let id: String
		let title: String
		let detail: String
		let state: CheckState
	}

	let repositoryName: String
	let issueCount: Int
	let enabledIssueCount: Int
	let branchPrefix: String
	let validationCommand: String
	let opensPullRequests: Bool
	let workspaceRoot: String
	let accountTitle: String
	let scopeSummary: String
	let checks: [Check]

	var blockingChecks: [Check] {
		checks.filter { $0.state == .blocked }
	}

	var canStartRun: Bool {
		blockingChecks.isEmpty
	}

	static func make(
		project: Project,
		queueItems: [QueueItemRecord],
		tickets: [TicketRecord],
		runtimeHealth: [RuntimeHealthCheck],
		providerAccounts: [ProviderAccountRecord],
		preferences: RunSecurityPreferences,
		workspaceRoot: String,
		secretReader: (String) throws -> String?
	) -> RunPreflightSummary {
		let enabledQueueItems = queueItems.filter(\.isEnabled).sorted { $0.position < $1.position }
		var checks: [Check] = []
		let parsedPolicy: ParsedWorkflowPolicy?
		do {
			parsedPolicy = try WorkflowPolicyParser().parse(project.workflowPolicyMarkdown)
			checks.append(
				Check(
					id: "workflow",
					title: "Workflow Policy",
					detail: "Concurrency \(parsedPolicy?.concurrency ?? 1), max retries \(parsedPolicy?.maxRetries ?? 0).",
					state: .passed
				)
			)
		}
		catch {
			parsedPolicy = nil
			checks.append(
				Check(
					id: "workflow",
					title: "Workflow Policy",
					detail: error.localizedDescription,
					state: .blocked
				)
			)
		}

		checks.append(
			Check(
				id: "queue",
				title: "Enabled Tickets",
				detail: enabledQueueItems.isEmpty
					? "No enabled queue items are ready to run." : "\(enabledQueueItems.count) tickets will run.",
				state: enabledQueueItems.isEmpty ? .blocked : .passed
			)
		)

		checks.append(
			contentsOf: permissionChecks(
				project: project,
				preferences: preferences,
				opensPullRequests: parsedPolicy?.openPullRequest ?? true
			)
		)
		checks.append(contentsOf: toolChecks(project: project, runtimeHealth: runtimeHealth))
		let account = githubAccountState(providerAccounts: providerAccounts, secretReader: secretReader)
		checks.append(account.check)

		return RunPreflightSummary(
			repositoryName: project.repositoryName,
			issueCount: tickets.count,
			enabledIssueCount: enabledQueueItems.count,
			branchPrefix: parsedPolicy?.branchPrefix ?? "Unavailable",
			validationCommand: parsedPolicy?.validationCommand
				?? (parsedPolicy?.runTests == true
					? "Workflow tests enabled; no command configured." : "No validation command configured."),
			opensPullRequests: parsedPolicy?.openPullRequest ?? true,
			workspaceRoot: workspaceRoot,
			accountTitle: account.title,
			scopeSummary: account.scopeSummary,
			checks: checks
		)
	}

	private static func permissionChecks(
		project: Project,
		preferences: RunSecurityPreferences,
		opensPullRequests: Bool
	) -> [Check] {
		let policy = RunSecurityPolicy()
		var checks: [Check] = []
		let networkRequired = policy.requiresNetwork(project: project)
		checks.append(
			Check(
				id: "network",
				title: "Network Access",
				detail: networkRequired
					? (preferences.allowNetworkAccess
						? "Enabled for GitHub, gh, and Codex operations." : "Disabled; real GitHub/Codex runs cannot start.")
					: "Not required for the selected offline runtime.",
				state: networkRequired && preferences.allowNetworkAccess == false ? .blocked : .passed
			)
		)
		checks.append(
			Check(
				id: "filesystem",
				title: "Filesystem Writes",
				detail: preferences.allowFilesystemWrite
					? "Enabled for workspaces, logs, and reports." : "Disabled; runs cannot create workspaces or reports.",
				state: preferences.allowFilesystemWrite ? .passed : .blocked
			)
		)
		checks.append(
			Check(
				id: "pull-request-confirmation",
				title: "Pull Request Confirmation",
				detail: pullRequestConfirmationDetail(
					opensPullRequests: opensPullRequests,
					requiresConfirmation: preferences.requirePullRequestConfirmation
				),
				state: opensPullRequests && preferences.requirePullRequestConfirmation == false ? .warning : .passed
			)
		)
		return checks
	}

	private static func pullRequestConfirmationDetail(opensPullRequests: Bool, requiresConfirmation: Bool) -> String {
		if opensPullRequests == false {
			return "Workflow will not open pull requests; confirmation is not required."
		}
		return requiresConfirmation
			? "Auditorium will ask before workflows that may push branches and open PRs."
			: "Confirmation is disabled for workflows that may open PRs."
	}

	private static func toolChecks(project: Project, runtimeHealth: [RuntimeHealthCheck]) -> [Check] {
		var requiredIDs: [(String, String)] = []
		if project.runtimeProviderKind == .localWorkspace {
			requiredIDs.append(("git", "Git"))
		}
		if project.agentProviderKind == .codex {
			requiredIDs.append(("codex", "Codex CLI"))
		}
		if project.repositoryProviderKind == .github || project.issueProviderKind == .githubIssues {
			requiredIDs.append(("gh", "GitHub CLI"))
		}
		if requiredIDs.isEmpty {
			return [
				Check(
					id: "tools",
					title: "Local Tools",
					detail: "Mock runtime and mock agent do not require local CLI tools.",
					state: .passed
				)
			]
		}
		let checksByID = Dictionary(uniqueKeysWithValues: runtimeHealth.map { ($0.id, $0) })
		return requiredIDs.map { id, title in
			let health = checksByID[id]
			let isAvailable = health?.state == .available
			return Check(
				id: "tool-\(id)",
				title: title,
				detail: health?.detail ?? "\(title) has not been checked yet.",
				state: isAvailable ? .passed : .blocked
			)
		}
	}

	private static func githubAccountState(
		providerAccounts: [ProviderAccountRecord],
		secretReader: (String) throws -> String?
	) -> (title: String, scopeSummary: String, check: Check) {
		let accounts = providerAccounts.filter {
			$0.providerKindRaw == RepositoryProviderKind.github.rawValue || $0.providerKindRaw == IssueProviderKind.githubIssues.rawValue
		}
		guard let account = accounts.first else {
			return (
				"GitHub",
				"No scopes available.",
				Check(id: "github-account", title: "GitHub Account", detail: "No GitHub account is connected.", state: .blocked)
			)
		}
		let secret = (try? secretReader(account.keychainAccount))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard secret.isEmpty == false else {
			return (
				account.displayName,
				scopeText(account.grantedScopes),
				Check(
					id: "github-account",
					title: "GitHub Account",
					detail: "Credential metadata exists, but the Keychain secret is missing.",
					state: .blocked
				)
			)
		}
		let missingScopes = requiredGitHubScopes.subtracting(account.grantedScopes)
		if account.grantedScopes.isEmpty == false, missingScopes.isEmpty == false {
			return (
				account.displayName,
				scopeText(account.grantedScopes),
				Check(
					id: "github-account",
					title: "GitHub Account",
					detail: "Connected, but missing scopes: \(missingScopes.sorted().joined(separator: ", ")).",
					state: .blocked
				)
			)
		}
		let scopeSummary = account.grantedScopes.isEmpty ? "Scope metadata unavailable." : scopeText(account.grantedScopes)
		return (
			account.displayName,
			scopeSummary,
			Check(id: "github-account", title: "GitHub Account", detail: "Connected with Keychain-backed credentials.", state: .passed)
		)
	}

	private static var requiredGitHubScopes: Set<String> {
		["repo", "read:user"]
	}

	private static func scopeText(_ scopes: Set<String>) -> String {
		scopes.isEmpty ? "No scopes recorded." : scopes.sorted().joined(separator: ", ")
	}
}
