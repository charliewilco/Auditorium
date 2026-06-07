import Foundation

struct RunSecurityPreferences: Sendable, Equatable {
	let allowNetworkAccess: Bool
	let allowFilesystemWrite: Bool
	let requireRunConfirmation: Bool
	let requirePullRequestConfirmation: Bool
	let runtimeIsolationLevel: RuntimeIsolationLevel

	init(
		allowNetworkAccess: Bool,
		allowFilesystemWrite: Bool,
		requireRunConfirmation: Bool,
		requirePullRequestConfirmation: Bool,
		runtimeIsolationLevel: RuntimeIsolationLevel = .localWorkspace
	) {
		self.allowNetworkAccess = allowNetworkAccess
		self.allowFilesystemWrite = allowFilesystemWrite
		self.requireRunConfirmation = requireRunConfirmation
		self.requirePullRequestConfirmation = requirePullRequestConfirmation
		self.runtimeIsolationLevel = runtimeIsolationLevel
	}
}

enum RunSecurityPolicyError: LocalizedError, Equatable {
	case networkAccessDisabled
	case filesystemWriteDisabled
	case runtimeIsolationDisallowsProvider(RuntimeIsolationLevel, RuntimeProviderKind)

	var errorDescription: String? {
		switch self {
		case .networkAccessDisabled:
			"Network access is disabled in Settings. Enable it before running a real GitHub/Codex workspace."
		case .filesystemWriteDisabled:
			"Filesystem writes are disabled in Settings. Enable them before starting a run."
		case .runtimeIsolationDisallowsProvider(let isolationLevel, let runtimeProvider):
			"\(runtimeProvider.title) is not allowed by the \(isolationLevel.title) isolation setting."
		}
	}
}

struct RunSecurityPolicy {
	func validate(project: Project, preferences: RunSecurityPreferences) throws {
		if preferences.runtimeIsolationLevel.allows(runtimeProviderKind: project.runtimeProviderKind) == false {
			throw RunSecurityPolicyError.runtimeIsolationDisallowsProvider(preferences.runtimeIsolationLevel, project.runtimeProviderKind)
		}
		if requiresNetwork(project: project), preferences.allowNetworkAccess == false {
			throw RunSecurityPolicyError.networkAccessDisabled
		}
		if requiresFilesystemWrite(project: project), preferences.allowFilesystemWrite == false {
			throw RunSecurityPolicyError.filesystemWriteDisabled
		}
	}

	func requiresNetwork(project: Project) -> Bool {
		project.runtimeProviderKind == .localWorkspace || project.agentProviderKind == .codex
	}

	func requiresFilesystemWrite(project: Project) -> Bool {
		true
	}

	func wouldOpenPullRequest(project: Project) -> Bool {
		project.workflowPolicyMarkdown.contains("open_pull_request: true")
	}
}
