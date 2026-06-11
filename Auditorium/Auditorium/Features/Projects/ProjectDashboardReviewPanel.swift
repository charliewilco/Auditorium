import SwiftUI

struct ProjectDashboardReviewPanel: View {
	let state: ProjectDashboardState
	let inspectTicket: (UUID) -> Void
	let openRuns: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack {
				Label("Review Needed", systemImage: "exclamationmark.bubble")
					.font(.headline)
				Spacer()
				StatusBadge(title: "\(state.reviewItems.count)", tint: state.reviewItems.isEmpty ? .secondary : .orange)
			}
			if state.reviewItems.isEmpty {
				Text("No failed, blocked, or review-ready tickets.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
			else {
				ForEach(state.reviewItems) { item in
					Button {
						inspectTicket(item.ticketID)
					} label: {
						VStack(alignment: .leading, spacing: 7) {
							HStack(alignment: .top) {
								VStack(alignment: .leading, spacing: 3) {
									Text("\(item.externalID) \(item.title)")
										.font(.callout.weight(.medium))
										.lineLimit(2)
									Text(item.reason)
										.font(.caption)
										.foregroundStyle(.secondary)
										.lineLimit(2)
								}
								Spacer()
								if let status = item.status {
									StatusBadge(title: status.title, tint: status.tint)
								}
								else {
									StatusBadge(title: item.ticketStatus.title, tint: item.ticketStatus.tint)
								}
							}
							Text(item.nextAction)
								.font(.caption.weight(.medium))
								.foregroundStyle(.secondary)
						}
						.padding(10)
						.background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
					}
					.buttonStyle(.plain)
				}
				Button {
					openRuns()
				} label: {
					Label("Open Runs", systemImage: "play.circle")
				}
				.buttonStyle(.bordered)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}
}

#Preview("Review") {
	ProjectDashboardReviewPanel(
		state: ProjectDashboardPreviewData.state,
		inspectTicket: { _ in },
		openRuns: {}
	)
	.padding()
	.frame(width: 520)
}
