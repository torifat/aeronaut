import Foundation

struct Window: Identifiable, Equatable, Sendable {
	let id: Int
	let appName: String
}

struct Workspace: Identifiable, Equatable, Sendable {
	let id: String
	let monitorID: Int
	var windows: [Window]
}

struct Snapshot: Equatable, Sendable {
	var workspaces: [Workspace] = []
	var focusedWorkspace: String?
	var focusedWindowID: Int?
}

struct AeroSpaceEvent: Decodable, Sendable {
	let name: String
	let workspace: String?
	let windowID: Int?

	enum CodingKeys: String, CodingKey {
		case name = "_event"
		case workspace
		case windowID = "windowId"
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
			["list-workspaces", "--all", "--format", "%{workspace}%{monitor-id}", "--json"]
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

		let windowsByWorkspace = Dictionary(grouping: try await windows, by: \.workspace)
		return Snapshot(
			workspaces: try await workspaces.map { row in
				Workspace(
					id: row.workspace,
					monitorID: row.monitorID,
					windows: (windowsByWorkspace[row.workspace] ?? []).map {
						Window(id: $0.windowID, appName: $0.appName)
					}
				)
			},
			focusedWorkspace: try await focusedWorkspace.first?.workspace,
			focusedWindowID: await focusedWindow?.first?.windowID
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

	enum CodingKeys: String, CodingKey {
		case workspace
		case monitorID = "monitor-id"
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
