import Foundation
import Observation

@Observable
@MainActor
final class ProjectDraft {
	var name = "Burton Demo"
	var repositoryProviderKind: RepositoryProviderKind = .github
	var repositoryName = "charlie/burton-ios"
	var repositoryURL = "https://github.com/charlie/burton-ios"
	var defaultBranch = "next"
	var repositoryCredential = ""
	var issueProviderKind: IssueProviderKind = .githubIssues
	var issueSourceName = "charlie/burton-ios"
	var issueSourceIdentifier = "charlie/burton-ios"
	var issueFilterName = "Ready for agent"
	var issueTrackerURL = "https://github.com/charlie/burton-ios/issues"
	var issueCredential = ""
	var runtimeProviderKind: RuntimeProviderKind = .mockRuntime
	var agentProviderKind: AgentProviderKind = .mockAgent
	var concurrency = 3
	var maxRetries = 2
	var branchPrefix = "auditorium"
	var runTests = true
	var openPullRequest = true
	var workflowPolicyMarkdown = WorkflowPolicy.defaultMarkdown
	var importDemoTickets = true

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

	var canCreate: Bool {
		!trimmedName.isEmpty &&
		!trimmedRepositoryName.isEmpty &&
		!trimmedRepositoryURL.isEmpty &&
		!trimmedDefaultBranch.isEmpty &&
		!issueSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	var resolvedWorkflowPolicyMarkdown: String {
		"""
		---
		concurrency: \(concurrency)
		max_retries: \(maxRetries)
		handoff_status: "Needs Review"
		branch_prefix: "\(branchPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "auditorium" : branchPrefix.trimmingCharacters(in: .whitespacesAndNewlines))"
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
