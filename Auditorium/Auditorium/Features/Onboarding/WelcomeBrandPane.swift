import SwiftUI

struct WelcomeBrandPane: View {
	let version: String
	let createProject: () -> Void
	let checkPrerequisites: () -> Void
	let seeAllProjects: () -> Void

	var body: some View {
		ZStack {
			Image("WelcomeBackground")
				.resizable()
				.scaledToFill()
			VStack(spacing: 18) {
				Spacer()
				Image("WelcomeMark")
					.resizable()
					.scaledToFit()
					.frame(width: 142, height: 142)
					.shadow(color: .black.opacity(0.28), radius: 18, y: 12)
				VStack(spacing: 4) {
					Text("AUDITORIUM")
						.font(.system(size: 48, weight: .semibold, design: .default))
						.fontWidth(.expanded)
						.foregroundStyle(.white.opacity(0.92))
					Text(displayVersion)
						.font(.system(size: 22, weight: .medium))
						.foregroundStyle(.white.opacity(0.54))
				}
				Spacer()
					.frame(height: 40)
				VStack(spacing: 12) {
					WelcomeActionButton(title: "Create New Project...", symbol: "plus.square", action: createProject)
					WelcomeActionButton(title: "Check Prerequisites...", symbol: "checklist", action: checkPrerequisites)
					WelcomeActionButton(title: "See All Projects...", symbol: "square.grid.2x2", action: seeAllProjects)
				}
				.frame(width: 520)
				Spacer()
			}
			.padding(.bottom, 58)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.clipped()
	}

	private var displayVersion: String {
		if version.hasPrefix("v") {
			return "Version \(version.dropFirst())"
		}
		return "Version \(version)"
	}
}

#Preview("Brand Pane") {
	WelcomeBrandPane(version: "v1.0", createProject: {}, checkPrerequisites: {}, seeAllProjects: {})
		.frame(width: 680, height: 690)
}
