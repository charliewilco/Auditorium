import Foundation

struct RunSecurityPreferences: Sendable, Equatable {
	let allowNetworkAccess: Bool
	let allowFilesystemWrite: Bool
	let requireRunConfirmation: Bool
	let requirePullRequestConfirmation: Bool
}

enum RunSecurityPolicyError: LocalizedError, Equatable {
	case networkAccessDisabled
	case filesystemWriteDisabled

	var errorDescription: String? {
		switch self {
		case .networkAccessDisabled:
			"Network access is disabled in Settings. Enable it before running a real GitHub/Codex workspace."
		case .filesystemWriteDisabled:
			"Filesystem writes are disabled in Settings. Enable them before starting a run."
		}
	}
}

struct RunSecurityPolicy {
	func validate(project: Project, preferences: RunSecurityPreferences) throws {
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
		(try? WorkflowPolicyParser().parse(project.workflowPolicyMarkdown).openPullRequest) ?? true
	}
}
