// Records the README media: a looping GIF of the workspace pill, one of the calendar pill, and
// the app icon as a PNG. Nothing personal reaches them: the bar runs against a fake `aerospace`
// and a scripted calendar (AERONAUT_DEMO_CALENDAR), with default settings, over a drawn backdrop.
//
// Run from the repo root, unsandboxed (needs the Command Line Tools toolchain, see AGENTS.md):
//   swift scripts/readme-media.swift [--binary PATH] [--out DIR] [--format gif|apng] [--frames DIR]
// Without --binary it runs `swift build -c release` and uses .build/release/Aeronaut. The terminal
// needs Screen Recording permission, and no other Aeronaut may be running.
// Writes <out>/workspaces.gif, <out>/calendar.gif (.png for apng) and <out>/icon.png.
// --frames DIR also writes one contact sheet per clip, to check the frames as stills.

import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: Settings

/// Region of the screen each clip covers, in points from the top-left corner.
let leftRegionWidth: CGFloat = 420
let rightRegionWidth: CGFloat = 360
let regionHeight: CGFloat = 40
/// What the output keeps vertically: the panels' height (Theme.barHeight).
let barHeight: CGFloat = 34
/// The backdrop covers this much of the top of the screen.
let backdropHeight: CGFloat = 80
/// Space kept between the pill's far side and the clip's edge.
let trimMargin: CGFloat = 8

let captureFPS = 60
let outputFPS = 50

/// Seconds after the clip's t0 at which the script sends each event.
enum WorkspaceClip {
	static let focusWindow23 = 0.6
	static let toWorkspace3 = 1.5
	static let toWorkspace1 = 2.4
	static let toWorkspace4 = 3.3
	static let backTo2 = 4.2
	static let duration = 5.3
	/// Time from launch to the first frame, for the bar to settle.
	static let settle = 3.0
}

/// Seconds relative to the whole-minute boundary B that the demo calendar is built around.
enum CalendarClip {
	static let minimumLead = 30.0 // B is at least this long after the script starts
	static let standupFrom = -3.5
	static let backToReviewFrom = 2.5
	static let clipStart = -5.0
	static let clipEnd = 7.5
}

/// The fake workspaces and windows. Window order inside a workspace is AeroSpace's: by app name.
let fakeWorkspaces = ["1", "2", "3", "4", "5", "6"]
let fakeWindows: [(id: Int, app: String, workspace: String)] = [
	(11, "Google Chrome", "1"),
	(21, "Ghostty", "2"), (22, "Ghostty", "2"), (23, "Zed", "2"),
	(31, "Slack", "3"),
	(41, "Spotify", "4"),
	(61, "Obsidian", "6"),
]
let startFocus = (workspace: "2", window: 21)

// Catppuccin Mocha
let base = 0x1e1e2e, mauve = 0xcba6f7, blue = 0x89b4fa, peach = 0xfab387, teal = 0x94e2d5

// MARK: Plumbing

struct Failure: Error, CustomStringConvertible {
	let description: String
	init(_ description: String) { self.description = description }
}

func say(_ message: String) {
	print(message)
	fflush(stdout)
}

func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

func sleep(until host: Double) async {
	let seconds = host - hostNow()
	if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bgraInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
	CGColor(colorSpace: srgb, components: [
		CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha,
	])!
}

func formatBytes(_ count: Int) -> String {
	count >= 1_000_000 ? String(format: "%.2f MB", Double(count) / 1e6) : String(format: "%.1f KB", Double(count) / 1e3)
}

/// Owns everything that has to be undone on the way out, including on error and Ctrl-C.
@MainActor
final class Session {
	var tempDir: URL?
	var aeronaut: Process?
	var fakeExecutable: String?
	var backdrop: NSWindow?

	/// Stops Aeronaut and takes the backdrop down.
	func stopCapture() {
		if let process = aeronaut, process.isRunning {
			process.terminate()
			let deadline = Date().addingTimeInterval(2)
			while process.isRunning && Date() < deadline { usleep(50_000) }
			if process.isRunning { kill(process.processIdentifier, SIGKILL) }
		}
		aeronaut = nil
		// The fake `aerospace subscribe` notices Aeronaut is gone within a moment; don't wait for it.
		if let executable = fakeExecutable {
			let pkill = Process()
			pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
			pkill.arguments = ["-f", "\(executable) subscribe"]
			try? pkill.run()
			pkill.waitUntilExit()
		}
		backdrop?.orderOut(nil)
		backdrop = nil
	}

