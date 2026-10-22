import AppKit
import SwiftUI

/// Reports whether the cursor is over the view behind it. SwiftUI's `onHover`
/// may not fire in a non-activating panel of an app that's never active, so
/// this uses an `NSTrackingArea` that works regardless of activation.
struct HoverTracker: NSViewRepresentable {
	var onChange: (Bool) -> Void

	func makeNSView(context: Context) -> TrackerView {
		let view = TrackerView()
		view.onChange = onChange
		return view
	}

	func updateNSView(_ view: TrackerView, context: Context) {
		view.onChange = onChange
	}

	final class TrackerView: NSView {
		var onChange: (Bool) -> Void = { _ in }
		private var isInside = false
		private var timer: Timer?

		override func updateTrackingAreas() {
			super.updateTrackingAreas()
			for area in trackingAreas { removeTrackingArea(area) }
			addTrackingArea(NSTrackingArea(
				rect: .zero,
				options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
				owner: self,
				userInfo: nil
			))
		}

		override func mouseEntered(with event: NSEvent) {
			set(inside: true)
		}

		override func mouseExited(with event: NSEvent) {
			set(inside: false)
		}

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window == nil { set(inside: false) }
		}

		// Never claim clicks: the button on top of this takes them.
		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		private func set(inside: Bool) {
			guard inside != isInside else { return }
			isInside = inside
			timer?.invalidate()
			timer = nil
			if inside {
				// An exit can be missed (the panel ignores mouse events while the
				// menu bar shows, and the cursor can leave fast), so check too.
				timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
					MainActor.assumeIsolated { self?.verifyInside() }
				}
			}
			onChange(inside)
		}

		private func verifyInside() {
			guard let window else { return set(inside: false) }
			let frame = window.convertToScreen(convert(bounds, to: nil))
			if !frame.contains(NSEvent.mouseLocation) { set(inside: false) }
		}
	}
}

/// An object rather than `@State`: the Command Line Tools have no SwiftUI
/// macro plugin.
@MainActor
private final class HoverModel: ObservableObject {
	@Published var isHovering = false
}

/// Gives its content a hover flag from a `HoverTracker`. `forced` pins it on,
/// for snapshots.
struct Hoverable<Content: View>: View {
	var forced = false
	@ViewBuilder var content: (Bool) -> Content

	@StateObject private var model = HoverModel()

	var body: some View {
		content(model.isHovering || forced)
			.background(HoverTracker { model.isHovering = $0 })
	}
}
