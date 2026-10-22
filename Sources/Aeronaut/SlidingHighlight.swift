import AppKit
import SwiftUI

/// The springy slide. The live bar and the snapshot both evaluate the same
/// analytic spring, so a frozen frame matches a live one.
struct SlideMotion: Sendable {
	var spring = Theme.focusSpring

	static let slide = SlideMotion()

	/// Reduce Motion: a plain ease with no overshoot.
	static let reduced = SlideMotion(spring: Spring(duration: 0.25, bounce: 0))

	static var current: SlideMotion {
		NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .reduced : .slide
	}

	var duration: TimeInterval { spring.settlingDuration }

	/// How far along the move is `time` seconds in. It passes 1 while the spring overshoots.
	func progress(at time: TimeInterval) -> CGFloat {
		CGFloat(spring.value(target: 1.0, initialVelocity: 0, time: max(0, time)))
	}

	/// The start rect moved rigidly toward the live target. Progress past 1
	/// extrapolates beyond it. At progress 1 this is exactly `target`.
	static func rect(start: CGRect, target: CGRect, progress: CGFloat) -> CGRect {
		func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
			from + (to - from) * progress
		}
		return CGRect(
			x: mix(start.minX, target.minX),
			y: mix(start.minY, target.minY),
			width: mix(start.width, target.width),
			height: mix(start.height, target.height)
		)
	}
}

/// Snapshot-only: draws the slide frozen `time` seconds into a move between two workspaces.
struct SlideFreeze {
	let from: String
	let to: String
	let time: TimeInterval
}

/// The highlight's frame for each workspace, reported by both styles in the
/// pill's coordinate space.
struct ItemBounds: PreferenceKey {
	static let defaultValue: [String: Anchor<CGRect>] = [:]

	static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
		value.merge(nextValue()) { $1 }
	}
}

/// Frame times at 120 Hz from `begin` until `end`, and nothing after, so the view stops redrawing once the slide has settled.
private struct SlideSchedule: TimelineSchedule {
	let begin: Date
	let end: Date

	func entries(from start: Date, mode: Mode) -> Entries {
		Entries(upcoming: start, first: Swift.max(start, begin), end: end)
	}

	struct Entries: Sequence, IteratorProtocol, Sendable {
		typealias Element = Date

		var upcoming: Date?
		var first: Date
		let end: Date

		mutating func next() -> Date? {
			guard let current = upcoming else { return nil }
			let following = Swift.max(current, first).addingTimeInterval(1.0 / 120)
			upcoming = following <= end ? following : nil
			return current
		}
	}
}

/// Remembers where the highlight was when focus moved and when the move began.
/// Nothing here is published: the view reads it while rendering and the
/// schedule drives the redraws. Only ever touched from view bodies, which run
/// on the main actor.
private final class SlideState: ObservableObject, @unchecked Sendable {
	private var focus: String?
	private var start: CGRect?
	private(set) var began = Date.distantPast
	private var last: CGRect?

	/// Starts a move from the rect on screen when `id` is new.
	func note(focus id: String, now: Date) {
		guard id != focus else { return }
		start = last
		focus = id
		began = now
	}

	/// The rect to draw at `now`: the start rect eased toward the live
	/// `target`, or the target itself when idle or with nothing to move from.
	func rect(target: CGRect, motion: SlideMotion, now: Date) -> CGRect {
		let elapsed = now.timeIntervalSince(began)
		let rect: CGRect
		if let start, elapsed < motion.duration {
			rect = SlideMotion.rect(start: start, target: target, progress: motion.progress(at: elapsed))
		} else {
			rect = target
		}
		last = rect
		return rect
	}
}

/// The focus marker behind the workspace items, positioned from their anchors.
struct SlidingHighlight: View {
	let bounds: [String: Anchor<CGRect>]
	let focused: String?
	let style: FocusStyle
	var freeze: SlideFreeze?

	@StateObject private var state = SlideState()

	var body: some View {
		GeometryReader { proxy in
			if let focused, let anchor = bounds[focused] {
				let target = proxy[anchor]
				if let freeze, let from = bounds[freeze.from] {
					let progress = SlideMotion.slide.progress(at: freeze.time)
					frame(style: style, rect: SlideMotion.rect(start: proxy[from], target: target, progress: progress))
				} else {
					animated(focused: focused, target: target)
				}
			}
		}
		.allowsHitTesting(false)
	}

	private func animated(focused: String, target: CGRect) -> some View {
		let state = state, style = style, motion = SlideMotion.current
		let now = Date()
		state.note(focus: focused, now: now)
		let schedule = SlideSchedule(begin: state.began, end: state.began.addingTimeInterval(motion.duration + 0.05))
		return TimelineView(schedule) { context in
			frame(style: style, rect: state.rect(target: target, motion: motion, now: context.date))
		}
	}

	private func frame(style: FocusStyle, rect: CGRect) -> some View {
		// Positioned by offset so the frame can be any size.
		FocusHighlight(style: style)
			.frame(width: rect.width, height: rect.height)
			.offset(x: rect.minX, y: rect.minY)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}
}
