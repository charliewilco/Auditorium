import Foundation
import Observation

enum ProjectSetupStep: Int, CaseIterable, Identifiable {
	case repositoryProvider
	case repositoryCredentials
	case repository
	case issueProvider
	case issueCredentials
	case issueSource
	case runtime
	case agent
	case runDefaults
	case review

	var id: Int { rawValue }

	var title: String {
		switch self {
		case .repositoryProvider: "Repository Provider"
		case .repositoryCredentials: "Repository Credentials"
		case .repository: "Repository"
		case .issueProvider: "Issue Source"
		case .issueCredentials: "Issue Credentials"
		case .issueSource: "Issue Filter"
		case .runtime: "Runtime"
		case .agent: "Agent"
		case .runDefaults: "Run Defaults"
		case .review: "Review"
		}
	}

	@MainActor
	func validationMessage(for draft: ProjectDraft) -> String? {
		switch self {
		case .repositoryProvider:
			return nil
		case .repositoryCredentials:
			return draft.hasRepositoryCredential == false
				? "Connect GitHub or paste an access token before selecting a repository." : nil
		case .repository:
			if draft.trimmedName.isEmpty {
				return "Project name is required."
			}
			if draft.trimmedRepositoryName.isEmpty {
				return "Repository is required."
			}
			if draft.trimmedRepositoryURL.isEmpty {
				return "Repository URL is required."
			}
			if draft.trimmedDefaultBranch.isEmpty {
				return "Default branch is required."
			}
			return nil
		case .issueProvider:
			return nil
		case .issueCredentials:
			return draft.hasGitHubCredential ? nil : "Connect GitHub or paste an access token before selecting issues."
		case .issueSource:
			if draft.trimmedIssueSourceName.isEmpty {
				return "Issue source name is required."
			}
			if draft.trimmedIssueSourceIdentifier.isEmpty {
				return "Issue source identifier is required."
			}
			if draft.importGitHubIssues && draft.trimmedIssueTrackerURL.isEmpty {
				return "Issue tracker URL is required when importing GitHub issues."
			}
			return nil
		case .runtime:
			return nil
		case .agent:
			return nil
		case .runDefaults:
			if draft.concurrency < 1 {
				return "Concurrency must be at least 1."
			}
			if draft.maxRetries < 0 {
				return "Max retries cannot be negative."
			}
			if draft.trimmedBranchPrefix.isEmpty {
				return "Branch prefix is required."
			}
			return nil
		case .review:
			return draft.canCreate ? nil : "Project name, repository, default branch, and issue source are required."
		}
	}
}

@Observable
@MainActor
final class ProjectDraft {
	var name = "Burton Demo"
	var repositoryProviderKind: RepositoryProviderKind = .github
	var repositoryName = "charlie/burton-ios"
	var repositoryURL = "https://github.com/charlie/burton-ios"
	var defaultBranch = "next"
	var repositoryCredential = ""
	var selectedRepositoryAccountID: UUID?
	var issueProviderKind: IssueProviderKind = .githubIssues
	var issueSourceName = "charlie/burton-ios"
	var issueSourceIdentifier = "charlie/burton-ios"
	var issueFilterName = "Ready for agent"
	var issueTrackerURL = "https://github.com/charlie/burton-ios/issues"
	var issueCredential = ""
	var selectedIssueAccountID: UUID?
	var runtimeProviderKind: RuntimeProviderKind = .mockRuntime
	var agentProviderKind: AgentProviderKind = .mockAgent
	var concurrency = 3
	var maxRetries = 2
	var branchPrefix = "auditorium"
	var runTests = true
	var openPullRequest = true
	var workflowPolicyMarkdown = WorkflowPolicy.defaultMarkdown
	var importDemoTickets = true
	var importGitHubIssues = false

	var trimmedName: String {
		name.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var trimmedRepositoryName: String {
		repositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var trimmedRepositoryURL: String {
		repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var trimmedDefaultBranch: String {
		defaultBranch.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var trimmedRepositoryCredential: String {
		repositoryCredential.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var trimmedIssueCredential: String {
		issueCredential.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var hasRepositoryCredential: Bool {
		!trimmedRepositoryCredential.isEmpty || selectedRepositoryAccountID != nil
	}

	var hasIssueCredential: Bool {
		!trimmedIssueCredential.isEmpty || selectedIssueAccountID != nil
	}

	var hasGitHubCredential: Bool {
		hasRepositoryCredential || hasIssueCredential
	}

	var trimmedIssueSourceName: String {
		issueSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var trimmedIssueSourceIdentifier: String {
		issueSourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var trimmedIssueTrackerURL: String {
		issueTrackerURL.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var trimmedBranchPrefix: String {
		branchPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var canCreate: Bool {
		!trimmedName.isEmpty && !trimmedRepositoryName.isEmpty && !trimmedRepositoryURL.isEmpty && !trimmedDefaultBranch.isEmpty
			&& !trimmedIssueSourceName.isEmpty
	}

	var resolvedWorkflowPolicyMarkdown: String {
		"""
		---
		concurrency: \(concurrency)
		max_retries: \(maxRetries)
		handoff_status: "Needs Review"
		update_issue_labels: false
		branch_prefix: "\(trimmedBranchPrefix.isEmpty ? "auditorium" : trimmedBranchPrefix)"
		run_tests: \(runTests)
		open_pull_request: \(openPullRequest)
		---
		You are an autonomous coding agent working on a single issue.
		Your job:
		1. Read the issue carefully.
		2. Inspect the repository.
		3. Create a focused implementation plan.
		4. Make the smallest correct change.
		5. Run relevant tests.
		6. Fix failures.
		7. Commit changes on a ticket-specific branch.
		8. Open a pull request.
		9. Leave a concise summary for human review.
		Do not make unrelated changes.
		Do not touch secrets.
		Do not rewrite large areas unless the issue requires it.
		When blocked, explain exactly what is missing.
		"""
	}
}
