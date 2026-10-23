import AppKit
import SwiftUI

/// The outline of a 30 pt-tall pill, as a path that starts at the top centre
/// and runs clockwise, so `trim(from: 1 - fraction, to: 1)` drains like a
/// clock hand sweeping clockwise from twelve. `inset`
/// matches `strokeBorder`: pass half the line width to sit on the track.
struct PillOutline: Shape {
	var inset: CGFloat = 0

	func path(in rect: CGRect) -> Path {
		let r = rect.insetBy(dx: inset, dy: inset)
		let radius = r.height / 2
		var path = Path()
		path.move(to: CGPoint(x: r.midX, y: r.minY))
		path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
		path.addArc(
			center: CGPoint(x: r.maxX - radius, y: r.midY),
			radius: radius,
			startAngle: .degrees(-90),
			endAngle: .degrees(90),
			clockwise: false
		)
		path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
		path.addArc(
			center: CGPoint(x: r.minX + radius, y: r.midY),
			radius: radius,
			startAngle: .degrees(90),
			endAngle: .degrees(270),
			clockwise: false
		)
		path.addLine(to: CGPoint(x: r.midX, y: r.minY))
		return path
	}
}

extension CalendarTint {
	var color: Color {
		switch self {
		case .blue: Theme.blue
		case .yellow: Theme.yellow
		case .red: Theme.red
		}
	}
}

/// One tick a second on `anchor`'s second boundaries, or a single entry when
/// there's no anchor, so a pill that isn't urgent costs nothing.
struct CountdownSchedule: TimelineSchedule {
	var anchor: Date?

	func entries(from start: Date, mode: Mode) -> AnyIterator<Date> {
		guard let anchor else { return AnyIterator([start].makeIterator()) }
		var next = anchor.addingTimeInterval(start.timeIntervalSince(anchor).rounded(.up))
		if next <= start { next = next.addingTimeInterval(1) }
		var first = true
		return AnyIterator {
			if first {
				first = false
				return start
			}
			defer { next = next.addingTimeInterval(1) }
			return next
		}
	}
}

/// How the calendar pill is drawn.
enum CalendarStyle: String, CaseIterable, Sendable {
	/// The workspace pill's layout: a grey glyph, and the time in a capsule inset
	/// in the pill. The capsule is a light fill at rest and the state colour when
	/// yellow or red; the title is plain text.
	case capsule
	/// The earlier look: the glyph and the accent border take the state colour, and
	/// the time and " • <title>" are plain text.
	case plain
}

/// The pill's look for a given state, with no behaviour of its own: a calendar
/// glyph and the time, plus the title when expanded. `ringFraction` draws a
/// coloured ring covering that fraction of the outline, clockwise from the top
/// centre, over a neutral track that replaces `border` while it shows.
struct NextEventContent: View {
	let state: CalendarState
	let isExpanded: Bool
	var ringFraction: Double?
	/// Pill backing; see `PillMaterial`.
	var material = PillMaterial.flat // snapshots stay flat
	var border = Settings.shared.border
	var style = Settings.shared.values.calendarStyle

	/// With nothing to the right of it, the icon gets the pill's usual end padding.
	private var iconOnly: Bool {
		state.timeText == nil && !isExpanded
	}

	/// Blue is the pill at rest, which `capsule` leaves neutral.
	private var isAtRest: Bool {
		state.tint == .blue
	}

	/// The time capsule's fill.
	private var capsuleFill: Color {
		isAtRest ? Color.white.opacity(Theme.restCapsuleOpacity) : state.tint.color.opacity(FocusStyle.translucentOpacity)
	}

	var body: some View {
		switch style {
		case .plain: outlined(plainContent, accent: state.tint.color)
		case .capsule: outlined(capsuleContent, accent: isAtRest ? Theme.border : state.tint.color)
		}
	}

	/// The pill's shape, material, border and countdown ring around `content`.
	/// The ring runs on the outline and replaces `border` while it shows.
	private func outlined<Content: View>(_ content: Content, accent: Color) -> some View {
		let shape = RoundedRectangle(cornerRadius: 16)
		return content
			.frame(height: Theme.pillHeight)
			.clipShape(shape)
			.pillBackground(shape, material: material, border: ringFraction == nil ? border : material.isFlat ? .neutral : .none, accent: accent)
			.overlay {
				if !material.isFlat, ringFraction != nil {
					PillOutline(inset: 0.5).stroke(Theme.glassTrack, lineWidth: 1)
				}
			}
			.overlay {
				if let fraction = ringFraction, fraction > 0 {
					PillOutline(inset: 0.5)
						.trim(from: 1 - fraction, to: 1)
						.stroke(state.tint.color, style: StrokeStyle(lineWidth: 1, lineCap: .round))
						.animation(.linear(duration: 1), value: fraction)
				}
			}
			.contentShape(shape)
	}

