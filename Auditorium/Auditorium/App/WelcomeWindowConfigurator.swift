import AppKit
import SwiftUI

struct WelcomeWindowConfigurator: NSViewRepresentable {
	let cornerRadius: CGFloat

	func makeNSView(context _: Context) -> NSView {
		let view = NSView(frame: .zero)
		view.wantsLayer = true
		DispatchQueue.main.async {
			configure(window: view.window)
		}
		return view
	}

	func updateNSView(_ view: NSView, context _: Context) {
		DispatchQueue.main.async {
			configure(window: view.window)
		}
	}

	private func configure(window: NSWindow?) {
		guard let window else { return }
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = true
		window.titleVisibility = .hidden
		window.titlebarAppearsTransparent = true
		window.standardWindowButton(.closeButton)?.isHidden = true
		window.standardWindowButton(.miniaturizeButton)?.isHidden = true
		window.standardWindowButton(.zoomButton)?.isHidden = true
		window.contentView?.wantsLayer = true
		window.contentView?.layer?.cornerRadius = cornerRadius
		window.contentView?.layer?.masksToBounds = true
	}
}
