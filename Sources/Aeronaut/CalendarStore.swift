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

	func start() {
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
		let next = Self.nextEvent(in: store, after: date)
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
