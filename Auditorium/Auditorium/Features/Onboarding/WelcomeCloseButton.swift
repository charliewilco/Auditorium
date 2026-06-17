import SwiftUI

struct WelcomeCloseButton: View {
	let action: () -> Void
	@State private var isHovered = false

	var body: some View {
		Button(action: action) {
			Image(systemName: "xmark.circle.fill")
				.symbolRenderingMode(.monochrome)
				.font(.system(size: 27, weight: .semibold))
				.foregroundStyle(.black.opacity(isHovered ? 0.56 : 0.42))
				.frame(width: 30, height: 30)
				.contentShape(Circle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Close Welcome")
		.help("Close")
		.onHover { isHovered = $0 }
	}
}

#Preview("Close Button") {
	WelcomeCloseButton(action: {})
		.padding()
		.background(Color(red: 0.14, green: 0.14, blue: 0.15))
}
