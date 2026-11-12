import AppKit
import SwiftUI

/// What the bars on one screen need to know about it. Its fields are updated in
/// place when the screens change, so the views re-render.
@MainActor
@Observable
final class BarScreen {
	/// The screen's 1-based position in `NSScreen.screens`, like AeroSpace's `monitor-appkit-nsscreen-screens-id`.
	var index: Int
	/// Whether it's `NSScreen.screens.first`.
	var isMain: Bool
	var isBuiltIn: Bool
	/// Whether any connected screen is built in.
	var hasBuiltIn: Bool

	init(index: Int, isMain: Bool, isBuiltIn: Bool, hasBuiltIn: Bool) {
		self.index = index
		self.isMain = isMain
		self.isBuiltIn = isBuiltIn
		self.hasBuiltIn = hasBuiltIn
	}
}

extension CalendarMonitor {
	@MainActor func includes(_ screen: BarScreen) -> Bool {
		switch self {
		case .builtIn: screen.hasBuiltIn ? screen.isBuiltIn : screen.isMain
		case .main: screen.isMain
		case .all: true
		}
	}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	/// One pair of panels per connected display.
	private struct Bars {
		let screen: BarScreen
		let left: PillPanel
		let right: PillPanel
	}

	private let store = WorkspaceStore(client: AeroSpaceClient())
	private let calendar = CalendarStore()
	private let config = ConfigWatcher()
	private var bars: [CGDirectDisplayID: Bars] = [:]

	func applicationDidFinishLaunching(_ notification: Notification) {
		config.start()
		syncScreens()

		NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.syncScreens()
				// A new display's pill needs AeroSpace's monitor list, so don't wait
				// for the safety refresh.
				self.store.refresh()
			}
		}

		store.start()
		calendar.start()
	}

	/// Gives every connected display its panels, re-places the existing ones and
	/// closes those of displays that are gone.
	private func syncScreens() {
		let screens = NSScreen.screens
		let displays = screens.map { (screen: $0, id: Self.displayID(of: $0)) }
		let hasBuiltIn = displays.contains { $0.id.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
		var connected: Set<CGDirectDisplayID> = []
		for (offset, display) in displays.enumerated() {
			guard let id = display.id else { continue }
			connected.insert(id)
			let index = offset + 1
			let isBuiltIn = CGDisplayIsBuiltin(id) != 0
			if let existing = bars[id] {
				let screen = existing.screen
				if screen.index != index { screen.index = index }
				if screen.isMain != (index == 1) { screen.isMain = index == 1 }
				if screen.isBuiltIn != isBuiltIn { screen.isBuiltIn = isBuiltIn }
				if screen.hasBuiltIn != hasBuiltIn { screen.hasBuiltIn = hasBuiltIn }
				place(existing.left, on: display.screen)
				placeRight(existing.right, on: display.screen)
			} else {
				let screen = BarScreen(index: index, isMain: index == 1, isBuiltIn: isBuiltIn, hasBuiltIn: hasBuiltIn)
				let left = PillPanel(rootView: LeftBar(store: store, screen: screen))
				let right = PillPanel(rootView: RightBar(store: calendar, screen: screen))
				place(left, on: display.screen)
				placeRight(right, on: display.screen)
				left.orderFrontRegardless()
				right.orderFrontRegardless()
				bars[id] = Bars(screen: screen, left: left, right: right)
			}
		}
		for (id, gone) in bars where !connected.contains(id) {
			gone.left.orderOut(nil)
			gone.left.close()
			gone.right.orderOut(nil)
			gone.right.close()
			bars[id] = nil
		}
	}

	private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
		(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
	}

	/// Pins the panel to the top-left of the screen, in the menu bar row. On a
	/// notched display it stops at the notch; elsewhere it takes the left half.
	private func place(_ panel: NSPanel, on screen: NSScreen) {
		let width = screen.auxiliaryTopLeftArea?.width ?? screen.frame.width / 2
		panel.setFrame(
			NSRect(
				x: screen.frame.minX,
				y: screen.frame.maxY - Theme.barHeight,
				width: width,
				height: Theme.barHeight
			),
			display: true
		)
	}

	/// Pins the panel to the top-right of the screen. On a notched display it
	/// starts at the notch; elsewhere it takes the right half.
	private func placeRight(_ panel: NSPanel, on screen: NSScreen) {
		let width = screen.auxiliaryTopRightArea?.width ?? screen.frame.width / 2
		panel.setFrame(
			NSRect(
				x: screen.frame.maxX - width,
				y: screen.frame.maxY - Theme.barHeight,
				width: width,
				height: Theme.barHeight
			),
			display: true
		)
	}
}

private struct LeftBar: View {
	let store: WorkspaceStore
	let screen: BarScreen

	var body: some View {
		let settings = Settings.shared
		return HStack(spacing: 0) {
			if let snapshot = store.snapshot.scoped(toScreen: screen.index) {
				WorkspacesPill(
					snapshot: snapshot,
					style: settings.values.workspaces,
					focus: settings.values.focus,
					material: settings.material,
					border: settings.border,
					onSelectWorkspace: store.focus(workspace:),
					onSelectWindow: store.focus(window:)
				)
			}
			Spacer(minLength: 0)
		}
		.padding(.leading, 8)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

/// Every screen keeps its right panel, empty or not, so a config reload that
/// changes `[calendar] monitor` only changes what this view draws.
private struct RightBar: View {
	let store: CalendarStore
	let screen: BarScreen

	var body: some View {
		let settings = Settings.shared
		return HStack(spacing: 0) {
			Spacer(minLength: 0)
			if settings.values.calendarMonitor.includes(screen) {
				NextEventPill(state: store.state, material: settings.material, border: settings.border, style: settings.values.calendarStyle, onSelect: store.openCalendar)
			}
		}
		.padding(.trailing, 8)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
