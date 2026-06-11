import SwiftUI

struct WelcomeActionButton: View {
	let title: String
	let symbol: String
	let action: () -> Void
	@State private var isHovered = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 12) {
				Image(systemName: symbol)
					.font(.system(size: 24, weight: .medium))
					.foregroundStyle(.white.opacity(0.64))
					.frame(width: 34)
				Text(title)
					.font(.system(size: 19, weight: .bold))
					.lineLimit(1)
				Spacer(minLength: 0)
			}
			.padding(.leading, 18)
			.padding(.trailing, 20)
			.frame(width: 520, height: 50)
			.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.foregroundStyle(.white.opacity(0.82))
		.background(Color.black.opacity(isHovered ? 0.24 : 0.16), in: Capsule())
		.onHover { isHovered = $0 }
	}
}

#Preview("Action") {
	WelcomeActionButton(title: "Create New Project...", symbol: "plus.square", action: {})
		.padding()
		.background(.pink)
}
