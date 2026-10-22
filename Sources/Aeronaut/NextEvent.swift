import Foundation

/// The next timed event that hasn't started yet.
struct NextEvent: Equatable, Sendable {
	var start: Date
	var title: String
}

/// Border colour of the calendar pill, by urgency.
enum CalendarTint: Equatable, Sendable {
	case blue, yellow, red
}

/// What the calendar pill shows. Pure and deterministic given `(event, now)`.
struct CalendarState: Equatable, Sendable {
	static let maxTitleLength = 28

	/// The event this state describes. Its identity (start and title) is what
	/// the pill peeks on, unlike the text, which ticks every minute.
	var event: NextEvent?
	/// "in 7h"; nil when there are no events.
	var timeText: String?
	/// The truncated title, or "No events".
	var detail: String
	var tint: CalendarTint
	/// Five minutes away or less, the yellow and red states.
	var isUrgent: Bool

	/// "<when> • <title>", or just "No events".
	var label: String {
		timeText.map { "\($0) • \(detail)" } ?? detail
	}

	init(event: NextEvent?, now: Date, calendar: Calendar = .current) {
		self.event = event
		guard let event else {
			timeText = nil
			detail = "No events"
			tint = .blue
			isUrgent = false
			return
		}
		let minutes = Self.minutesUntil(event.start, now: now, calendar: calendar)
		timeText = Self.when(event.start, minutes: minutes, calendar: calendar)
		detail = Self.truncate(event.title)
		tint = switch minutes {
		case ...1: .red
		case ...5: .yellow
		default: .blue
		}
		isUrgent = minutes <= 5
	}

	/// Whole minutes until `start`, rounded down. `now` is first cut back to
	/// the start of its minute so a tick just after :00 still reads "in 5m"
	/// for an event on the minute, not "in 4m".
	static func minutesUntil(_ start: Date, now: Date, calendar: Calendar = .current) -> Int {
		let minute = calendar.dateInterval(of: .minute, for: now)?.start ?? now
		return Int((start.timeIntervalSince(minute) / 60).rounded(.down))
	}

	static func when(_ start: Date, minutes: Int, calendar: Calendar = .current) -> String {
		switch minutes {
		case ..<1: return "in <1m"
		case ..<60: return "in \(minutes)m"
		case ..<(24 * 60): return "in \(minutes / 60)h"
		default:
			// "EEE HH:mm", independent of the 12/24 hour setting.
			let formatter = DateFormatter()
			formatter.calendar = calendar
			formatter.locale = Locale(identifier: "en_US_POSIX")
			formatter.timeZone = calendar.timeZone
			formatter.dateFormat = "EEE HH:mm"
			return formatter.string(from: start)
		}
	}

	/// Cuts the title to 28 characters plus "…", counting graphemes so an
	/// emoji is never split.
	static func truncate(_ title: String) -> String {
		title.count > maxTitleLength ? String(title.prefix(maxTitleLength)) + "…" : title
	}
}