	func cleanup() {
		stopCapture()
		if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
		tempDir = nil
	}
}

// MARK: Arguments

struct Options {
	var binary: String?
	var out = "docs"
	var apng = false
	var frames: String?

	init(_ arguments: [String]) throws {
		var iterator = arguments.dropFirst().makeIterator()
		func value(for flag: String) throws -> String {
			guard let next = iterator.next() else { throw Failure("\(flag) needs a value") }
			return next
		}
		while let argument = iterator.next() {
			switch argument {
			case "--binary": binary = try value(for: argument)
			case "--out": out = try value(for: argument)
			case "--frames": frames = try value(for: argument)
			case "--format":
				switch try value(for: argument) {
				case "gif": apng = false
				case "apng": apng = true
				default: throw Failure("--format takes gif or apng")
				}
			default:
				throw Failure("usage: swift scripts/readme-media.swift [--binary PATH] [--out DIR] [--format gif|apng] [--frames DIR]")
			}
		}
	}
}

// MARK: Backdrop

/// Draws the backdrop: Catppuccin base with soft colour blobs near both ends, where the pills sit,
/// so the frosted material has something to show.
func drawBackdrop(width: CGFloat, height: CGFloat, scale: CGFloat) -> CGImage {
	let pixelWidth = Int(width * scale), pixelHeight = Int(height * scale)
	let context = CGContext(
		data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
		space: srgb, bitmapInfo: bgraInfo)!
	context.scaleBy(x: scale, y: scale)
	context.setFillColor(color(base))
	context.fill(CGRect(x: 0, y: 0, width: width, height: height))

	// (x from the left edge, y from the top, horizontal radius, colour, strength)
	let left: [(CGFloat, CGFloat, CGFloat, Int, CGFloat)] = [
		(30, 22, 140, mauve, 0.85), (175, 40, 120, blue, 0.85), (275, 14, 100, teal, 0.75), (365, 34, 110, peach, 0.8),
	]
	let right: [(CGFloat, CGFloat, CGFloat, Int, CGFloat)] = [
		(30, 22, 100, teal, 0.8), (135, 40, 110, mauve, 0.85), (235, 12, 100, peach, 0.8), (310, 36, 100, blue, 0.8),
	]
	let blobs = left.map { (x: $0.0, y: $0.1, radius: $0.2, hex: $0.3, strength: $0.4) }
		+ right.map { (x: width - $0.0, y: $0.1, radius: $0.2, hex: $0.3, strength: $0.4) }
	for blob in blobs {
		let gradient = CGGradient(
			colorsSpace: srgb,
			colors: [
				color(blob.hex, blob.strength), color(blob.hex, blob.strength * 0.55),
				color(blob.hex, blob.strength * 0.2), color(blob.hex, 0),
			] as CFArray,
			locations: [0, 0.4, 0.75, 1])!
		context.saveGState()
		context.translateBy(x: blob.x, y: height - blob.y)
		context.scaleBy(x: 1, y: 0.5)
		context.drawRadialGradient(
			gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: blob.radius, options: [])
		context.restoreGState()
	}
	return context.makeImage()!
}

/// Same trick as the pill panels: AppKit would otherwise push a window at the top below the menu bar.
final class BackdropPanel: NSPanel {
	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }
	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
