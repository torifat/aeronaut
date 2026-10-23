import AppKit
import EventKit
import SwiftUI

extension Snapshot {
	static let sample = Snapshot(
		workspaces: [
			Workspace(id: "1", monitorID: 1, windows: [Window(id: 1, appName: "Google Chrome")]),
			Workspace(id: "2", monitorID: 1, windows: [
				Window(id: 2, appName: "Ghostty"),
				Window(id: 3, appName: "Ghostty"),
				Window(id: 4, appName: "Ghostty"),
			]),
			Workspace(id: "3", monitorID: 1, windows: [Window(id: 5, appName: "Slack")]),
			Workspace(id: "4", monitorID: 1, windows: [Window(id: 6, appName: "Claude")]),
		],
		focusedWorkspace: "2",
		focusedWindowID: 3
	)

	/// Focus on workspace 3, where the slide rows land.
	static let sampleFocus3 = Snapshot(workspaces: sample.workspaces, focusedWorkspace: "3", focusedWindowID: 5)

	/// Focus on an empty workspace, to check the number-only capsule.
	static let sampleEmptyFocus = Snapshot(
		workspaces: sample.workspaces + [Workspace(id: "6", monitorID: 1, windows: [])],
		focusedWorkspace: "6",
		focusedWindowID: nil
	)
}

enum SnapshotError: Error {
	case render
}

/// Renders the workspace pill from live AeroSpace state (or sample data if
/// AeroSpace isn't reachable), then the calendar pill from live EventKit data
/// (only if access was already granted), then fixed sample states, on a
/// bar-coloured background, and writes it as a PNG.
@MainActor
func renderSnapshot(to path: String, client: AeroSpaceClient) async throws {
	Settings.shared.reload()
	let settings = Settings.shared
	let snapshot = (try? await client.snapshot()) ?? .sample
	// Minute-aligned so the sample offsets land on the labels they name.
	let now = Calendar.current.dateInterval(of: .minute, for: Date())?.start ?? Date()
	let live = CalendarStore.nextEvent(in: EKEventStore(), after: now)
	let samples: [(String, NextEvent?)] = [
		("blue, hours away", NextEvent(start: now.addingTimeInterval(3 * 3600 + 120), title: "Design review")),
		("blue, next day", NextEvent(start: now.addingTimeInterval(30 * 3600), title: "Quarterly planning")),
		("yellow, 5m", NextEvent(start: now.addingTimeInterval(5 * 60 + 30), title: "Standup")),
		("red, 1m", NextEvent(start: now.addingTimeInterval(90), title: "1:1 with Sam")),
		("truncated", NextEvent(start: now.addingTimeInterval(2 * 3600), title: "🎉🎉 Launch party for the new Aeronaut release 🚀🚀")),
		("none", nil),
	]
	func calendarRow(_ state: CalendarState, ring: Double? = nil, style: CalendarStyle = settings.values.calendarStyle) -> some View {
		HStack(spacing: 8) {
			NextEventContent(state: state, isExpanded: false, ringFraction: ring, style: style)
			NextEventContent(state: state, isExpanded: true, ringFraction: ring, style: style)
		}
	}
	/// Urgent rows, `seconds` before the start, with the ring that many seconds in.
	let slideTimes: [TimeInterval] = [0.1, 0.2, 0.3, SlideMotion.slide.duration]
	let rings: [(Int, String)] = [(270, "Standup"), (120, "Design sync"), (45, "1:1 with Sam")]
	let variants: [(String, CalendarStyle)] = [("capsule", .capsule), ("plain", .plain)]
	let variantStates: [(NextEvent?, Double?)] = [
		(NextEvent(start: now.addingTimeInterval(3 * 3600 + 120), title: "Review"), nil),
		(NextEvent(start: now.addingTimeInterval(270), title: "Standup"), 270.0 / 300),
		(NextEvent(start: now.addingTimeInterval(45), title: "1:1 Sam"), 45.0 / 300),
		(nil, nil),
	]
	let view = VStack(alignment: .leading, spacing: 8) {
		WorkspacesPill(snapshot: snapshot, style: settings.values.workspaces, focus: settings.values.focus, border: settings.border)
		WorkspacesPill(snapshot: .sampleEmptyFocus, style: settings.values.workspaces, focus: settings.values.focus, border: settings.border)
		// Workspace 3 hovered: the preview capsule and the brighter number.
		WorkspacesPill(snapshot: .sample, focus: settings.values.focus, border: settings.border, hovered: "3")
		WorkspacesPill(snapshot: snapshot, style: .all)
		WorkspacesPill(snapshot: .sampleEmptyFocus, style: .all)
		// Capsule halfway between workspaces 2 and 3, to check the split colours.
		WorkspacesPill(snapshot: .sample, style: .all, slide: HighlightSlide(from: "2", to: "3", progress: 0.5))
		calendarRow(CalendarState(event: live, now: now))
		ForEach(samples.indices, id: \.self) { index in
			calendarRow(CalendarState(event: samples[index].1, now: now))
		}
		ForEach(rings.indices, id: \.self) { index in
			let (seconds, title) = rings[index]
			let start = now.addingTimeInterval(TimeInterval(seconds))
			calendarRow(
				CalendarState(event: NextEvent(start: start, title: title), now: now),
				ring: Double(seconds) / 300
			)
		}
		// Every calendar style, one column each, over four states.
		HStack(alignment: .top, spacing: 16) {
			ForEach(variants.indices, id: \.self) { column in
				let (title, style) = variants[column]
				VStack(alignment: .leading, spacing: 8) {
					Text(title).font(Theme.label).foregroundStyle(Theme.text)
					ForEach(variantStates.indices, id: \.self) { row in
						let (event, ring) = variantStates[row]
						VStack(alignment: .leading, spacing: 4) {
							ForEach([false, true], id: \.self) { expanded in
								NextEventContent(
									state: CalendarState(event: event, now: now),
									isExpanded: expanded, ringFraction: ring, style: style
								)
							}
						}
					}
				}
			}
		}
		.fixedSize()
		ForEach(FocusStyle.allCases, id: \.self) { focus in
			HStack(spacing: 8) {
				WorkspacesPill(snapshot: snapshot, focus: focus)
				WorkspacesPill(snapshot: .sampleEmptyFocus, focus: focus)
			}
		}
		// The slide from 1 to 3, frozen at fixed times, the last one after the overshoot.
		ForEach(slideTimes, id: \.self) { time in
			WorkspacesPill(snapshot: .sampleFocus3, slideFreeze: SlideFreeze(from: "1", to: "3", time: time))
		}
	}
	.padding(8)
	.background(Color(argb: 0xff10_108c))
	// Through NSHostingView like the live bar: ImageRenderer doesn't clip text to
	// its layout bounds, so it hides glyphs that overflow their advance.
	let host = NSHostingView(rootView: view)
	host.frame = CGRect(origin: .zero, size: host.fittingSize)
	host.layoutSubtreeIfNeeded()
	let size = host.bounds.size
	// Always 2x, whatever screen this runs on.
	guard
		let rep = NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: Int(size.width * 2),
			pixelsHigh: Int(size.height * 2),
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		)
	else { throw SnapshotError.render }
	rep.size = size
	host.cacheDisplay(in: host.bounds, to: rep)
	guard let png = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.render }
	try png.write(to: URL(fileURLWithPath: path))
}
