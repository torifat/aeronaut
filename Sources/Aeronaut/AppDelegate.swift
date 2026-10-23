import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private let store = WorkspaceStore(client: AeroSpaceClient())
	private let calendar = CalendarStore()
	private let config = ConfigWatcher()
	private var leftPanel: PillPanel?
	private var rightPanel: PillPanel?

	func applicationDidFinishLaunching(_ notification: Notification) {
		config.start()
		let panel = PillPanel(rootView: LeftBar(store: store))
		leftPanel = panel
		place(panel)
		panel.orderFrontRegardless()

		let right = PillPanel(rootView: RightBar(store: calendar))
		rightPanel = right
		placeRight(right)
		right.orderFrontRegardless()

		NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				if let panel = self.leftPanel { self.place(panel) }
				if let panel = self.rightPanel { self.placeRight(panel) }
			}
		}

		store.start()
		calendar.start()
	}

	/// Pins the panel to the top-left of the primary display, in the menu bar row.
	/// On a notched display it stops at the notch; elsewhere it takes the left half.
	private func place(_ panel: NSPanel) {
		guard let screen = NSScreen.screens.first else { return }
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

	/// Pins the panel to the top-right of the primary display. On a notched
	/// display it starts at the notch; elsewhere it takes the right half.
	private func placeRight(_ panel: NSPanel) {
		guard let screen = NSScreen.screens.first else { return }
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

	var body: some View {
		let settings = Settings.shared
		return HStack(spacing: 0) {
			WorkspacesPill(
				snapshot: store.snapshot,
				style: settings.values.workspaces,
				focus: settings.values.focus,
				material: settings.material,
				border: settings.border,
				onSelectWorkspace: store.focus(workspace:),
				onSelectWindow: store.focus(window:)
			)
			Spacer(minLength: 0)
		}
		.padding(.leading, 8)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

private struct RightBar: View {
	let store: CalendarStore

	var body: some View {
		let settings = Settings.shared
		return HStack(spacing: 0) {
			Spacer(minLength: 0)
			NextEventPill(state: store.state, material: settings.material, border: settings.border, style: settings.values.calendarStyle, onSelect: store.openCalendar)
		}
		.padding(.trailing, 8)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
