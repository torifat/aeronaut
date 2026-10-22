import AppKit
import SwiftUI

/// A transparent, borderless panel that floats above normal windows on every
/// Space and never takes focus. Clicks on its transparent areas fall through.
final class PillPanel: NSPanel {
	init<Content: View>(rootView: Content) {
		super.init(
			contentRect: .zero,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		// Just under the menu bar, so an auto-hidden menu bar slides over it.
		level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
		collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		hidesOnDeactivate = false
		isMovable = false

		let host = FirstMouseHostingView(rootView: rootView)
		host.sizingOptions = []
		contentView = host

		MenuBarWatcher.shared.register(self)
	}

	/// Fades out while the menu bar shows over this panel, and stops catching clicks.
	func setMenuBarShowing(_ showing: Bool) {
		ignoresMouseEvents = showing
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.2
			animator().alphaValue = showing ? 0 : 1
		}
	}

	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }

	/// AppKit would push the panel below the menu bar (and notch). It belongs
	/// in that row, so keep the requested frame as is.
	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
		frameRect
	}
}

/// Lets the first click act immediately even though the panel is never key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
