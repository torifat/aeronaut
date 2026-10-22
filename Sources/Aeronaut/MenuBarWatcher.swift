import AppKit

/// Fades every `PillPanel` out while the (auto-hiding) menu bar is showing.
///
/// The menu bar is a "Window Server" window named "Menubar" that rests just
/// above the top of its display and slides down on reveal. Nothing notifies
/// us about that, so we read its frame: quickly while the cursor is near the
/// top edge or the bar is showing, and once a second otherwise.
@MainActor
final class MenuBarWatcher {
	static let shared = MenuBarWatcher()

	private struct Entry {
		weak var panel: PillPanel?
		var windowID: CGWindowID?
		var showing = false
	}

	private static let topZone: CGFloat = 40
	private static let fastInterval: TimeInterval = 1.0 / 30
	private static let slowInterval: TimeInterval = 1
	private static let linger: TimeInterval = 1

	private var entries: [Entry] = []
	private var topZones: [NSRect] = []
	private var fastTimer: Timer?
	private var slowTimer: Timer?
	private var lastActive = Date.distantPast
	private var started = false

	func register(_ panel: PillPanel) {
		entries.removeAll { $0.panel == nil }
		entries.append(Entry(panel: panel))
		start()
	}

	private func start() {
		guard !started else { return }
		started = true
		refreshZones()

		NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { _ in
			MainActor.assumeIsolated {
				let watcher = MenuBarWatcher.shared
				for index in watcher.entries.indices { watcher.entries[index].windowID = nil }
				watcher.refreshZones()
				watcher.check()
			}
		}

		// Mouse-moved monitors need no Accessibility permission. The global one
		// sees other apps, the local one our own panels.
		NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
			MainActor.assumeIsolated { MenuBarWatcher.shared.mouseMoved() }
		}
		NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
			MainActor.assumeIsolated { MenuBarWatcher.shared.mouseMoved() }
			return event
		}

		let slow = Timer(timeInterval: Self.slowInterval, repeats: true) { _ in
			MainActor.assumeIsolated { _ = MenuBarWatcher.shared.check() }
		}
		RunLoop.main.add(slow, forMode: .common)
		slowTimer = slow
		check()
	}

	// MARK: Polling

	private func refreshZones() {
		topZones = NSScreen.screens.map {
			NSRect(x: $0.frame.minX, y: $0.frame.maxY - Self.topZone, width: $0.frame.width, height: Self.topZone)
		}
	}

	/// True when the cursor is within the top strip of any screen, or above it.
	private func cursorNearTop() -> Bool {
		let point = NSEvent.mouseLocation
		return topZones.contains { point.x >= $0.minX && point.x < $0.maxX && point.y >= $0.minY }
	}

	/// Fires at display rate, so it only decides whether to poll faster.
	private func mouseMoved() {
		guard fastTimer == nil, cursorNearTop() else { return }
		lastActive = Date()
		let timer = Timer(timeInterval: Self.fastInterval, repeats: true) { _ in
			MainActor.assumeIsolated { MenuBarWatcher.shared.fastTick() }
		}
		RunLoop.main.add(timer, forMode: .common)
		fastTimer = timer
	}

	private func fastTick() {
		let anyShowing = check()
		if anyShowing || cursorNearTop() {
			lastActive = Date()
		} else if Date().timeIntervalSince(lastActive) > Self.linger {
			fastTimer?.invalidate()
			fastTimer = nil
		}
	}

	/// Updates every panel and returns whether any menu bar is showing.
	@discardableResult
	private func check() -> Bool {
		entries.removeAll { $0.panel == nil }
		var anyShowing = false
		for index in entries.indices {
			guard let panel = entries[index].panel, let screen = panel.screen else { continue }
			let showing = isShowing(&entries[index], on: screen)
			anyShowing = anyShowing || showing
			if showing != entries[index].showing {
				entries[index].showing = showing
				panel.setMenuBarShowing(showing)
			}
		}
		return anyShowing
	}

	private func isShowing(_ entry: inout Entry, on screen: NSScreen) -> Bool {
		if let id = entry.windowID, let frame = MenuBarWindow.frame(of: id) {
			return MenuBarWindow.isShowing(frame, on: screen)
		}
		// Unknown or stale id (for example after a display change): look again.
		guard let id = MenuBarWindow.discover(on: screen), let frame = MenuBarWindow.frame(of: id) else {
			entry.windowID = nil
			return false
		}
		entry.windowID = id
		return MenuBarWindow.isShowing(frame, on: screen)
	}
}

/// Finds and reads the Window Server "Menubar" windows.
enum MenuBarWindow {
	/// The Menubar window whose x-range overlaps the screen the most.
	static func discover(on screen: NSScreen) -> CGWindowID? {
		guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
			return nil
		}
		var best: (id: CGWindowID, overlap: CGFloat)?
		for info in list {
			guard info[kCGWindowOwnerName as String] as? String == "Window Server",
				info[kCGWindowName as String] as? String == "Menubar",
				info[kCGWindowLayer as String] as? Int == 24,
				let number = info[kCGWindowNumber as String] as? UInt32,
				let bounds = info[kCGWindowBounds as String] as? NSDictionary,
				let rect = CGRect(dictionaryRepresentation: bounds)
			else { continue }
			let overlap = min(rect.maxX, screen.frame.maxX) - max(rect.minX, screen.frame.minX)
			if overlap > 0, overlap > (best?.overlap ?? 0) { best = (number, overlap) }
		}
		return best?.id
	}

	/// Reads one window's frame in CG coordinates without listing every window.
	static func frame(of id: CGWindowID) -> CGRect? {
		var value = UnsafeRawPointer(bitPattern: UInt(id))
		guard let ids = CFArrayCreate(nil, &value, 1, nil),
			let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
			let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary
		else { return nil }
		return CGRect(dictionaryRepresentation: bounds)
	}

	/// Showing once the bar has moved more than 1 pt from its hidden spot, which
	/// is directly above the screen's top edge.
	static func isShowing(_ frame: CGRect, on screen: NSScreen) -> Bool {
		guard let primary = NSScreen.screens.first else { return false }
		let top = primary.frame.maxY - screen.frame.maxY
		return frame.minY > top - frame.height + 1
	}
}
