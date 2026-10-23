import SwiftUI

/// How the workspace pill lays out its items.
enum WorkspacesStyle: String, CaseIterable, Sendable {
	/// Numbers only; the focused workspace shows its icons on the capsule.
	case compact
	/// Every workspace shows its number and icons; the capsule slides under them.
	case all
}

/// How the compact style marks the focused workspace. `.translucent` is the
/// shipped default and `.solid` the opaque alternative; the rest are experiments.
enum FocusStyle: String, CaseIterable, Sendable {
	/// The opaque green capsule with dark content.
	case solid
	/// The green capsule with the pill showing through it, at `Theme.focusOpacity`.
	case translucent
	/// The green capsule with a gradient, a top highlight and a soft shadow.
	case glossy
	/// A faint green fill and border, with green content.
	case tint
	/// A strong green border over a near-clear fill, with light content.
	case outline
	/// No capsule: a green bar under the focused group, with light content.
	case underline

	/// The colour of the focused workspace's icons, or of its number when empty.
	@MainActor var content: Color {
		switch self {
		case .solid, .translucent, .glossy: Theme.onAccent
		case .tint: Theme.accent
		case .outline, .underline: Theme.text
		}
	}

	/// Opacity of the icons that aren't the focused window's.
	var dimmedOpacity: Double {
		switch self {
		case .solid, .translucent, .glossy: 0.4
		case .tint, .outline, .underline: 0.45
		}
	}

	/// The green's opacity in `.translucent`.
	@MainActor static var translucentOpacity: Double { Settings.shared.values.focusOpacity }
}

/// The focus marker's shape, filling the rect `SlidingHighlight` gives it.
struct FocusHighlight: View {
	let style: FocusStyle

	var body: some View {
		switch style {
		case .solid:
			Capsule().fill(Theme.accent)
		case .translucent:
			Capsule().fill(Theme.accent.opacity(FocusStyle.translucentOpacity))
		case .glossy:
			Capsule()
				.fill(Theme.accent)
				.overlay {
					Capsule().fill(LinearGradient(
						colors: [.white.opacity(0.3), .black.opacity(0.12)],
						startPoint: .top,
						endPoint: .bottom
					))
				}
				.overlay {
					Capsule().strokeBorder(
						LinearGradient(
							colors: [.white.opacity(0.5), .white.opacity(0)],
							startPoint: .top,
							endPoint: .center
						),
						lineWidth: 1
					)
				}
				.shadow(color: .black.opacity(0.25), radius: 2, y: 1)
		case .tint:
			Capsule()
				.fill(Theme.accent.opacity(0.2))
				.overlay { Capsule().strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1) }
		case .outline:
			Capsule()
				.fill(Theme.accent.opacity(0.06))
				.overlay { Capsule().strokeBorder(Theme.accent.opacity(0.9), lineWidth: 1.5) }
		case .underline:
			Color.clear.overlay(alignment: .bottom) {
				Capsule()
					.fill(Theme.accent)
					.frame(height: 3)
					.padding(.horizontal, 6)
					.padding(.bottom, 1)
			}
		}
	}
}

extension Snapshot {
	/// Workspaces with windows, plus the focused one even if empty.
	var visibleWorkspaces: [Workspace] {
		workspaces.filter { !$0.windows.isEmpty || $0.id == focusedWorkspace }
	}
}

/// Workspaces with windows (plus the focused one, even if empty). In the
/// compact style the focused workspace gets a green highlight that flows
/// between items as one piece and shows its app icons; the rest show only their number.
struct WorkspacesPill: View {
	let snapshot: Snapshot
	var style: WorkspacesStyle = .compact
	/// How the compact style marks the focused workspace.
	var focus = FocusStyle.translucent
	/// Pill backing; see `PillMaterial`.
	var material = PillMaterial.flat // snapshots stay flat
	var border = Settings.shared.border
	/// Snapshot-only: pins the `.all` capsule part-way between two workspaces.
	var slide: HighlightSlide?
	/// Snapshot-only: freezes the compact highlight part-way through a slide.
	var slideFreeze: SlideFreeze?
	/// Snapshot-only: draws this compact item as hovered.
	var hovered: String?
	var onSelectWorkspace: @MainActor (String) -> Void = { _ in }
	var onSelectWindow: @MainActor (Int) -> Void = { _ in }

	private var visible: [Workspace] { snapshot.visibleWorkspaces }

	var body: some View {
		Group {
			switch style {
			case .compact: compact
			case .all:
				AllWorkspaces(
					snapshot: snapshot,
					slide: slide,
					onSelectWorkspace: onSelectWorkspace,
					onSelectWindow: onSelectWindow
				)
			}
		}
		.frame(height: Theme.pillHeight)
		.pillBackground(Capsule(), material: material, border: border, accent: Theme.accent)
		.animation(Theme.animation, value: snapshot)
	}

	private var compact: some View {
		HStack(spacing: 0) {
			ForEach(visible) { workspace in
				WorkspaceItem(
					workspace: workspace,
					isFocused: workspace.id == snapshot.focusedWorkspace,
					focusedWindowID: snapshot.focusedWindowID,
					focus: focus,
					forceHover: workspace.id == hovered,
					onSelectWorkspace: onSelectWorkspace,
					onSelectWindow: onSelectWindow
				)
				.transition(.scale(scale: 0.6).combined(with: .opacity))
			}
		}
		.backgroundPreferenceValue(ItemBounds.self) { bounds in
			SlidingHighlight(bounds: bounds, focused: snapshot.focusedWorkspace, style: focus, freeze: slideFreeze)
		}
	}
}