func makeBackdrop(on screen: NSScreen) -> NSWindow {
	let frame = NSRect(
		x: screen.frame.minX, y: screen.frame.maxY - backdropHeight, width: screen.frame.width, height: backdropHeight)
	let panel = BackdropPanel(
		contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
	panel.level = .floating
	panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
	panel.isOpaque = true
	panel.hasShadow = false
	panel.ignoresMouseEvents = true
	panel.hidesOnDeactivate = false
	let image = drawBackdrop(width: frame.width, height: frame.height, scale: screen.backingScaleFactor)
	let view = NSImageView(image: NSImage(cgImage: image, size: frame.size))
	view.imageScaling = .scaleAxesIndependently
	panel.contentView = view
	panel.setFrame(frame, display: true)
	panel.orderFrontRegardless()
	return panel
}

// MARK: Fake AeroSpace

let fakeAeroSpaceScript = """
#!/bin/bash
# Stands in for `aerospace` while recording the README media. Answers from files next to it.
dir="$(cd "$(dirname "$0")" && pwd)"
read -r ws win < "$dir/state"
case "$1 $2" in
	"list-workspaces --all") cat "$dir/workspaces.json" ;;
	"list-workspaces --focused") printf '[{"workspace":"%s","monitor-id":1}]\\n' "$ws" ;;
	"list-windows --all") cat "$dir/windows.json" ;;
	"list-windows --focused") cat "$dir/window-$win.json" ;;
	"subscribe --all")
		# Not `tail -f`: it polls once a second, which would delay every event.
		exec 3< "$dir/events"
		while kill -0 "$PPID" 2>/dev/null; do
			while IFS= read -r -u 3 line; do printf '%s\n' "$line"; done
			sleep 0.01
		done ;;
	"workspace "* | "focus "*) exit 0 ;;
	*) exit 1 ;;
esac
"""

/// Drives the fake `aerospace`: sets the focus it reports, then emits the matching events.
final class FakeAeroSpace {
	let directory: URL
	private let events: FileHandle

	var executable: String { directory.appendingPathComponent("aerospace").path }

	init(directory: URL) throws {
		self.directory = directory
		let fm = FileManager.default
		try fm.createDirectory(at: directory, withIntermediateDirectories: true)
		let script = directory.appendingPathComponent("aerospace")
		try fakeAeroSpaceScript.write(to: script, atomically: true, encoding: .utf8)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
		fm.createFile(atPath: directory.appendingPathComponent("events").path, contents: nil)
		events = try FileHandle(forWritingTo: directory.appendingPathComponent("events"))

		func row(_ window: (id: Int, app: String, workspace: String)) -> String {
			#"{"window-id":\#(window.id),"app-name":"\#(window.app)","workspace":"\#(window.workspace)"}"#
		}
		let workspaces = fakeWorkspaces.map { #"{"workspace":"\#($0)","monitor-id":1}"# }
		try "[\(workspaces.joined(separator: ","))]\n".write(
			to: directory.appendingPathComponent("workspaces.json"), atomically: true, encoding: .utf8)
		try "[\(fakeWindows.map(row).joined(separator: ","))]\n".write(
			to: directory.appendingPathComponent("windows.json"), atomically: true, encoding: .utf8)
		for window in fakeWindows {
			try "[\(row(window))]\n".write(
				to: directory.appendingPathComponent("window-\(window.id).json"), atomically: true, encoding: .utf8)
		}
		try setFocus(workspace: startFocus.workspace, window: startFocus.window)
	}

	/// Atomic, so a refresh in the middle never reads half a line.
	private func setFocus(workspace: String, window: Int) throws {
		try "\(workspace) \(window)\n".write(
			to: directory.appendingPathComponent("state"), atomically: true, encoding: .utf8)
	}

	private func emit(_ lines: [String]) {
		events.write(Data((lines.joined(separator: "\n") + "\n").utf8))
	}

	/// `focus-changed` within the current workspace.
	func focusWindow(_ window: Int, in workspace: String) throws {
		try setFocus(workspace: workspace, window: window)
		emit([#"{"_event":"focus-changed","windowId":\#(window),"workspace":"\#(workspace)"}"#])
	}

	/// What AeroSpace sends for a workspace switch: two lines, workspace first.
	func switchWorkspace(from previous: String, to workspace: String, window: Int) throws {
		try setFocus(workspace: workspace, window: window)
		emit([
			#"{"_event":"focused-workspace-changed","workspace":"\#(workspace)","prevWorkspace":"\#(previous)"}"#,
			#"{"_event":"focus-changed","windowId":\#(window),"workspace":"\#(workspace)"}"#,
		])
	}
}

// MARK: Capture

struct Frame {
	/// Presentation time on the host clock, in seconds.
	let time: Double
	/// BGRA, rows tightly packed, cropped to the bar's height.
	let pixels: Data
}

/// Records a region of a display with ScreenCaptureKit, keeping every frame's timestamp.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
	let pixelWidth: Int
	let pixelRows: Int
	private let capturedHeight: Int
	private var stream: SCStream?
	private let queue = DispatchQueue(label: "readme-media.capture")
	private let lock = NSLock()
	private var frames: [Frame] = []
	private var failure: String?

	init(filter: SCContentFilter, region: CGRect, scale: CGFloat) {
		pixelWidth = Int(region.width * scale)
		capturedHeight = Int(region.height * scale)
		pixelRows = Int(barHeight * scale)
		super.init()
		let configuration = SCStreamConfiguration()
		configuration.sourceRect = region
		configuration.width = pixelWidth
		configuration.height = capturedHeight
		configuration.pixelFormat = kCVPixelFormatType_32BGRA
		configuration.colorSpaceName = CGColorSpace.sRGB
		configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(captureFPS))
		configuration.showsCursor = false
		configuration.queueDepth = 8
		let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
		try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
		self.stream = stream
	}

	func start() async throws { try await stream?.startCapture() }

	/// Drops frames before `time`, keeping the last of them: it is what the screen showed at `time`.
	func prune(before time: Double) {
		lock.withLock {
			guard let keep = frames.lastIndex(where: { $0.time < time }) else { return }
			frames.removeFirst(keep)
		}
	}

	func stop() async throws -> [Frame] {
		try await stream?.stopCapture()
		stream = nil
		return lock.withLock {
			if let failure { fputs("aeronaut readme-media: \(failure)\n", stderr) }
			return frames
		}
	}

	func stream(_ stream: SCStream, didStopWithError error: any Error) {
		lock.withLock { failure = "capture stopped: \(error.localizedDescription)" }
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
		guard type == .screen, buffer.isValid,
			let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
				as? [[SCStreamFrameInfo: Any]],
			let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
			let image = CMSampleBufferGetImageBuffer(buffer)
		else { return }
		CVPixelBufferLockBaseAddress(image, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
		guard let address = CVPixelBufferGetBaseAddress(image) else { return }
		guard CVPixelBufferGetWidth(image) == pixelWidth, CVPixelBufferGetHeight(image) == capturedHeight else {
			lock.withLock {
				failure = "got \(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)) px, expected \(pixelWidth)x\(capturedHeight)"
			}
			return
		}
		let stride = CVPixelBufferGetBytesPerRow(image)
		var pixels = Data(capacity: pixelWidth * 4 * pixelRows)
		for row in 0..<pixelRows {
			pixels.append(Data(bytes: address + row * stride, count: pixelWidth * 4))
		}
		let frame = Frame(time: CMSampleBufferGetPresentationTimeStamp(buffer).seconds, pixels: pixels)
		lock.withLock { frames.append(frame) }
	}
}

func shareableContent() async throws -> SCShareableContent {
	try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
}

/// Windows the window server draws itself, which a clip must not show.
let systemWindowTitles: Set<String> = ["StatusIndicator", "Menubar"]

/// Everything on the display except other apps' windows, the menu bar and the recording indicator. A
/// filter that lists the windows to include would be simpler, but it composites each window alone, and a
/// behind-window blur then shows nothing. The window server's own windows (`system`) have to stay for the
/// blur to work, so only the two that matter are taken out by title. Windows that open later aren't
/// excluded, which is what `watchForIntruders` is for.
func displayFilter(
	_ display: SCDisplay, _ content: SCShareableContent, keeping pids: Set<pid_t>, system: pid_t?
) -> SCContentFilter {
	SCContentFilter(
		display: display,
		excludingWindows: content.windows.filter { window in
			let pid = window.owningApplication?.processID ?? -1
			if pid == system { return systemWindowTitles.contains(window.title ?? "") }
			return !pids.contains(pid)
		})
}

/// Polls for windows that opened after the filter was built (a notification banner, say) and overlap a
/// region. They would show in the clips, so the run reports them. Cancel the task to get the list.
func watchForIntruders(known: Set<CGWindowID>, keeping pids: Set<pid_t>, regions: [CGRect]) -> Task<[String], Never> {
	Task {
		var found: [String] = []
		while !Task.isCancelled {
			if let content = try? await shareableContent() {
				for window in content.windows where !known.contains(window.windowID) {
					guard !pids.contains(window.owningApplication?.processID ?? -1) else { continue }
					guard regions.contains(where: { $0.intersects(window.frame) }) else { continue }
					let name = "\(window.owningApplication?.applicationName ?? "?") \"\(window.title ?? "")\""
					if !found.contains(name) { found.append(name) }
				}
			}
			try? await Task.sleep(for: .seconds(0.5))
		}
		return found
	}
}

/// A throwaway stream that keeps the system's recording indicator on screen. The indicator belongs to the
/// window server, which only shows up as an app to exclude while a capture is running.
final class IndicatorKeeper: NSObject, SCStreamOutput, @unchecked Sendable {
	private let stream: SCStream

	init(display: SCDisplay) throws {
		let configuration = SCStreamConfiguration()
		configuration.width = 16
		configuration.height = 16
		configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
		stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
		super.init()
		try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "readme-media.indicator"))
	}

	func start() async throws { try await stream.startCapture() }
	func stop() async throws { try await stream.stopCapture() }
	func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

// MARK: Encoding

func makeImage(_ pixels: Data, width: Int, height: Int) -> CGImage {
	CGImage(
		width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: srgb,
		bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
		provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// Columns in which any pixel of `frame` differs from `reference`, as a min and max column.
func changedColumns(_ frame: Data, _ reference: Data, width: Int, rows: Int, tolerance: Int = 3) -> ClosedRange<Int>? {
	var low = width, high = -1
	frame.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
		reference.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
			for row in 0..<rows {
				let offset = row * width * 4
				for column in 0..<width {
					let i = offset + column * 4
					if abs(Int(a[i]) - Int(b[i])) > tolerance || abs(Int(a[i + 1]) - Int(b[i + 1])) > tolerance
						|| abs(Int(a[i + 2]) - Int(b[i + 2])) > tolerance
					{
						if column < low { low = column }
						if column > high { high = column }
					}
				}
			}
		}
	}
	return high >= 0 ? low...high : nil
}

struct Clip {
	/// One entry per output frame, sampled every 1/outputFPS seconds: the index of the source frame.
	var sources: [Int]
	var frames: [Frame]
	var reference: Data
	var width: Int
	var rows: Int
}

enum Side { case left, right }

/// Resamples to a steady rate by timestamp: each output time takes the latest frame at or before it.
func resample(_ frames: [Frame], start: Double, duration: Double) throws -> [Int] {
	guard let first = frames.first else { throw Failure("no frames were captured") }
	// The first frame is the screen as it stood when the stream began, so it must come before the clip.
	guard first.time <= start + 0.05 else {
		throw Failure(String(format: "capture began %.2f s after the clip's start; frames before it are missing", first.time - start))
	}
	say(String(format: "  first frame %.2f s before the clip starts", start - first.time))
	var sources: [Int] = []
	var index = 0
	for k in 0..<Int((duration * Double(outputFPS)).rounded()) {
		let time = start + Double(k) / Double(outputFPS)
		while index + 1 < frames.count && frames[index + 1].time <= time { index += 1 }
		sources.append(index)
	}
	return sources
}

/// Crops and merges a clip into (image, delay) pairs and returns the cropped image per output frame too.
func encode(_ clip: Clip, side: Side, scale: CGFloat) -> (images: [(image: CGImage, delay: Double)], all: [CGImage]) {
	var low = clip.width, high = -1
	for index in Set(clip.sources) {
		if let range = changedColumns(clip.frames[index].pixels, clip.reference, width: clip.width, rows: clip.rows) {
			low = min(low, range.lowerBound)
			high = max(high, range.upperBound)
		}
	}
	let margin = Int((trimMargin * scale).rounded())
	let x0 = side == .left ? 0 : max(0, low - margin)
	let x1 = side == .left ? min(clip.width, high + 1 + margin) : clip.width
	let crop = CGRect(x: x0, y: 0, width: x1 - x0, height: clip.rows)
	say("  trimming to columns \(x0)..<\(x1) of \(clip.width) px (pill spans \(low)...\(high))")

	var cache: [Int: CGImage] = [:]
	var images: [(image: CGImage, delay: Double)] = []
	var all: [CGImage] = []
	var previous: Int?
	for source in clip.sources {
		let image: CGImage
		if let cached = cache[source] {
			image = cached
		} else {
			image = makeImage(clip.frames[source].pixels, width: clip.width, height: clip.rows).cropping(to: crop)!
			cache[source] = image
		}
		all.append(image)
		if let last = previous, last == source || clip.frames[last].pixels == clip.frames[source].pixels {
			images[images.count - 1].delay += 1 / Double(outputFPS)
		} else {
			images.append((image, 1 / Double(outputFPS)))
		}
		previous = source
	}
	return (images, all)
}

func writeAnimation(_ images: [(image: CGImage, delay: Double)], to url: URL, apng: Bool) throws {
	let type = apng ? UTType.png : UTType.gif
	guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil)
	else { throw Failure("can't write \(url.path)") }
	let loopKey = apng ? kCGImagePropertyPNGDictionary : kCGImagePropertyGIFDictionary
	CGImageDestinationSetProperties(destination, [loopKey: [apng ? kCGImagePropertyAPNGLoopCount : kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
	for (image, delay) in images {
		let frameProperties: [CFString: Any] = apng
			? [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
			: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]]
		CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
	}
	guard CGImageDestinationFinalize(destination) else { throw Failure("can't finish \(url.path)") }
}

/// About every 10th output frame, stacked vertically at full resolution.
func writeContactSheet(_ images: [CGImage], to url: URL) throws {
	let picked = stride(from: 0, to: images.count, by: 10).map { images[$0] }
	guard let first = picked.first else { return }
	let gap = 2
	let height = picked.count * (first.height + gap) - gap
	let context = CGContext(
		data: nil, width: first.width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
		bitmapInfo: bgraInfo)!
	context.setFillColor(color(0xff00ff))
	context.fill(CGRect(x: 0, y: 0, width: first.width, height: height))
	for (index, image) in picked.enumerated() {
		let y = height - (index + 1) * first.height - index * gap
		context.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height))
	}
	guard let sheet = context.makeImage(),
		let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
	else { throw Failure("can't write \(url.path)") }
	CGImageDestinationAddImage(destination, sheet, nil)
	guard CGImageDestinationFinalize(destination) else { throw Failure("can't finish \(url.path)") }
}

// MARK: Main

@MainActor
func run(_ session: Session) async throws {
	let options = try Options(CommandLine.arguments)
	let fm = FileManager.default
	let repo = URL(fileURLWithPath: fm.currentDirectoryPath)

	// 1. Nothing else may be showing a bar.
	func isAeronautRunning() -> Bool {
		let pgrep = Process()
		pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
		pgrep.arguments = ["-x", "Aeronaut"]
		pgrep.standardOutput = FileHandle.nullDevice
		try? pgrep.run()
		pgrep.waitUntilExit()
		return pgrep.terminationStatus == 0
	}
	if isAeronautRunning() {
		throw Failure("Aeronaut is already running. Quit it first (check with `pgrep -x Aeronaut`); it would be on screen in the clips.")
	}
	guard CGPreflightScreenCaptureAccess() else {
		throw Failure("Screen Recording isn't granted to this terminal (System Settings > Privacy & Security).")
	}

	var binary = options.binary
	if binary == nil {
		say("Building (swift build -c release)...")
		let build = Process()
		build.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
		build.arguments = ["build", "-c", "release"]
		try build.run()
		build.waitUntilExit()
		guard build.terminationStatus == 0 else { throw Failure("swift build failed") }
		binary = repo.appendingPathComponent(".build/release/Aeronaut").path
	}
	guard let binary, fm.isExecutableFile(atPath: binary) else {
		throw Failure("no executable at \(binary ?? ".build/release/Aeronaut")")
	}

	guard let screen = NSScreen.screens.first else { throw Failure("no screen") }
	let scale = screen.backingScaleFactor
	let screenWidth = screen.frame.width
	guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
		throw Failure("can't identify the main display")
	}
	let leftRegion = CGRect(x: 0, y: 0, width: leftRegionWidth, height: regionHeight)
	let rightRegion = CGRect(x: screenWidth - rightRegionWidth, y: 0, width: rightRegionWidth, height: regionHeight)

	// 2. Scratch files.
	let temp = fm.temporaryDirectory.appendingPathComponent("aeronaut-readme-media-\(getpid())")
	session.tempDir = temp
	let fake = try FakeAeroSpace(directory: temp.appendingPathComponent("aerospace"))
	session.fakeExecutable = fake.executable
	let configHome = temp.appendingPathComponent("config")
	try fm.createDirectory(at: configHome, withIntermediateDirectories: true)
	let calendarJSON = temp.appendingPathComponent("calendar.json")
	// B: the first whole minute far enough off that the launch peek is over.
	let boundary = ((Date().timeIntervalSince1970 + CalendarClip.minimumLead) / 60).rounded(.up) * 60
	let demo: [[String: Any]] = [
		["from": 0, "start": boundary + 3 * 3600 + 120, "title": "Design review"],
		["from": boundary + CalendarClip.standupFrom, "start": boundary + 60, "title": "Standup"],
		["from": boundary + CalendarClip.backToReviewFrom, "start": boundary + 3 * 3600 + 120, "title": "Design review"],
	]
	try JSONSerialization.data(withJSONObject: demo).write(to: calendarJSON)

	// 3. Backdrop, with the cursor out of the way so the auto-hidden menu bar stays hidden.
	CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.height / 2))
	let backdrop = makeBackdrop(on: screen)
	session.backdrop = backdrop
	try await Task.sleep(for: .seconds(1))

	// 4. Reference frames of the backdrop alone, for the auto-trim.
	var content = try await shareableContent()
	guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
		throw Failure("ScreenCaptureKit doesn't list the main display")
	}
	let indicator = try IndicatorKeeper(display: display)
	try await indicator.start()
	var indicatorShowing = false
	for _ in 0..<12 {
		try await Task.sleep(for: .seconds(0.25))
		content = try await shareableContent()
		if content.windows.contains(where: { $0.title == "StatusIndicator" }) {
			indicatorShowing = true
			break
		}
	}
	if !indicatorShowing { fputs("readme-media: the recording indicator window wasn't found; it may show in the clips\n", stderr) }
	let ownPID = getpid()
	let systemPID = content.windows.first(where: { $0.title == "StatusIndicator" })?.owningApplication?.processID
	func reference(_ region: CGRect) async throws -> Data {
		let recorder = Recorder(filter: displayFilter(display, content, keeping: [ownPID], system: systemPID), region: region, scale: scale)
		try await recorder.start()
		try await Task.sleep(for: .seconds(0.6))
		guard let last = try await recorder.stop().last else { throw Failure("no reference frame; is Screen Recording allowed?") }
		return last.pixels
	}
	say("Capturing the backdrop...")
	let leftReference = try await reference(leftRegion)
	let rightReference = try await reference(rightRegion)

	// Launch Aeronaut with a clean environment, so the maintainer's config can't leak in.
	var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AERONAUT_") && $0.key != "XDG_CONFIG_HOME" }
	environment["AERONAUT_AEROSPACE"] = fake.executable
	environment["AERONAUT_DEMO_CALENDAR"] = calendarJSON.path
	environment["XDG_CONFIG_HOME"] = configHome.path
	let process = Process()
	process.executableURL = URL(fileURLWithPath: binary)
	process.environment = environment
	say("Launching \(binary)...")
	let launched = hostNow()
	try process.run()
	session.aeronaut = process

	var filter: SCContentFilter?
	var knownWindows: Set<CGWindowID> = []
	for _ in 0..<60 {
		try await Task.sleep(for: .seconds(0.25))
		content = try await shareableContent()
		let windows = content.windows.filter { $0.owningApplication?.processID == process.processIdentifier }
		if windows.count >= 2 {
			filter = displayFilter(display, content, keeping: [ownPID, process.processIdentifier], system: systemPID)
			knownWindows = Set(content.windows.map(\.windowID))
			break
		}
	}
	guard let filter else { throw Failure("Aeronaut's windows never appeared") }
	let intruders = watchForIntruders(known: knownWindows, keeping: [ownPID, process.processIdentifier], regions: [leftRegion, rightRegion])

	// 6. Workspace clip.
	await sleep(until: launched + WorkspaceClip.settle)
	say("Recording the workspace clip...")
	let workspaceRecorder = Recorder(filter: filter, region: leftRegion, scale: scale)
	try await workspaceRecorder.start()
	try await Task.sleep(for: .seconds(0.5))
	let workspaceStart = hostNow()
	let script: [(time: Double, label: String, action: () throws -> Void)] = [
		(WorkspaceClip.focusWindow23, "window 23", { try fake.focusWindow(23, in: "2") }),
		(WorkspaceClip.toWorkspace3, "2 -> 3", { try fake.switchWorkspace(from: "2", to: "3", window: 31) }),
		(WorkspaceClip.toWorkspace1, "3 -> 1", { try fake.switchWorkspace(from: "3", to: "1", window: 11) }),
		(WorkspaceClip.toWorkspace4, "1 -> 4", { try fake.switchWorkspace(from: "1", to: "4", window: 41) }),
		(WorkspaceClip.backTo2, "4 -> 2", { try fake.switchWorkspace(from: "4", to: "2", window: 21) }),
	]
	for step in script {
		await sleep(until: workspaceStart + step.time)
		try step.action()
		say(String(format: "  %@ sent at t0 + %.3f s", step.label, hostNow() - workspaceStart))
	}
	await sleep(until: workspaceStart + WorkspaceClip.duration + 0.1)
	let workspaceFrames = try await workspaceRecorder.stop()
	say("  captured \(workspaceFrames.count) frames")

	// 7. Calendar clip.
	let clipStartWall = boundary + CalendarClip.clipStart
	let wallToHost = hostNow() - Date().timeIntervalSince1970
	say("Recording the calendar clip, from the minute boundary at \(Date(timeIntervalSince1970: boundary).formatted(date: .omitted, time: .standard))...")
	// Start well ahead: ScreenCaptureKit sends nothing while the screen is idle, and on a static screen the
	// first frame can arrive a second or two late. It only has to come before the clip does.
	let calendarRecorder = Recorder(filter: filter, region: rightRegion, scale: scale)
	try await calendarRecorder.start()
	let calendarStart = clipStartWall + wallToHost
	let calendarDuration = CalendarClip.clipEnd - CalendarClip.clipStart
	while hostNow() < calendarStart {
		calendarRecorder.prune(before: calendarStart)
		await sleep(until: min(calendarStart, hostNow() + 1))
	}
	await sleep(until: calendarStart + calendarDuration + 0.1)
	let calendarFrames = try await calendarRecorder.stop()
	say("  captured \(calendarFrames.count) frames")
	try? await indicator.stop()
	intruders.cancel()
	for name in await intruders.value {
		fputs("readme-media: a window opened over the clips: \(name). It may show in them; run again.\n", stderr)
	}

	// Aeronaut and the backdrop have done their job.
	session.stopCapture()

	// 8. Encode.
	let out = URL(fileURLWithPath: options.out)
	try fm.createDirectory(at: out, withIntermediateDirectories: true)
	let ext = options.apng ? "png" : "gif"
	var written: [(path: String, detail: String)] = []
	let clips: [(name: String, side: Side, frames: [Frame], reference: Data, width: Int, start: Double, duration: Double)] = [
		("workspaces", .left, workspaceFrames, leftReference, Int(leftRegionWidth * scale), workspaceStart, WorkspaceClip.duration),
		("calendar", .right, calendarFrames, rightReference, Int(rightRegionWidth * scale), calendarStart, calendarDuration),
	]
	for clip in clips {
		say("Encoding \(clip.name)...")
		let rows = Int(barHeight * scale)
		let sources = try resample(clip.frames, start: clip.start, duration: clip.duration)
		let (images, all) = encode(
			Clip(sources: sources, frames: clip.frames, reference: clip.reference, width: clip.width, rows: rows),
			side: clip.side, scale: scale)
		let url = out.appendingPathComponent("\(clip.name).\(ext)")
		try writeAnimation(images, to: url, apng: options.apng)
		let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
		written.append((url.path, "\(formatBytes(size)), \(images.count) frames after merging (\(all.count) at \(outputFPS) fps), \(all[0].width)x\(all[0].height) px"))
		if let frames = options.frames {
			let directory = URL(fileURLWithPath: frames)
			try fm.createDirectory(at: directory, withIntermediateDirectories: true)
			let sheet = directory.appendingPathComponent("\(clip.name)-contact.png")
			try writeContactSheet(all, to: sheet)
			written.append((sheet.path, "every 10th output frame (0.2 s apart), top to bottom"))
		}
	}

	// 9. Icon.
	say("Drawing the icon...")
	let iconDirectory = temp.appendingPathComponent("icon")
	let icon = Process()
	icon.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
	icon.arguments = [repo.appendingPathComponent("scripts/icon.swift").path, iconDirectory.path]
	try icon.run()
	icon.waitUntilExit()
	guard icon.terminationStatus == 0 else { throw Failure("scripts/icon.swift failed") }
	let iconURL = out.appendingPathComponent("icon.png")
	let sips = Process()
	sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
	sips.arguments = ["-Z", "256", iconDirectory.appendingPathComponent("AppIcon-1024.png").path, "--out", iconURL.path]
	sips.standardOutput = FileHandle.nullDevice
	try sips.run()
	sips.waitUntilExit()
	guard sips.terminationStatus == 0 else { throw Failure("sips failed") }
	written.append((iconURL.path, formatBytes((try? fm.attributesOfItem(atPath: iconURL.path)[.size] as? Int) ?? 0) + ", 256x256 px"))

	// 11. Report.
	say("\nWrote:")
	for file in written { say("  \(file.path): \(file.detail)") }
}

let session = MainActor.assumeIsolated { Session() }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Ctrl-C and kill clean up too.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGINT, SIGTERM] {
	signal(number, SIG_IGN)
	let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
	source.setEventHandler {
		MainActor.assumeIsolated { session.cleanup() }
		fputs("\ninterrupted\n", stderr)
		exit(130)
	}
	source.resume()
	signalSources.append(source)
}

Task { @MainActor in
	do {
		try await run(session)
		session.cleanup()
		exit(0)
	} catch {
		session.cleanup()
		fputs("readme-media: \(error)\n", stderr)
		exit(1)
	}
}
app.run()
