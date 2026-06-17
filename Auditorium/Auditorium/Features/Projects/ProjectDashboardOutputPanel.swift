import SwiftUI

struct ProjectDashboardOutputPanel: View {
	let state: ProjectDashboardState
	let openReports: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack {
				Label("Recent Output", systemImage: "tray.full")
					.font(.headline)
				Spacer()
				Button {
					openReports()
				} label: {
					Label("Reports", systemImage: "doc.text")
				}
				.buttonStyle(.bordered)
			}
			if state.recentOutputs.isEmpty {
				Text("Pull requests and reports will land here after a run produces output.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
			else {
				ForEach(state.recentOutputs) { output in
					HStack(alignment: .top, spacing: 10) {
						Image(systemName: output.kind == .pullRequest ? "arrow.triangle.pull" : "doc.text")
							.foregroundStyle(output.kind == .pullRequest ? Color.indigo : Color.teal)
							.frame(width: 20)
						VStack(alignment: .leading, spacing: 3) {
							Text(output.title)
								.font(.callout.weight(.medium))
								.lineLimit(1)
							Text(output.detail)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
						Spacer()
						if let url = output.url.flatMap(URL.init(string:)) {
							Link("Open", destination: url)
						}
					}
					.padding(8)
					.background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
				}
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}
}

#Preview("Output") {
	ProjectDashboardOutputPanel(
		state: ProjectDashboardPreviewData.state,
		openReports: {}
	)
	.padding()
	.frame(width: 520)
}
