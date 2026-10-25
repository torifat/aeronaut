import AppKit
import EventKit
import Observation

@MainActor
@Observable
final class CalendarStore {
	private(set) var event: NextEvent?
	private(set) var now = Date()

	var state: CalendarState {
		CalendarState(event: event, now: now)
	}

	@ObservationIgnored private let store = EKEventStore()
	@ObservationIgnored private var observers: [any NSObjectProtocol] = []
	/// Set by `AERONAUT_DEMO_CALENDAR`; EventKit is then never touched.
	@ObservationIgnored private let demo = DemoCalendar.fromEnvironment()

	func start() {
		if demo != nil {
			// Scripted events switch at arbitrary moments, so poll faster than
			// the minute. `CalendarState` still flips colours on real minutes.
			Task {
				while !Task.isCancelled {
					refresh()
					try? await Task.sleep(for: .milliseconds(250))
				}
			}
			return
		}
		observe(NotificationCenter.default, name: .EKEventStoreChanged)
		observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification)
		Task {
			_ = try? await store.requestFullAccessToEvents()
			refresh()
		}
		// Tick on the minute boundary so colours and "in 5m" never lag.
		Task {
			while !Task.isCancelled {
				refresh()
				let seconds = Date.now.timeIntervalSinceReferenceDate
				// A moment past :00 so the clock has certainly rolled over.
				try? await Task.sleep(for: .seconds(60 - seconds.truncatingRemainder(dividingBy: 60) + 0.1))
			}
		}
	}

	func openCalendar() {
		guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
		NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
	}

	private func observe(_ center: NotificationCenter, name: Notification.Name) {
		observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.refresh() }
		})
	}

	private func refresh() {
		let date = Date()
		let next = if let demo { demo.event(at: date) } else { Self.nextEvent(in: store, after: date) }
		if next != event { event = next }
		now = date
	}

	/// Nothing is returned without full calendar access.
	static func nextEvent(in store: EKEventStore, after now: Date) -> NextEvent? {
		guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
		let end = now.addingTimeInterval(30 * 24 * 3600)
		let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
		return store.events(matching: predicate)
			.filter { !$0.isAllDay && $0.startDate > now && $0.status != .canceled }
			.filter { event in
				!(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
			}
			.min { $0.startDate < $1.startDate }
			.map { NextEvent(start: $0.startDate, title: $0.title ?? "") }
	}
}

/// Scripted calendar for README captures, read once from the JSON file that
/// `AERONAUT_DEMO_CALENDAR` names (unix seconds):
/// `[{"from": 1761450000, "start": 1761460800, "title": "Design review"}]`.
/// From `from` on, the entry is the next event until a later entry's `from`.
private struct DemoCalendar {
	private struct Entry: Decodable {
		let from: TimeInterval
		let start: TimeInterval
		let title: String
	}

	private let entries: [Entry]

	/// Nil when the variable is unset. A file that can't be read or parsed
	/// gives a calendar with no events, after a note on stderr.
	static func fromEnvironment() -> DemoCalendar? {
		guard let path = ProcessInfo.processInfo.environment["AERONAUT_DEMO_CALENDAR"] else { return nil }
		do {
			let data = try Data(contentsOf: URL(fileURLWithPath: path))
			return DemoCalendar(entries: try JSONDecoder().decode([Entry].self, from: data))
		} catch {
			FileHandle.standardError.write(Data("aeronaut: AERONAUT_DEMO_CALENDAR: \(error.localizedDescription)\n".utf8))
			return DemoCalendar(entries: [])
		}
	}

	func event(at now: Date) -> NextEvent? {
		let seconds = now.timeIntervalSince1970
		guard let entry = entries.last(where: { $0.from <= seconds }), entry.start > seconds else { return nil }
		return NextEvent(start: Date(timeIntervalSince1970: entry.start), title: entry.title)
	}
}
