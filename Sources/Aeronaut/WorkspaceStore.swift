import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceStore {
	private(set) var snapshot = Snapshot()

	@ObservationIgnored private let client: AeroSpaceClient
	@ObservationIgnored private var isRefreshing = false
	@ObservationIgnored private var needsRefresh = false
	/// Focus changes that arrived during the hold window, newest last.
	@ObservationIgnored private var pendingWorkspace: String?
	@ObservationIgnored private var pendingWindowID: Int?
	/// Whether a `focus-changed` has set `pendingWindowID` since the last show,
	/// so a lone `focused-workspace-changed` leaves the shown window alone.
	@ObservationIgnored private var hasPendingWindow = false
	@ObservationIgnored private var isHolding = false
	@ObservationIgnored private var refreshAfterHold = false
	/// Bumped on every focus event, so a refresh that started before one can
	/// tell its read is stale.
	@ObservationIgnored private var focusGeneration = 0

	/// AeroSpace sometimes bounces focus away and back within a few dozen
	/// milliseconds. The first change shows at once; later ones wait this long
	/// and only show if they still differ.
	private static let holdWindow = Duration.milliseconds(100)

	init(client: AeroSpaceClient) {
		self.client = client
	}

	func start() {
		requestRefresh()
		Task {
			for await event in client.events() {
				apply(event)
			}
		}
		// Safety net for changes AeroSpace has no event for, such as a
		// background window closing.
		Task {
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(5))
				requestRefresh()
			}
		}
	}

	func focus(workspace: String) {
		Task { try? await client.focus(workspace: workspace) }
	}

	func focus(window: Int) {
		Task { try? await client.focus(window: window) }
	}

	private func apply(_ event: AeroSpaceEvent) {
		// Move the highlight straight away; the refresh then fills in any
		// window changes.
		if event.name == "focused-workspace-changed" || event.name == "focus-changed" {
			focusGeneration += 1
		}
		switch event.name {
		case "focused-workspace-changed":
			if let workspace = event.workspace {
				pendingWorkspace = workspace
				applyFocus()
			}
		case "focus-changed":
			// The workspace comes with the window, so the pair of events AeroSpace
			// sends for one change counts as one.
			if let workspace = event.workspace { pendingWorkspace = workspace }
			pendingWindowID = event.windowID
			hasPendingWindow = true
			applyFocus()
		default:
			break
		}
		requestRefresh()
	}

	private func applyFocus() {
		guard !isHolding else { return }
		showPendingFocus()
		isHolding = true
		Task {
			try? await Task.sleep(for: Self.holdWindow)
			isHolding = false
			showPendingFocus()
			if refreshAfterHold {
				refreshAfterHold = false
				requestRefresh()
			}
		}
	}

	private func showPendingFocus() {
		if let workspace = pendingWorkspace, workspace != snapshot.focusedWorkspace {
			snapshot.focusedWorkspace = workspace
		}
		if hasPendingWindow {
			hasPendingWindow = false
			if pendingWindowID != snapshot.focusedWindowID {
				snapshot.focusedWindowID = pendingWindowID
			}
		}
	}

	/// Coalesces bursts of events into as few CLI round trips as possible. It
	/// waits out the hold window so the CLI reads the settled focus.
	private func requestRefresh() {
		guard !isHolding else {
			refreshAfterHold = true
			return
		}
		guard !isRefreshing else {
			needsRefresh = true
			return
		}
		isRefreshing = true
		Task {
			repeat {
				needsRefresh = false
				let generation = focusGeneration
				if let next = try? await client.snapshot() {
					if isHolding {
						// Focus moved while the CLI ran; this read may be mid-flicker.
						refreshAfterHold = true
					} else if generation != focusGeneration {
						// Focus moved after this read began, so its focus may predate the
						// change. Take its workspaces and windows, keep the focus the
						// events set, and read again for the settled focus.
						var merged = next
						merged.focusedWorkspace = snapshot.focusedWorkspace
						merged.focusedWindowID = snapshot.focusedWindowID
						if merged != snapshot { snapshot = merged }
						needsRefresh = true
					} else {
						if next != snapshot { snapshot = next }
						pendingWorkspace = next.focusedWorkspace
						pendingWindowID = next.focusedWindowID
						hasPendingWindow = false
					}
				}
			} while needsRefresh
			isRefreshing = false
		}
	}
}
