import Foundation

struct Window: Identifiable, Equatable, Sendable {
	let id: Int
	let appName: String
}

struct Workspace: Identifiable, Equatable, Sendable {
	let id: String
	let monitorID: Int
	var windows: [Window]
	/// Whether this workspace is the one its monitor currently shows. Every
	/// monitor has exactly one.
	var isVisible = false
}

/// One AeroSpace monitor and the screen it sits on.
struct Monitor: Equatable, Sendable {
	let id: Int
	/// The monitor's 1-based position in `NSScreen.screens`.
	let screenIndex: Int
}

struct Snapshot: Equatable, Sendable {
	var workspaces: [Workspace] = []
	/// AeroSpace's one focused workspace. On a snapshot scoped to an unfocused
	/// monitor, that monitor's visible workspace instead.
	var focusedWorkspace: String?
	var focusedWindowID: Int?
	/// Every monitor AeroSpace reports. Empty when it can't say, which keeps
	/// everything on the first screen.
	var monitors: [Monitor] = []
	/// The monitor that holds focus. Only a fallback for `scoped(toScreen:)`,
	/// which looks at `focusedWorkspace` first.
	var focusedMonitorID: Int?
	/// False only on a snapshot scoped to a monitor that doesn't hold focus. That
	/// pill drops its green, because green means focus.
	var hasFocus = true
}

extension Snapshot {
	/// What the pill on one screen shows. `index` is 1-based, like `NSScreen.screens`.
	///
	/// With no monitors to go by, screen 1 gets the snapshot as it is and the
	/// others get nothing. Otherwise the result keeps only that monitor's
	/// workspaces. The monitor that holds focus keeps the focus. Any other one
	/// shows its visible workspace with no focused window and `hasFocus` false.
	/// `monitors` and `focusedMonitorID` are cleared, so a change on another
	/// monitor leaves this snapshot equal.
	func scoped(toScreen index: Int) -> Snapshot? {
		if monitors.isEmpty { return index == 1 ? self : nil }
		guard let monitor = monitors.first(where: { $0.screenIndex == index }) else { return nil }
		// The workspace is right as soon as `focused-workspace-changed` lands, and
		// events can arrive in any order, so it comes before the monitor id.
		let focusedMonitor = workspaces.first { $0.id == focusedWorkspace }?.monitorID ?? focusedMonitorID
		var scoped = self
		scoped.workspaces = workspaces.filter { $0.monitorID == monitor.id }
		scoped.monitors = [monitor]
		scoped.focusedMonitorID = nil
		if monitor.id == focusedMonitor {
			scoped.hasFocus = true
		} else {
			scoped.focusedWorkspace = scoped.workspaces.first(where: \.isVisible)?.id
			scoped.focusedWindowID = nil
			scoped.hasFocus = false
		}
		return scoped
	}

	/// Marks `focusedWorkspace` as the visible workspace on its monitor. A focus
	/// event lands before the refresh that reports visibility. Without this, a
	/// monitor that lost focus right after would show its previous workspace
	/// until that refresh.
	mutating func markFocusedVisible() {
		guard let focused = workspaces.first(where: { $0.id == focusedWorkspace }) else { return }
		for index in workspaces.indices where workspaces[index].monitorID == focused.monitorID {
			workspaces[index].isVisible = workspaces[index].id == focused.id
		}
	}
}

struct AeroSpaceEvent: Decodable, Sendable {
	let name: String
	let workspace: String?
	let windowID: Int?
	let monitorID: Int?

	enum CodingKeys: String, CodingKey {
		case name = "_event"
		case workspace
		case windowID = "windowId"
		case monitorID = "monitorId"
	}
}

enum AeroSpaceError: Error {
	case exit(command: [String], status: Int32)
}

/// Talks to AeroSpace through its CLI.
struct AeroSpaceClient: Sendable {
	let executable: URL

	init(executable: URL? = nil) {
		self.executable = executable ?? Self.locate()
	}

	/// launchd agents get a minimal PATH, so also check the usual Nix and
	/// Homebrew locations. `AERONAUT_AEROSPACE` overrides everything.
	private static func locate() -> URL {
		let env = ProcessInfo.processInfo.environment
		if let path = env["AERONAUT_AEROSPACE"] {
			return URL(fileURLWithPath: path)
		}
		let fromPath = (env["PATH"] ?? "").split(separator: ":").map { "\($0)/aerospace" }
		let known = [
			"/run/current-system/sw/bin/aerospace",
			"/etc/profiles/per-user/\(NSUserName())/bin/aerospace",
			"/opt/homebrew/bin/aerospace",
			"/usr/local/bin/aerospace",
		]
		let found = (fromPath + known).first { FileManager.default.isExecutableFile(atPath: $0) }
		return URL(fileURLWithPath: found ?? known[0])
	}

