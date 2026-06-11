import SwiftUI

struct WelcomeEmptyRecents: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Image(systemName: "tray")
				.font(.system(size: 36, weight: .semibold))
				.foregroundStyle(.white.opacity(0.45))
			Text("No recent runs yet")
				.font(.system(size: 22, weight: .heavy))
				.foregroundStyle(.white)
			Text("Create a project, run a queue, and Auditorium will surface recent PR activity here.")
				.font(.callout)
				.foregroundStyle(.white.opacity(0.48))
				.fixedSize(horizontal: false, vertical: true)
		}
		.frame(maxWidth: 360, alignment: .leading)
		.padding(.top, 16)
	}
}

#Preview("Empty Recents") {
	WelcomeEmptyRecents()
		.padding()
		.background(Color(red: 0.1, green: 0.1, blue: 0.11))
}
