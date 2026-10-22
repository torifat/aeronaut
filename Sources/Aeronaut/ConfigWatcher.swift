import Foundation

/// Reloads `Settings` whenever `config.toml` changes. It watches the directory,
/// so atomic saves (write a temp file, rename it over) are seen, and the file
/// itself, for editors that write in place. If the directory doesn't exist yet,
/// it watches the nearest ancestor that does and moves down as the path appears.
@MainActor
final class ConfigWatcher {
	private let path: String
	private var directorySource: DispatchSourceFileSystemObject?
	private var fileSource: DispatchSourceFileSystemObject?
	private var directoryWatched: String?
	private var pending: Task<Void, Never>?

	init(path: String = ConfigWatcher.configPath()) {
		self.path = path
	}

	/// `$XDG_CONFIG_HOME/aeronaut/config.toml`, or `~/.config/aeronaut/config.toml`.
	nonisolated static func configPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
		let base: String
		if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
			base = xdg
		} else {
			base = NSHomeDirectory() + "/.config"
		}
		return base + "/aeronaut/config.toml"
	}

	func start() {
		Settings.shared.reload(path: path)
		rewatch()
	}

	private func schedule() {
		// Watching an ancestor, only the next path component appearing matters.
		if let watched = directoryWatched, watched != configDirectory,
			!FileManager.default.fileExists(atPath: nextComponent(below: watched))
		{
			return
		}
		pending?.cancel()
		pending = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(100))
			guard !Task.isCancelled, let self else { return }
			Settings.shared.reload(path: path)
			rewatch()
		}
	}

	private var configDirectory: String { (path as NSString).deletingLastPathComponent }

	/// The path one component further down toward the config directory.
	private func nextComponent(below ancestor: String) -> String {
		var next = configDirectory
		while (next as NSString).deletingLastPathComponent != ancestor, next != "/" {
			next = (next as NSString).deletingLastPathComponent
		}
		return next
	}

	/// Points the sources at the nearest existing ancestor of the config directory
	/// and at the file, if each exists, replacing whatever they watched before.
	private func rewatch() {
		var directory = (path as NSString).deletingLastPathComponent
		while !FileManager.default.fileExists(atPath: directory), directory != "/" {
			directory = (directory as NSString).deletingLastPathComponent
		}
		if directory != directoryWatched || directorySource == nil {
			directorySource?.cancel()
			directorySource = makeSource(directory)
			directoryWatched = directory
		}
		// A rename or delete invalidates the file's descriptor, so always reopen it.
		fileSource?.cancel()
		fileSource = makeSource(path)
	}

	private func makeSource(_ path: String) -> DispatchSourceFileSystemObject? {
		let descriptor = open(path, O_EVTONLY)
		guard descriptor >= 0 else { return nil }
		let source = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: descriptor,
			eventMask: [.write, .extend, .delete, .rename, .link],
			queue: .main
		)
		source.setEventHandler { [weak self] in
			MainActor.assumeIsolated { self?.schedule() }
		}
		source.setCancelHandler { close(descriptor) }
		source.resume()
		return source
	}
}
