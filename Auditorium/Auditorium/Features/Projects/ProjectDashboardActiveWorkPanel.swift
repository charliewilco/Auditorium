import SwiftUI

struct ProjectDashboardActiveWorkPanel: View {
	let state: ProjectDashboardState
	let selectedTicketID: UUID?
	let inspectTicket: (UUID) -> Void
	let openRuns: () -> Void
	let openTickets: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack {
				Label(
					"Active Work",
					systemImage: state.activeRun == nil ? "text.line.first.and.arrowtriangle.forward" : "play.circle.fill"
				)
				.font(.headline)
				Spacer()
				if let activeRun = state.activeRun {
					StatusBadge(title: activeRun.status.title, tint: activeRun.status.tint)
				}
			}
			if let activeRun = state.activeRun {
				activeRunView(activeRun)
			}
			else {
				queuePreview
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private func activeRunView(_ activeRun: ProjectDashboardState.ActiveRun) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			VStack(alignment: .leading, spacing: 6) {
				HStack {
					Text(activeRun.title)
						.font(.title3.weight(.semibold))
					Spacer()
					Text(activeRun.progressText)
						.font(.caption.weight(.medium))
						.foregroundStyle(.secondary)
				}
				Text(activeRun.summary)
					.font(.callout)
					.foregroundStyle(.secondary)
				ProgressView(value: activeRun.progress)
			}
			HStack(spacing: 16) {
				ProjectDashboardValue(title: "Running", value: "\(activeRun.runningTicketCount)")
				ProjectDashboardValue(title: "Needs Review", value: "\(activeRun.reviewTicketCount)")
				Spacer()
				Button {
					openRuns()
				} label: {
					Label("Open Run", systemImage: "arrow.right")
				}
				.buttonStyle(.bordered)
			}
			if state.activeRunEvents.isEmpty == false {
				VStack(alignment: .leading, spacing: 8) {
					ForEach(state.activeRunEvents) { event in
						HStack(alignment: .top, spacing: 8) {
							Circle()
								.fill(event.level.tint)
								.frame(width: 7, height: 7)
								.padding(.top, 6)
							VStack(alignment: .leading, spacing: 2) {
								Text(event.message)
									.font(.caption)
								Text(event.category.rawValue)
									.font(.caption2)
									.foregroundStyle(.secondary)
							}
							Spacer()
							Text(event.timestamp, format: .dateTime.hour().minute())
								.font(.caption2)
								.foregroundStyle(.secondary)
						}
					}
				}
			}
		}
	}

	private var queuePreview: some View {
		VStack(alignment: .leading, spacing: 10) {
			if state.queuePreview.isEmpty {
				Text("No tickets are queued.")
					.font(.callout)
					.foregroundStyle(.secondary)
				Button {
					openTickets()
				} label: {
					Label("Find Tickets", systemImage: "ticket")
				}
				.buttonStyle(.bordered)
			}
			else {
				ForEach(state.queuePreview.prefix(5)) { item in
					Button {
						inspectTicket(item.ticketID)
					} label: {
						HStack(spacing: 10) {
							Text("\(item.position + 1)")
								.font(.caption.monospacedDigit().weight(.semibold))
								.foregroundStyle(.secondary)
								.frame(width: 22)
							VStack(alignment: .leading, spacing: 3) {
								Text("\(item.externalID) \(item.title)")
									.font(.callout.weight(.medium))
									.lineLimit(1)
								Text(
									item.isEnabled
										? "Enabled - \(item.priority.title)"
										: "Disabled - \(item.priority.title)"
								)
								.font(.caption)
								.foregroundStyle(.secondary)
							}
							Spacer()
							StatusBadge(title: item.status.title, tint: item.status.tint)
						}
						.padding(8)
						.background(
							item.ticketID == selectedTicketID
								? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05),
							in: RoundedRectangle(cornerRadius: 8)
						)
					}
					.buttonStyle(.plain)
				}
			}
		}
	}
}

#Preview("Active Work") {
	ProjectDashboardActiveWorkPanel(
		state: ProjectDashboardPreviewData.state,
		selectedTicketID: ProjectDashboardPreviewData.firstTicketID,
		inspectTicket: { _ in },
		openRuns: {},
		openTickets: {}
	)
	.padding()
	.frame(width: 620)
}
