import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
	// Render the pill once to a PNG and exit, to check layout without a live bar.
	let path = arguments[index + 1]
	Task { @MainActor in
		do {
			try await renderSnapshot(to: path, client: AeroSpaceClient())
			exit(0)
		} catch {
			FileHandle.standardError.write("snapshot failed: \(error)\n".data(using: .utf8)!)
			exit(1)
		}
	}
} else {
	app.delegate = delegate
}

app.setActivationPolicy(.accessory)
app.run()
