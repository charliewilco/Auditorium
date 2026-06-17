import SwiftUI

struct ProjectDashboardReadinessPanel: View {
	let state: ProjectDashboardState
	let openQueue: () -> Void
	let openSettings: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(alignment: .firstTextBaseline) {
				Label("Run Readiness", systemImage: symbol)
					.font(.headline)
				Spacer()
				StatusBadge(title: state.readinessTitle, tint: tint)
			}
			Text(state.readinessDetail)
				.font(.callout)
				.foregroundStyle(.secondary)
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
				ProjectDashboardValue(title: "Enabled", value: "\(state.enabledQueueCount)")
				ProjectDashboardValue(title: "Disabled", value: "\(state.disabledQueueCount)")
				ProjectDashboardValue(title: "Validation", value: state.validationCommand)
				ProjectDashboardValue(title: "Pull Requests", value: state.pullRequestPolicy)
			}
			HStack {
				if let topBlocker = state.topBlocker {
					Label(topBlocker, systemImage: "exclamationmark.triangle.fill")
						.font(.caption.weight(.medium))
						.foregroundStyle(.orange)
				}
				Spacer()
				Button {
					state.readinessKind == .blocked ? openSettings() : openQueue()
				} label: {
					Label(
						state.readinessKind == .blocked ? "Resolve" : "Open Queue",
						systemImage: state.readinessKind == .blocked ? "gear" : "list.bullet"
					)
				}
				.buttonStyle(.bordered)
				.disabled(state.readinessKind == .noProject)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private var tint: Color {
		switch state.readinessKind {
		case .noProject, .checking:
			.secondary
		case .ready:
			.green
		case .blocked:
			.orange
		}
	}

	private var symbol: String {
		switch state.readinessKind {
		case .noProject:
			"questionmark.circle"
		case .checking:
			"clock"
		case .ready:
			"checkmark.circle.fill"
		case .blocked:
			"exclamationmark.triangle.fill"
		}
	}
}

struct ProjectDashboardValue: View {
	let title: String
	let value: String

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title)
				.font(.caption.weight(.semibold))
				.foregroundStyle(.secondary)
			Text(value)
				.font(.callout)
				.lineLimit(2)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

#Preview("Readiness") {
	ProjectDashboardReadinessPanel(
		state: ProjectDashboardPreviewData.state,
		openQueue: {},
		openSettings: {}
	)
	.padding()
	.frame(width: 520)
}