	private var plainContent: some View {
		HStack(spacing: 0) {
			Text("\u{F00F6}")
				.font(Theme.symbol)
				.foregroundStyle(state.tint.color)
				.tracking(Theme.symbolOverhang)
				.padding(.leading, 12)
				.padding(.trailing, iconOnly ? 12 : 4)
			if !iconOnly {
				HStack(spacing: 0) {
					if let timeText = state.timeText {
						Text(timeText)
							.foregroundStyle(Theme.text)
							.contentTransition(.numericText())
					}
					if isExpanded {
						HStack(spacing: 0) {
							if state.timeText != nil {
								Text(" • ").foregroundStyle(Theme.grey)
							}
							Text(state.detail).foregroundStyle(Theme.text)
						}
						.transition(.move(edge: .trailing).combined(with: .opacity))
					}
				}
				.font(Theme.label)
				.fixedSize()
				.padding(.leading, 4)
				.padding(.trailing, 12)
			}
		}
	}

	private var capsuleContent: some View {
		HStack(spacing: 0) {
			Text("\u{F00F6}")
				.font(Theme.symbol)
				.foregroundStyle(Theme.grey)
				.tracking(Theme.symbolOverhang)
				.padding(.leading, 12)
				.padding(.trailing, iconOnly ? 12 : 6)
			if let timeText = state.timeText {
				Text(timeText)
					.font(Theme.label)
					.foregroundStyle(isAtRest ? Theme.text : Theme.onAccent)
					.contentTransition(.numericText())
					.fixedSize()
					.padding(.horizontal, 8)
					.frame(height: Theme.focusHeight)
					.background(Capsule().fill(capsuleFill))
					// Collapsed, the capsule's end sits `focusMargin` from the pill's edge.
					.padding(.trailing, isExpanded ? 0 : Theme.focusMargin)
			}
			if isExpanded {
				Text(state.detail)
					.font(Theme.label)
					.foregroundStyle(state.timeText == nil ? Theme.grey : Theme.text)
					.fixedSize()
					.padding(.leading, state.timeText == nil ? 0 : 6)
					.padding(.trailing, 12)
					.transition(.move(edge: .trailing).combined(with: .opacity))
			}
		}
	}
}

/// The next calendar event, collapsed to its time unless something asks for
/// the full label: the cursor (and a second after), an event five minutes away
/// or less, or a short peek whenever the next event changes.
struct NextEventPill: View {
	static let lingerDuration: Duration = .seconds(1)
	static let peekDuration: Duration = .seconds(4)

	let state: CalendarState
	var material = PillMaterial.flat // snapshots stay flat
	var border = Settings.shared.border
	var style = Settings.shared.values.calendarStyle
	var onSelect: @MainActor () -> Void = {}

	/// Why the pill is open besides urgency. An object rather than `@State`
	/// properties: the Command Line Tools have no SwiftUI macro plugin.
	@MainActor
	private final class Triggers: ObservableObject {
		@Published var isHovering = false
		@Published var isLingering = false
		@Published var isPeeking = false
		/// Set for the beat of the one-off pulse when the pill turns red.
		@Published var isPulsing = false
	}

	@StateObject private var triggers = Triggers()

	private var isExpanded: Bool {
		triggers.isHovering || triggers.isLingering || triggers.isPeeking || state.isUrgent
	}

	/// Ticks only while urgent.
	private var schedule: CountdownSchedule {
		CountdownSchedule(anchor: state.isUrgent ? state.event?.start : nil)
	}

	/// The share of the last five minutes left once this tick's second has run.
	/// The trim animates over that second, so it lands on the value as the next
	/// tick starts.
	private func ringFraction(at date: Date) -> Double? {
		guard state.isUrgent, let event = state.event else { return nil }
		return min(max((event.start.timeIntervalSince(date) - 1) / 300, 0), 1)
	}

	var body: some View {
		Button(action: onSelect) {
			TimelineView(schedule) { context in
				NextEventContent(state: state, isExpanded: isExpanded, ringFraction: ringFraction(at: context.date), material: material, border: border, style: style)
			}
			.scaleEffect(triggers.isPulsing ? 1.05 : 1)
		}
		.buttonStyle(PressStyle())
		.focusable(false)
		.background(HoverTracker { triggers.isHovering = $0 })
			.animation(Theme.animation, value: isExpanded)
			.animation(Theme.animation, value: state)
			// Keyed on the event itself, so "in 5m" -> "in 4m" doesn't peek. Also
			// runs on first appearance, which covers the first load after launch.
			// No peek for "No events", which is all there is before the first load.
			.task(id: state.event) {
				triggers.isPeeking = state.event != nil
				guard triggers.isPeeking else { return }
				do { try await Task.sleep(for: Self.peekDuration) } catch { return }
				triggers.isPeeking = false
			}
			// One gentle pulse as the ring turns red; never repeats.
			.task(id: state.tint) {
				guard state.tint == .red, state.isUrgent else { return }
				withAnimation(.easeOut(duration: 0.25)) { triggers.isPulsing = true }
				do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
				withAnimation(.easeInOut(duration: 0.35)) { triggers.isPulsing = false }
			}
			// Hovering again cancels a pending linger, since the id changes.
			.task(id: triggers.isHovering) {
				if triggers.isHovering {
					triggers.isLingering = true
				} else if triggers.isLingering {
					do { try await Task.sleep(for: Self.lingerDuration) } catch { return }
					triggers.isLingering = false
				}
			}
	}
}
