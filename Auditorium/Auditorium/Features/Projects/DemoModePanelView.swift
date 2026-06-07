import SwiftUI

struct DemoModePanelView: View {
	let state: DemoModeState
	let resetDemoProject: () -> Void

	var body: some View {
		HStack(alignment: .center, spacing: 12) {
			Label(state.title, systemImage: state.isNetworkFree ? "bolt.slash" : "exclamationmark.triangle")
				.font(.headline)
			Text(state.detail)
				.foregroundStyle(.secondary)
				.lineLimit(2)
			Spacer()
			StatusBadge(title: state.isNetworkFree ? "Offline" : "Review", tint: state.isNetworkFree ? .green : .yellow)
			Button {
				resetDemoProject()
			} label: {
				Label("Reset", systemImage: "arrow.clockwise")
			}
		}
		.padding()
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}
}