	@discardableResult
	func run(_ arguments: [String]) async throws -> Data {
		let executable = executable
		return try await withCheckedThrowingContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				let process = Process()
				process.executableURL = executable
				process.arguments = arguments
				let stdout = Pipe()
				process.standardOutput = stdout
				process.standardError = FileHandle.nullDevice
				do {
					try process.run()
				} catch {
					continuation.resume(throwing: error)
					return
				}
				// Read before waiting so a full pipe can't deadlock the child.
				let data = stdout.fileHandleForReading.readDataToEndOfFile()
				process.waitUntilExit()
				if process.terminationStatus == 0 {
					continuation.resume(returning: data)
				} else {
					continuation.resume(
						throwing: AeroSpaceError.exit(command: arguments, status: process.terminationStatus)
					)
				}
			}
		}
	}

	func snapshot() async throws -> Snapshot {
		async let workspaces = decode(
			[WorkspaceRow].self,
			["list-workspaces", "--all", "--format", "%{workspace}%{monitor-id}%{workspace-is-visible}", "--json"]
		)
		async let windows = decode(
			[WindowRow].self,
			["list-windows", "--all", "--format", "%{window-id}%{app-name}%{workspace}", "--json"]
		)
		async let focusedWorkspace = decode(
			[WorkspaceRow].self,
			["list-workspaces", "--focused", "--format", "%{workspace}%{monitor-id}", "--json"]
		)
		// Fails or prints nothing when no window has focus.
		async let focusedWindow = try? decode(
			[WindowRow].self,
			["list-windows", "--focused", "--format", "%{window-id}%{app-name}%{workspace}", "--json"]
		)
		// An AeroSpace without monitor formats leaves the pills on the first screen.
		async let monitors = try? decode(
			[MonitorRow].self,
			["list-monitors", "--format", "%{monitor-id}%{monitor-appkit-nsscreen-screens-id}", "--json"]
		)

		let windowsByWorkspace = Dictionary(grouping: try await windows, by: \.workspace)
		return Snapshot(
			workspaces: try await workspaces.map { row in
				Workspace(
					id: row.workspace,
					monitorID: row.monitorID,
					windows: (windowsByWorkspace[row.workspace] ?? []).map {
						Window(id: $0.windowID, appName: $0.appName)
					},
					isVisible: row.isVisible ?? false
				)
			},
			focusedWorkspace: try await focusedWorkspace.first?.workspace,
			focusedWindowID: await focusedWindow?.first?.windowID,
			monitors: (await monitors ?? []).map { Monitor(id: $0.monitorID, screenIndex: $0.screenIndex) },
			focusedMonitorID: try await focusedWorkspace.first?.monitorID
		)
	}

	/// Streams `aerospace subscribe --all`, restarting it if AeroSpace exits.
	func events() -> AsyncStream<AeroSpaceEvent> {
		let executable = executable
		return AsyncStream { continuation in
			let task = Task.detached {
				while !Task.isCancelled {
					let process = Process()
					process.executableURL = executable
					process.arguments = ["subscribe", "--all"]
					let stdout = Pipe()
					process.standardOutput = stdout
					process.standardError = FileHandle.nullDevice
					do {
						try process.run()
						for try await line in stdout.fileHandleForReading.bytes.lines {
							if let event = try? JSONDecoder().decode(AeroSpaceEvent.self, from: Data(line.utf8)) {
								continuation.yield(event)
							}
						}
					} catch {}
					if process.isRunning {
						process.terminate()
					}
					try? await Task.sleep(for: .seconds(2))
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	func focus(workspace: String) async throws {
		try await run(["workspace", workspace])
	}

	func focus(window: Int) async throws {
		try await run(["focus", "--window-id", String(window)])
	}

	private func decode<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
		try JSONDecoder().decode(T.self, from: try await run(arguments))
	}
}

private struct WorkspaceRow: Decodable {
	let workspace: String
	let monitorID: Int
	/// Absent from a fake or older `aerospace`, and from `--focused` rows.
	let isVisible: Bool?

	enum CodingKeys: String, CodingKey {
		case workspace
		case monitorID = "monitor-id"
		case isVisible = "workspace-is-visible"
	}
}

private struct MonitorRow: Decodable {
	let monitorID: Int
	let screenIndex: Int

	enum CodingKeys: String, CodingKey {
		case monitorID = "monitor-id"
		case screenIndex = "monitor-appkit-nsscreen-screens-id"
	}
}

private struct WindowRow: Decodable {
	let windowID: Int
	let appName: String
	let workspace: String

	enum CodingKeys: String, CodingKey {
		case windowID = "window-id"
		case appName = "app-name"
		case workspace
	}
}
