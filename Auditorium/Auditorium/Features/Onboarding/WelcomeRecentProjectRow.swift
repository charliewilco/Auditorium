import SwiftUI

struct WelcomeRecentProjectRow: View {
	let row: WelcomeProjectSummary
	let selectProject: (UUID) -> Void
	@State private var isHovered = false

	var body: some View {
		Button {
			selectProject(row.id)
		} label: {
			HStack(spacing: 12) {
				Image(systemName: "doc.text.fill")
					.font(.system(size: 39, weight: .regular))
					.foregroundStyle(.white.opacity(0.88))
					.frame(width: 42, height: 46)
				VStack(alignment: .leading, spacing: 2) {
					Text(row.name)
						.font(.system(size: 19, weight: .bold))
						.foregroundStyle(.white.opacity(0.88))
						.lineLimit(1)
					Text(row.subtitle)
						.font(.system(size: 15, weight: .semibold))
						.foregroundStyle(.white.opacity(0.48))
						.lineLimit(1)
				}
				Spacer(minLength: 12)
				HStack(spacing: 10) {
					Image(systemName: row.issueSymbol)
					Image(systemName: row.repositorySymbol)
				}
				.font(.system(size: 15, weight: .bold))
				.foregroundStyle(.white.opacity(0.86))
				Text("\(row.pullRequestCount)")
					.font(.system(size: 15, weight: .heavy))
					.foregroundStyle(Color(red: 0.05, green: 0.59, blue: 1))
					.frame(width: 40, height: 40)
					.background(Color(red: 0.02, green: 0.22, blue: 0.39), in: Circle())
			}
			.padding(.vertical, 7)
			.padding(.horizontal, 8)
			.contentShape(RoundedRectangle(cornerRadius: 8))
		}
		.buttonStyle(.plain)
		.background(Color.white.opacity(isHovered ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 8))
		.onHover { isHovered = $0 }
	}
}

#Preview("Row") {
	WelcomeRecentProjectRow(row: WelcomeProjectSummary.previewRows[0], selectProject: { _ in })
		.frame(width: 460)
		.padding()
		.background(Color(red: 0.1, green: 0.1, blue: 0.11))
}
