import Foundation

struct MockGitHubRepositoryProvider: RepositoryProvider {
	let kind = RepositoryProviderKind.github
	let authentication = ProviderAuthenticationDescriptor(method: .oauth, displayName: "Mock GitHub OAuth", oauth: GitHubOAuth.descriptor)

	func listRepositories() async throws -> [RepositoryDescriptor] {
		[
			RepositoryDescriptor(
				provider: .github,
				owner: "charlie",
				name: "burton-ios",
				fullName: "charlie/burton-ios",
				cloneURL: URL(string: "https://github.com/charlie/burton-ios.git")!,
				webURL: URL(string: "https://github.com/charlie/burton-ios")!,
				defaultBranch: "next"
			)
		]
	}

	func cloneOrUpdate(repository: RepositoryDescriptor, into path: URL) async throws {
		try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
	}

	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor {
		let number = abs(request.branchName.hashValue % 900) + 100
		return PullRequestDescriptor(
			title: request.title,
			url: URL(string: "https://example.com/\(request.repository.fullName)/pull/\(number)")!,
			branchName: request.branchName,
			targetBranch: request.targetBranch,
			status: .open,
			checksStatus: .passed
		)
	}
}

struct MockGitHubIssueTrackerProvider: IssueTrackerProvider {
	let kind = IssueProviderKind.githubIssues
	let authentication = ProviderAuthenticationDescriptor(method: .oauth, displayName: "Mock GitHub OAuth", oauth: GitHubOAuth.descriptor)

	func listTickets(projectID: String) async throws -> [TicketDescriptor] {
		DemoTickets.all.map(\.descriptor)
	}

	func updateTicketStatus(ticketID: String, status: TicketStatus) async throws {}

	func addComment(ticketID: String, body: String) async throws {}
}

typealias MockLinearIssueProvider = MockGitHubIssueTrackerProvider

struct MockRuntimeProvider: RuntimeProvider {
	let workspaceService: ApplicationWorkspaceService
	let projectID: UUID

	func prepareWorkspace(for ticket: TicketDescriptor, repository: RepositoryDescriptor) async throws -> WorkspaceDescriptor {
		let workspace = workspaceService.workspacePath(projectID: projectID, ticketExternalID: ticket.externalID)
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		let branch = "auditorium/\(workspaceService.sanitize(ticket.externalID))-\(workspaceService.sanitize(ticket.title).prefix(32))"
		return WorkspaceDescriptor(path: workspace, runtimeID: "mock-\(ticket.externalID.lowercased())", branchName: branch)
	}

	func startExecution(_ request: RuntimeExecutionRequest) async throws -> RuntimeExecutionHandle {
		if request.environment.isEmpty == false {
			let metadataDirectory = request.workspace.path.appending(path: ".auditorium")
			try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
			let payload = #"{"injectedVariableCount":\#(request.environment.count)}"#
			try payload.write(to: metadataDirectory.appending(path: "runtime-environment.json"), atomically: true, encoding: .utf8)
		}
		return RuntimeExecutionHandle(id: request.workspace.runtimeID, workspacePath: request.workspace.path)
	}

	func stopExecution(handle: RuntimeExecutionHandle) async throws {}
}

struct MockCodexAgentProvider: AgentProvider {
	func runAgent(_ request: AgentRunRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
		let outcome = MockOutcomePolicy.outcome(for: request.ticket.externalID)
		let steps: [AgentEvent] = [
			AgentEvent(level: .info, category: .runtime, message: "Creating isolated workspace", summary: nil, outcome: nil),
			AgentEvent(
				level: .info,
				category: .runtime,
				message: "Starting mock runtime \(request.workspace.runtimeID)",
				summary: nil,
				outcome: nil
			),
			AgentEvent(level: .info, category: .agent, message: "Reading \(request.ticket.externalID)", summary: nil, outcome: nil),
			AgentEvent(level: .info, category: .agent, message: "Planning focused implementation", summary: nil, outcome: nil),
			AgentEvent(
				level: .info,
				category: .agent,
				message: "Editing repository files in \(request.workspace.path.lastPathComponent)",
				summary: nil,
				outcome: nil
			),
			AgentEvent(level: .info, category: .tests, message: "Running relevant validation", summary: nil, outcome: nil),
			finalEvent(outcome: outcome, request: request),
		]

		return AsyncThrowingStream { continuation in
			Task {
				for step in steps {
					try? await Task.sleep(nanoseconds: 450_000_000)
					continuation.yield(step)
				}
				continuation.finish()
			}
		}
	}

	private func finalEvent(outcome: MockTicketOutcome, request: AgentRunRequest) -> AgentEvent {
		switch outcome {
		case .completed:
			return AgentEvent(
				level: .success,
				category: .pullRequest,
				message: "Pull request opened for \(request.ticket.externalID)",
				summary: "Implemented \(request.ticket.title), validated the focused path, and opened a pull request for review.",
				outcome: .completed
			)
		case .blocked:
			return AgentEvent(
				level: .warning,
				category: .agent,
				message: "Blocked: missing product decision for \(request.ticket.externalID)",
				summary: "The ticket needs a human decision before implementation should continue.",
				outcome: .blocked
			)
		case .failed:
			return AgentEvent(
				level: .error,
				category: .tests,
				message: "Validation failed for \(request.ticket.externalID)",
				summary: "The agent reached test failures that need manual review before retrying.",
				outcome: .failed
			)
		}
	}
}

enum MockOutcomePolicy {
	static func outcome(for externalID: String) -> MockTicketOutcome {
		if externalID.hasSuffix("103") || externalID.hasSuffix("107") {
			return .blocked
		}
		if externalID.hasSuffix("106") {
			return .failed
		}
		return .completed
	}
}
