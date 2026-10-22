import SwiftUI

/// Snapshot-only: the highlight rect interpolated between two workspaces.
struct HighlightSlide {
	let from: String
	let to: String
	let progress: CGFloat
}

/// The `.all` style: every visible workspace shows its number and icons. The
/// green capsule sits behind a grey layer with a capsule-shaped hole, and a
/// dark copy of the content is masked to the same capsule, so text is dark
/// exactly where the capsule is, even mid-slide. All three use one rect,
/// resolved from the focused group's anchor.
struct AllWorkspaces: View {
	let snapshot: Snapshot
	var slide: HighlightSlide?
	let onSelectWorkspace: @MainActor (String) -> Void
	let onSelectWindow: @MainActor (Int) -> Void

	private enum Layer {
		/// Invisible; owns the layout and reports each group's bounds.
		case measure
		/// Grey content that takes taps.
		case grey
		/// Dark copy, shown only inside the capsule.
		case dark
	}

	var body: some View {
		groups(.measure)
			.opacity(0)
			.allowsHitTesting(false)
			.overlayPreferenceValue(ItemBounds.self) { bounds in
				let capsule = HighlightCapsule(bounds: bounds, focused: snapshot.focusedWorkspace, slide: slide)
				ZStack(alignment: .topLeading) {
					capsule.foregroundStyle(Theme.accent)
					groups(.grey)
						.mask {
							Rectangle()
								.overlay { capsule.blendMode(.destinationOut) }
								.compositingGroup()
						}
					groups(.dark)
						.mask { capsule.foregroundStyle(.black) }
						.allowsHitTesting(false)
				}
			}
	}

	private func groups(_ layer: Layer) -> some View {
		HStack(spacing: 0) {
			ForEach(snapshot.visibleWorkspaces) { workspace in
				WorkspaceGroup(
					workspace: workspace,
					isFocused: workspace.id == snapshot.focusedWorkspace,
					focusedWindowID: snapshot.focusedWindowID,
					layer: layer,
					onSelectWindow: onSelectWindow
				)
				.padding(.horizontal, 4)
				.contentShape(Rectangle())
				.onTapGesture { onSelectWorkspace(workspace.id) }
				.transition(.scale(scale: 0.6).combined(with: .opacity))
			}
		}
		// All three layers must lay out at their ideal size, or the overlays
		// get squeezed (digits first) and drift away from the measured rects.
		.fixedSize()
	}

	private struct WorkspaceGroup: View {
		let workspace: Workspace
		let isFocused: Bool
		let focusedWindowID: Int?
		let layer: Layer
		let onSelectWindow: @MainActor (Int) -> Void

		private var color: Color { layer == .dark ? Theme.onAccent : Theme.grey }


		var body: some View {
			HStack(spacing: 6 - Theme.digitBearing) {
				Text(workspace.id)
					.font(Theme.label)
					.foregroundStyle(color)
				if !workspace.windows.isEmpty {
					HStack(spacing: 6) {
						ForEach(workspace.windows) { window in
							AppIcon(
								appName: window.appName,
								// Only the focused workspace's other windows are dimmed.
								isFocused: !(layer == .dark && isFocused) || window.id == focusedWindowID,
								color: color
							)
							.onTapGesture { onSelectWindow(window.id) }
							.transition(.scale.combined(with: .opacity))
						}
					}
				}
			}
			.padding(.leading, 8)
			.padding(.trailing, workspace.windows.isEmpty ? 8 - Theme.digitBearing : 8)
			.frame(height: Theme.focusHeight)
			.anchorPreference(key: ItemBounds.self, value: .bounds) {
				layer == .measure ? [workspace.id: $0] : [:]
			}
		}
	}
}

/// The capsule shape at the focused group's rect. Fill it with the caller's
/// foreground style; the green capsule and both masks use this one view.
private struct HighlightCapsule: View {
	let bounds: [String: Anchor<CGRect>]
	let focused: String?
	let slide: HighlightSlide?

	var body: some View {
		GeometryReader { proxy in
			if let rect = rect(in: proxy) {
				Capsule()
					.frame(width: rect.width, height: rect.height)
					.offset(x: rect.minX, y: rect.minY)
			}
		}
	}

	private func rect(in proxy: GeometryProxy) -> CGRect? {
		if let slide, let from = bounds[slide.from], let to = bounds[slide.to] {
			return SlideMotion.rect(start: proxy[from], target: proxy[to], progress: slide.progress)
		}
		return focused.flatMap { bounds[$0] }.map { proxy[$0] }
	}
}
