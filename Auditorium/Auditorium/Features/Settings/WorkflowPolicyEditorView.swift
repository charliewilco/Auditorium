import SwiftData
import SwiftUI

struct WorkflowPolicyEditorView: View {
	let project: Project?
	@Environment(\.modelContext) private var modelContext
	@State private var editorState: WorkflowPolicyEditorState

	init(project: Project?) {
		self.project = project
		self._editorState = State(initialValue: WorkflowPolicyEditorState(project: project))
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				VStack(alignment: .leading, spacing: 4) {
					Text(editorState.projectName)
						.font(.subheadline.weight(.semibold))
					Text(editorState.validationMessage)
						.font(.caption)
						.foregroundStyle(editorState.isValid ? Color.secondary : Color.red)
				}
				Spacer()
				workflowActions
			}
			workflowSummary
			TextEditor(text: $editorState.draftMarkdown)
				.font(.system(.body, design: .monospaced))
				.frame(minHeight: 260)
				.scrollContentBackground(.hidden)
				.background(.background, in: RoundedRectangle(cornerRadius: 6))
				.overlay {
					RoundedRectangle(cornerRadius: 6)
						.stroke(.separator, lineWidth: 1)
				}
				.disabled(editorState.hasProject == false)
		}
		.onChange(of: project?.id) {
			editorState.load(project: project)
		}
	}

	private var workflowActions: some View {
		HStack(spacing: 8) {
			Button {
				editorState.restoreDefault()
			} label: {
				Label("Default", systemImage: "arrow.counterclockwise")
			}
			.disabled(editorState.hasProject == false)
			Button {
				editorState.revert()
			} label: {
				Label("Revert", systemImage: "arrow.uturn.backward")
			}
			.disabled(editorState.hasUnsavedChanges == false)
			Button {
				save()
			} label: {
				Label("Save", systemImage: "square.and.arrow.down")
			}
			.buttonStyle(.borderedProminent)
			.disabled(editorState.canSave == false)
		}
	}

	private var workflowSummary: some View {
		Group {
			if let policy = editorState.parsedPolicy {
				LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
					workflowSummaryItem("Concurrency", "\(policy.concurrency)")
					workflowSummaryItem("Retries", "\(policy.maxRetries)")
					workflowSummaryItem("Backoff", "\(policy.maxRetryBackoffMilliseconds / 1_000)s")
					workflowSummaryItem("Branch", policy.branchPrefix)
					workflowSummaryItem("Tests", policy.runTests ? "On" : "Off")
					workflowSummaryItem("Validation", policy.validationCommand ?? "Not configured")
					workflowSummaryItem("Pull Request", policy.openPullRequest ? "On" : "Off")
				}
			}
		}
	}

	private func workflowSummaryItem(_ title: String, _ value: String) -> some View {
		LabeledContent(title, value: value)
			.font(.caption)
	}

	private func save() {
		do {
			guard let project else {
				throw WorkflowPolicyEditorError.noProjectSelected
			}
			try editorState.apply(to: project)
			try modelContext.save()
		}
		catch {
			NSAlert(error: error).runModal()
		}
	}
}

#Preview {
	let project = Project(
		name: "Preview Project",
		repositoryProviderKind: .github,
		repositoryName: "charliewilco/Auditorium",
		repositoryURL: "https://github.com/charliewilco/Auditorium",
		defaultBranch: "main",
		issueProviderKind: .githubIssues,
		runtimeProviderKind: .localWorkspace,
		agentProviderKind: .codex
	)
	WorkflowPolicyEditorView(project: project)
		.padding()
		.modelContainer(for: Project.self, inMemory: true)
}
