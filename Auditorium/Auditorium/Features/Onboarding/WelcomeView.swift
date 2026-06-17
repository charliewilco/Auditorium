import SwiftUI

struct WelcomeView: View {
	let rows: [WelcomeProjectSummary]
	let version: String
	let createProject: () -> Void
	let checkPrerequisites: () -> Void
	let seeAllProjects: () -> Void
	let selectProject: (UUID) -> Void
	let close: () -> Void
	var configureWindow = true

	var body: some View {
		GeometryReader { proxy in
			let brandWidth = min(max(proxy.size.width * 0.62, 580), 760)
			HStack(spacing: 0) {
				WelcomeBrandPane(
					version: version,
					createProject: createProject,
					checkPrerequisites: checkPrerequisites,
					seeAllProjects: seeAllProjects
				)
				.frame(width: brandWidth)
				WelcomeRecentsPane(rows: rows, selectProject: selectProject)
			}
			.frame(width: proxy.size.width, height: proxy.size.height)
		}
		.frame(minWidth: 980, idealWidth: 1120, maxWidth: .infinity, minHeight: 600, idealHeight: 690, maxHeight: .infinity)
		.background(Color(red: 0.12, green: 0.12, blue: 0.13))
		.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 28, style: .continuous)
				.stroke(.white.opacity(0.16), lineWidth: 1)
		}
		.background {
			if configureWindow {
				WelcomeWindowConfigurator(cornerRadius: 28)
			}
		}
		.overlay(alignment: .top) {
			Color.clear
				.frame(height: 44)
				.contentShape(Rectangle())
				.gesture(WindowDragGesture())
				.allowsWindowActivationEvents(true)
		}
		.overlay(alignment: .topLeading) {
			WelcomeCloseButton(action: close)
				.padding(.top, 24)
				.padding(.leading, 24)
		}
	}
}

#Preview("Welcome") {
	WelcomeView(
		rows: WelcomeProjectSummary.previewRows,
		version: "v1.0",
		createProject: {},
		checkPrerequisites: {},
		seeAllProjects: {},
		selectProject: { _ in },
		close: {}
	)
	.frame(width: 1120, height: 690)
	.padding()
	.background(.black)
}
