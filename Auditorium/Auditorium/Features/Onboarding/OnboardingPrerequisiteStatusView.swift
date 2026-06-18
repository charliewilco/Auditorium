import SwiftUI

struct OnboardingPrerequisiteStatusView: View {
	let checks: [RuntimeHealthCheck]

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			ForEach(checks) { check in
				HStack(alignment: .top, spacing: 10) {
					Image(systemName: symbol(for: check.state))
						.foregroundStyle(check.state.tint)
						.frame(width: 18)
					VStack(alignment: .leading, spacing: 3) {
						HStack(alignment: .firstTextBaseline, spacing: 8) {
							Text(check.name)
								.font(.subheadline.weight(.semibold))
							StatusBadge(title: check.state.title, tint: check.state.tint)
						}
						Text(check.detail)
							.font(.caption)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
						if let version = check.version, version.isEmpty == false {
							Text(version)
								.font(.caption2)
								.foregroundStyle(.tertiary)
								.lineLimit(1)
						}
					}
					Spacer(minLength: 0)
				}
				.padding(.vertical, 3)
			}
		}
	}

	private func symbol(for state: RuntimeHealthState) -> String {
		switch state {
		case .available:
			"checkmark.circle.fill"
		case .unavailable:
			"exclamationmark.triangle.fill"
		case .needsSetup:
			"wrench.and.screwdriver.fill"
		case .unsupported:
			"circle.slash"
		case .error:
			"xmark.octagon.fill"
		}
	}
}

#Preview {
	OnboardingPrerequisiteStatusView(checks: [
		RuntimeHealthCheck(
			id: "container",
			name: "Container CLI",
			state: .unavailable,
			detail: "Container CLI is installed, but the container system is not running.",
			version: "container CLI version 0.12.3"
		),
		RuntimeHealthCheck(
			id: "codex-auth",
			name: "Codex",
			state: .available,
			detail: "Logged in using ChatGPT",
			version: "codex-cli 0.139.0"
		),
		RuntimeHealthCheck(
			id: "github-auth",
			name: "GitHub",
			state: .available,
			detail: "GitHub CLI is authenticated for github.com as charliewilco.",
			version: "gh version 2.93.0"
		),
	])
	.padding()
	.frame(width: 420)
}