private struct WorkspaceItem: View {
	let workspace: Workspace
	let isFocused: Bool
	let focusedWindowID: Int?
	let focus: FocusStyle
	let forceHover: Bool
	let onSelectWorkspace: @MainActor (String) -> Void
	let onSelectWindow: @MainActor (Int) -> Void

	/// The focused workspace's capsule shows its icons instead of its number,
	/// unless it has no windows.
	private var showsWindows: Bool { isFocused && !workspace.windows.isEmpty }


	/// Each item owns its 4 pt of margin on both sides, so the hit area has no
	/// gaps; the capsule insets by that margin.
	private static let margin: CGFloat = 4

	var body: some View {
		HStack(spacing: 0) {
			if showsWindows {
				windows
					.transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .leading)))
			} else {
				number
					.transition(.scale(scale: 0.5).combined(with: .opacity))
			}
		}
		.frame(height: Theme.pillHeight)
		// The highlight's frame when this item is focused, which `SlidingHighlight` reads.
		.background {
			// The same slot as `focusSlot()`, but anchored inside the margin:
			// padding outside the anchor would be part of the reported bounds.
			Color.clear
				.frame(height: Theme.focusHeight)
				.anchorPreference(key: ItemBounds.self, value: .bounds) { [workspace.id: $0] }
				.padding(.horizontal, Theme.focusMargin)
		}
	}

	/// An unfocused (or empty focused) item: just the number, as a button that
	/// switches workspace. Hovering previews the capsule that focus would bring.
	private var number: some View {
		Hoverable(forced: forceHover) { hovering in
			Button { onSelectWorkspace(workspace.id) } label: {
				Text(workspace.id)
					.font(Theme.label)
					// Grey until it's the highlighted number, so it doesn't turn dark
					// while it fades out ahead of the sliding capsule.
					.foregroundStyle(isFocused ? focus.content : hovering ? Theme.text : Theme.grey)
					.padding(.leading, 8 + Self.margin)
					.padding(.trailing, isFocused ? 8 - Theme.digitBearing + Self.margin : 8)
					.frame(height: Theme.pillHeight)
					.background {
						// Exactly the slot the focus capsule would take.
						Capsule()
							.fill(Theme.surface0)
							.focusSlot()
							.opacity(hovering && !isFocused ? 1 : 0)
					}
					.contentShape(Rectangle())
					.animation(Theme.hoverFade, value: hovering)
			}
			.buttonStyle(PressStyle())
			.focusable(false)
		}
	}

	/// The focused item: one button per window.
	private var windows: some View {
		HStack(spacing: 6) {
			ForEach(workspace.windows) { window in
				Hoverable { hovering in
					Button { onSelectWindow(window.id) } label: {
						AppIcon(
							appName: window.appName,
							isFocused: window.id == focusedWindowID,
							color: focus.content,
							isHovering: hovering,
							dimmedOpacity: focus.dimmedOpacity
						)
						.padding(.vertical, 7)
						.contentShape(Rectangle())
					}
					.buttonStyle(PressStyle())
					.focusable(false)
				}
				.transition(.scale.combined(with: .opacity))
			}
		}
		// The anchor insets by `focusMargin`, so this leaves the capsule exactly
		// `focusPadding` clear of the icons.
		.padding(.leading, Theme.focusPadding(beside: inkWidth(of: workspace.windows.first)) + Theme.focusMargin)
		.padding(.trailing, Theme.focusPadding(beside: inkWidth(of: workspace.windows.last)) + Theme.focusMargin)
	}

	private func inkWidth(of window: Window?) -> CGFloat {
		window.map { AppIcons.inkWidth(of: AppIcons.glyph(for: $0.appName)) } ?? Theme.appIconSize
	}
}

extension View {
	/// The focus capsule's slot in an item: its height, centred, inset from the
	/// item's edges by `focusMargin`. The hover ghost uses it, and the capsule's
	/// anchor in `WorkspaceItem.body` repeats it with the anchor inside the padding.
	fileprivate func focusSlot() -> some View {
		frame(height: Theme.focusHeight).padding(.horizontal, Theme.focusMargin)
	}
}

/// One app glyph. The focused window's app is drawn at full strength and the
/// others are dimmed; change the styling here to tell them apart differently.
struct AppIcon: View {
	let appName: String
	let isFocused: Bool
	let color: Color
	var isHovering = false
	var dimmedOpacity = 0.4

	var body: some View {
		let glyph = AppIcons.glyph(for: appName)
		Text(glyph)
			.font(Theme.appIcon)
			.foregroundStyle(color.opacity(isFocused ? 1 : isHovering ? 0.7 : dimmedOpacity))
			.animation(Theme.hoverFade, value: isHovering)
			// The glyph's advance runs well past its ink, so box it to the ink
			// and let the HStack space the icons evenly.
			.fixedSize()
			.frame(width: AppIcons.inkWidth(of: glyph), alignment: .leading)
	}
}
