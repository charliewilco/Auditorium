import Foundation

enum WorkflowPolicyEditorError: LocalizedError, Equatable {
	case noProjectSelected
	case projectChanged
	case invalidPolicy(String)

	var errorDescription: String? {
		switch self {
		case .noProjectSelected:
			"No project is selected."
		case .projectChanged:
			"The selected project changed before the workflow policy could be saved."
		case .invalidPolicy(let message):
			message
		}
	}
}

struct WorkflowPolicyEditorState: Equatable {
	private(set) var projectID: UUID?
	private(set) var projectName: String
	private(set) var originalMarkdown: String
	var draftMarkdown: String {
		didSet {
			validateDraft()
		}
	}
	private(set) var parsedPolicy: ParsedWorkflowPolicy?
	private(set) var validationMessage: String
	private(set) var validationError: String?

	init(project: Project?) {
		self.projectID = project?.id
		self.projectName = project?.name ?? "No Project"
		self.originalMarkdown = project?.workflowPolicyMarkdown ?? WorkflowPolicy.defaultMarkdown
		self.draftMarkdown = project?.workflowPolicyMarkdown ?? WorkflowPolicy.defaultMarkdown
		self.validationMessage = ""
		self.validationError = nil
		validateDraft()
	}

	var hasProject: Bool {
		projectID != nil
	}

	var hasUnsavedChanges: Bool {
		draftMarkdown != originalMarkdown
	}

	var isValid: Bool {
		validationError == nil
	}

	var canSave: Bool {
		hasProject && hasUnsavedChanges && isValid
	}

	mutating func load(project: Project?) {
		projectID = project?.id
		projectName = project?.name ?? "No Project"
		originalMarkdown = project?.workflowPolicyMarkdown ?? WorkflowPolicy.defaultMarkdown
		draftMarkdown = originalMarkdown
		validateDraft()
	}

	mutating func revert() {
		draftMarkdown = originalMarkdown
	}

	mutating func restoreDefault() {
		draftMarkdown = WorkflowPolicy.defaultMarkdown
	}

	mutating func apply(to project: Project, now: Date = .now) throws {
		guard let projectID else {
			throw WorkflowPolicyEditorError.noProjectSelected
		}
		guard project.id == projectID else {
			throw WorkflowPolicyEditorError.projectChanged
		}
		if let validationError {
			throw WorkflowPolicyEditorError.invalidPolicy(validationError)
		}
		project.workflowPolicyMarkdown = draftMarkdown
		project.updatedAt = now
		originalMarkdown = draftMarkdown
	}

	private mutating func validateDraft() {
		do {
			parsedPolicy = try WorkflowPolicyParser().parse(draftMarkdown)
			validationError = nil
			validationMessage = "Policy is valid."
		}
		catch {
			parsedPolicy = nil
			validationError = error.localizedDescription
			validationMessage = error.localizedDescription
		}
	}
}
