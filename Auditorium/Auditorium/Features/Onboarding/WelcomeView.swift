import SwiftUI

struct WelcomeView: View {
	let createProject: () -> Void
	let openDemo: () -> Void

	var body: some View {
		VStack(spacing: 28) {
			Image(systemName: "music.quarternote.3")
				.font(.system(size: 64, weight: .semibold))
				.foregroundStyle(Color.accentColor)
			VStack(spacing: 10) {
				Text("Auditorium")
					.font(.system(size: 48, weight: .bold))
				Text("Queue the work. Hit play. Review the pull requests.")
					.font(.title3)
					.foregroundStyle(.secondary)
				Text("Auditorium turns repositories and issue trackers into a visual control plane for coding agents.")
					.font(.body)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.frame(maxWidth: 560)
			}
			HStack(spacing: 12) {
				Button(action: createProject) {
					Label("Create Project", systemImage: "plus")
				}
				.buttonStyle(.borderedProminent)
				Button(action: openDemo) {
					Label("Open Demo Project", systemImage: "play.circle")
				}
				.buttonStyle(.bordered)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding()
	}
}
