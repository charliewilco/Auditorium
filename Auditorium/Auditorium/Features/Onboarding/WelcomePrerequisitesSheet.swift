import SwiftUI

struct WelcomePrerequisitesSheet: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.appServices) private var services
	@State private var checks: [RuntimeHealthCheck] = []
	@State private var isChecking = false

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			HStack(alignment: .firstTextBaseline) {
				VStack(alignment: .leading, spacing: 4) {
					Text("Onboarding Check")
						.font(.title2.weight(.semibold))
					Text("Auditorium needs local container support, Codex, and GitHub access before real runs.")
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer()
				Button {
					dismiss()
				} label: {
					Image(systemName: "xmark")
				}
				.buttonStyle(.borderless)
				.accessibilityLabel("Close")
			}

			if isChecking && checks.isEmpty {
				HStack(spacing: 8) {
					ProgressView()
						.controlSize(.small)
					Text("Checking local prerequisites...")
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.vertical, 20)
			}
			else {
				OnboardingPrerequisiteStatusView(checks: checks)
			}

			Divider()

			HStack {
				Text(summary)
					.font(.caption)
					.foregroundStyle(.secondary)
				Spacer()
				Button {
					Task { await refresh() }
				} label: {
					Label("Refresh", systemImage: "arrow.clockwise")
				}
				.disabled(isChecking)
				Button("Done") {
					dismiss()
				}
				.keyboardShortcut(.defaultAction)
			}
		}
		.padding(22)
		.frame(width: 520)
		.task {
			await refresh()
		}
	}

	private var summary: String {
		if checks.isEmpty {
			return "No checks have run yet."
		}
		let blockedCount = checks.filter { $0.state != .available }.count
		if blockedCount == 0 {
			return "All onboarding checks are ready."
		}
		return "\(blockedCount) onboarding check\(blockedCount == 1 ? "" : "s") need attention."
	}

	private func refresh() async {
		isChecking = true
		checks = await services.runtimeDetection.onboardingChecks()
		isChecking = false
	}
}

#Preview {
	WelcomePrerequisitesSheet()
}
