import Foundation
import SwiftData

enum ProjectCreationError: LocalizedError {
	case invalidDraft
	case projectNotFound(UUID)

	var errorDescription: String? {
		switch self {
		case .invalidDraft:
			"Project name, repository, default branch, and issue source are required."
		case .projectNotFound(let id):
			"Project \(id.uuidString) could not be found."
		}
	}
}

@MainActor
struct ProjectCreationService {
	func createProject(
		from draft: ProjectDraft,
		context: ModelContext,
		workspaceService: ApplicationWorkspaceService,
		keychainService: KeychainService? = nil
	) throws -> UUID {
		guard draft.canCreate else {
			throw ProjectCreationError.invalidDraft
		}

		let project = Project(
			name: draft.trimmedName,
			repositoryProviderKind: draft.repositoryProviderKind,
			repositoryName: draft.trimmedRepositoryName,
			repositoryURL: draft.trimmedRepositoryURL,
			defaultBranch: draft.trimmedDefaultBranch,
			issueProviderKind: draft.issueProviderKind,
			runtimeProviderKind: draft.runtimeProviderKind,
			agentProviderKind: draft.agentProviderKind,
			workflowPolicyMarkdown: draft.resolvedWorkflowPolicyMarkdown
		)
		let repositoryAccountID: UUID?
		let issueAccountID: UUID?
		if draft.repositoryProviderKind == .github, draft.issueProviderKind == .githubIssues {
			let sharedCredential = draft.repositoryCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? draft.issueCredential : draft.repositoryCredential
			let sharedAccountID = try storeCredentialIfNeeded(
				sharedCredential,
				providerKind: draft.repositoryProviderKind.rawValue,
				displayName: "GitHub OAuth for \(draft.trimmedRepositoryName)",
				projectID: project.id,
				credentialRole: "github-oauth",
				context: context,
				keychainService: keychainService
			)
			repositoryAccountID = sharedAccountID
			issueAccountID = sharedAccountID
		} else {
			repositoryAccountID = try storeCredentialIfNeeded(
				draft.repositoryCredential,
				providerKind: draft.repositoryProviderKind.rawValue,
				displayName: "\(draft.repositoryProviderKind.title) for \(draft.trimmedRepositoryName)",
				projectID: project.id,
				credentialRole: "repository",
				context: context,
				keychainService: keychainService
			)
			issueAccountID = try storeCredentialIfNeeded(
				draft.issueCredential,
				providerKind: draft.issueProviderKind.rawValue,
				displayName: "\(draft.issueProviderKind.title) for \(draft.issueSourceName)",
				projectID: project.id,
				credentialRole: "issues",
				context: context,
				keychainService: keychainService
			)
		}

		context.insert(project)
		context.insert(RepositoryRecord(
			provider: draft.repositoryProviderKind,
			owner: repositoryOwner(from: draft.trimmedRepositoryName),
			name: repositoryShortName(from: draft.trimmedRepositoryName),
			fullName: draft.trimmedRepositoryName,
			cloneURL: cloneURL(from: draft.trimmedRepositoryURL),
			webURL: draft.trimmedRepositoryURL,
			defaultBranch: draft.trimmedDefaultBranch,
			localPath: workspaceService.repositoryDirectory(projectID: project.id).path(),
			providerAccountID: repositoryAccountID,
			projectID: project.id
		))
		context.insert(IssueTrackerRecord(
			provider: draft.issueProviderKind,
			displayName: draft.issueSourceName.trimmingCharacters(in: .whitespacesAndNewlines),
			sourceIdentifier: draft.issueSourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
			filterName: draft.issueFilterName.trimmingCharacters(in: .whitespacesAndNewlines),
			webURL: draft.issueTrackerURL.trimmingCharacters(in: .whitespacesAndNewlines),
			projectID: project.id,
			providerAccountID: issueAccountID
		))

		if draft.importDemoTickets {
			insertDemoTickets(projectID: project.id, context: context)
		}

		try workspaceService.ensureProjectLayout(projectID: project.id)
		try context.save()
		return project.id
	}

	private func storeCredentialIfNeeded(
		_ credential: String,
		providerKind: String,
		displayName: String,
		projectID: UUID,
		credentialRole: String,
		context: ModelContext,
		keychainService: KeychainService?
	) throws -> UUID? {
		let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, let keychainService else {
			return nil
		}

		let accountID = UUID()
		let keychainAccount = "\(projectID.uuidString)-\(credentialRole)-\(providerKind)"
		try keychainService.storeSecret(trimmed, account: keychainAccount)
		context.insert(ProviderAccountRecord(
			id: accountID,
			providerKindRaw: providerKind,
			displayName: displayName,
			keychainAccount: keychainAccount
		))
		return accountID
	}

	private func insertDemoTickets(projectID: UUID, context: ModelContext) {
		for demoTicket in DemoTickets.all {
			let descriptor = demoTicket.descriptor
			context.insert(TicketRecord(
				provider: descriptor.provider,
				externalID: descriptor.externalID,
				title: descriptor.title,
				body: descriptor.body,
				status: descriptor.status,
				labels: descriptor.labels,
				assignee: descriptor.assignee,
				priority: descriptor.priority,
				webURL: descriptor.webURL?.absoluteString ?? "",
				createdAt: descriptor.createdAt,
				updatedAt: descriptor.updatedAt,
				estimatedComplexity: descriptor.estimatedComplexity,
				blockedBy: descriptor.blockedBy,
				sourceProjectID: projectID
			))
		}
	}

	private func repositoryOwner(from fullName: String) -> String {
		String(fullName.split(separator: "/").first ?? "local")
	}

	private func repositoryShortName(from fullName: String) -> String {
		String(fullName.split(separator: "/").last ?? Substring(fullName))
	}

	private func cloneURL(from repositoryURL: String) -> String {
		repositoryURL.hasSuffix(".git") ? repositoryURL : "\(repositoryURL).git"
	}
}
