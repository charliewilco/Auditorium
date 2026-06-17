import SwiftUI

struct WelcomeRecentsPane: View {
	let rows: [WelcomeProjectSummary]
	let selectProject: (UUID) -> Void

	var body: some View {
		ZStack(alignment: .topLeading) {
			Color(red: 0.18, green: 0.17, blue: 0.18)
			VStack(alignment: .leading, spacing: 22) {
				Text("RECENTS")
					.font(.system(size: 15, weight: .medium))
					.foregroundStyle(.white.opacity(0.44))
					.tracking(1.4)
					.padding(.top, 42)
				if rows.isEmpty {
					WelcomeEmptyRecents()
				}
				else {
					VStack(spacing: 17) {
						ForEach(rows) { row in
							WelcomeRecentProjectRow(row: row, selectProject: selectProject)
						}
					}
				}
				Spacer()
			}
			.padding(.leading, 32)
			.padding(.trailing, 20)
		}
		.frame(minWidth: 360, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}
}

#Preview("Recents") {
	WelcomeRecentsPane(rows: WelcomeProjectSummary.previewRows, selectProject: { _ in })
		.frame(width: 553, height: 796)
}
