import Foundation

struct ProviderStateSummary: Identifiable, Sendable, Equatable {
	let id: String
	let title: String
	let detail: String
	let state: ProviderImplementationState

	var isAvailable: Bool {
		state == .implemented || state == .authenticated || state == .authorized || state == .detected
	}
}

enum ProviderStateSummaries {
	static func repositoryProviders() -> [ProviderStateSummary] {
		var providers: [ProviderStateSummary] = []
		for kind in RepositoryProviderKind.allCases {
			providers.append(repositoryProvider(kind))
		}
		return providers
	}

	static func issueProviders() -> [ProviderStateSummary] {
		var providers: [ProviderStateSummary] = []
		for kind in IssueProviderKind.allCases {
			providers.append(issueProvider(kind))
		}
		return providers
	}

	static func agentProviders() -> [ProviderStateSummary] {
		var providers: [ProviderStateSummary] = []
		for kind in AgentProviderKind.allCases {
			providers.append(agentProvider(kind))
		}
		return providers
	}

	static func runtimeProviders(from checks: [RuntimeHealthCheck]) -> [RuntimeProviderStatus] {
		RuntimeDetectionService.runtimeProviderStatuses(from: checks)
	}

	private static func repositoryProvider(_ kind: RepositoryProviderKind) -> ProviderStateSummary {
		switch kind {
		case .github:
			ProviderStateSummary(
				id: kind.id,
				title: kind.title,
				detail:
					"v0 source provider for repository listing, cloning, branches, commits, pushes, pull requests, and check status.",
				state: .implemented
			)
		case .gitlab, .bitbucket, .azureDevOps, .genericGit:
			ProviderStateSummary(
				id: kind.id,
				title: kind.title,
				detail: "Future adapter placeholder. Auditorium v0 source runs are GitHub-only.",
				state: .unavailable
			)
		}
	}

	private static func issueProvider(_ kind: IssueProviderKind) -> ProviderStateSummary {
		switch kind {
		case .githubIssues:
			ProviderStateSummary(
				id: kind.id,
				title: kind.title,
				detail: "v0 issue provider for GitHub issue import, filtering, comments, and optional handoff labels.",
				state: .implemented
			)
		case .linear, .asana, .gitlabIssues, .azureBoards, .imported:
			ProviderStateSummary(
				id: kind.id,
				title: kind.title,
				detail: "Future adapter placeholder. Auditorium v0 issue import is GitHub-only.",
				state: .unavailable
			)
		}
	}

	private static func agentProvider(_ kind: AgentProviderKind) -> ProviderStateSummary {
		switch kind {
		case .codex:
			ProviderStateSummary(
				id: kind.id,
				title: kind.title,
				detail:
					"Implemented through Codex CLI process execution with streamed output, logs, cancellation, and final status parsing.",
				state: .implemented
			)
		case .genericCLI:
			ProviderStateSummary(
				id: kind.id,
				title: kind.title,
				detail: "Implemented for local process execution with quoted command parsing, logs, and streamed output.",
				state: .implemented
			)
		case .mockAgent:
			ProviderStateSummary(
				id: kind.id,
				title: kind.title,
				detail: "Implemented as an offline deterministic agent for demo and test runs.",
				state: .implemented
			)
		}
	}
}
