import AppKit
import CoreText
import SwiftUI

/// Catppuccin Mocha, matching the sketchybar config.
enum Theme {
	static let barHeight: CGFloat = 34

	static let pill = Color(argb: 0xeb1e_1e2e)
	/// The workspace pill's accent (`[workspaces] accent`), green unless configured.
	@MainActor static var accent: Color { Color(argb: Settings.shared.values.accent) }
	static let surface0 = Color(argb: 0xff31_3244)
	/// The pills' resting outline.
	static let border = Color(argb: 0xff45_475a)
	/// Unfocused workspace numbers and the calendar separator, deliberately subdued.
	static let grey = Color(argb: 0xff7f_849c)
	static let onAccent = Color(argb: 0xc000_0000)
	static let red = Color(argb: 0xfff3_8ba8)
	static let yellow = Color(argb: 0xfff9_e2af)
	static let blue = Color(argb: 0xff89_b4fa)
	static let text = Color(argb: 0xffcd_d6f4)

	/// The UI text, per `[text] font`.
	@MainActor static var label: Font {
		switch Settings.shared.values.font {
		case .rounded: .system(size: 13, weight: .medium, design: .rounded).monospacedDigit()
		case .mono: .system(size: 13, weight: .medium, design: .monospaced)
		case .sf: .system(size: 13, weight: .medium).monospacedDigit()
		case .pixel: .custom("Pixel Code", size: 14)
		}
	}

	@MainActor private static var digitBearings: [FontChoice: CGFloat] = [:]

	/// The selected font's digit right side bearing: the advance of "0" minus the
	/// right edge of its ink. Subtracted where visible gaps are measured from the ink.
	@MainActor static var digitBearing: CGFloat {
		let choice = Settings.shared.values.font
		if let cached = digitBearings[choice] { return cached }
		let bearing = measureDigitBearing(choice)
		digitBearings[choice] = bearing
		return bearing
	}

	private static func measureDigitBearing(_ choice: FontChoice) -> CGFloat {
		let font: CTFont
		switch choice {
		case .rounded, .mono, .sf:
			let base = NSFont.systemFont(ofSize: 13, weight: .medium)
			let design: NSFontDescriptor.SystemDesign? = choice == .rounded ? .rounded : choice == .mono ? .monospaced : nil
			var descriptor = design.flatMap { base.fontDescriptor.withDesign($0) } ?? base.fontDescriptor
			if choice != .mono {
				descriptor = descriptor.addingAttributes([
					.featureSettings: [[
						NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
						NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
					]]
				])
			}
			font = NSFont(descriptor: descriptor, size: 13) ?? base
		case .pixel:
			font = CTFontCreateWithName("Pixel Code" as CFString, 14, nil)
		}
		var glyph = CTFontGetGlyphWithName(font, "zero" as CFString)
		var character: UniChar = 0x30
		if glyph == 0 { CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) }
		guard glyph != 0 else { return 0 }
		var advance = CGSize.zero
		CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
		var rect = CGRect.zero
		CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &rect, 1)
		let bearing = advance.width - rect.maxX
		return bearing.isFinite ? max(bearing, 0) : 0
	}
	/// Pixel Code has no U+F00F6, so this names the Nerd Font that does instead of
	/// leaving it to fallback. Its ink is wider than its advance; see `symbolOverhang`.
	static let symbolFont = "Liga SFMono Nerd Font"
	/// `[calendar] icon-size` in points.
	@MainActor static var symbolSize: CGFloat { CGFloat(Settings.shared.values.calendarIconSize) }
	@MainActor static var symbol: Font { .custom(symbolFont, size: symbolSize) }

	@MainActor private static var overhangs: [CGFloat: CGFloat] = [:]

	/// How far the calendar glyph's ink overhangs its advance at the current size
	/// (1.85 pt at 14 pt). Fed to `.tracking` so the live view doesn't clip it.
	@MainActor static var symbolOverhang: CGFloat {
		let size = symbolSize
		if let overhang = overhangs[size] { return overhang }
		let font = CTFontCreateWithName(symbolFont as CFString, size, nil)
		let text = NSAttributedString(string: "\u{F00F6}", attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
		let line = CTLineCreateWithAttributedString(text)
		let overhang = CTLineGetImageBounds(line, nil).maxX - CTLineGetTypographicBounds(line, nil, nil, nil)
		let value = overhang.isFinite ? max(overhang, 0) : 0
		overhangs[size] = value
		return value
	}
	static let appIconFont = "sketchybar-app-font"
	/// The pill's height.
	static let pillHeight: CGFloat = 30
	/// The gap between the focus capsule and the pill's edge.
	@MainActor static var focusMargin: CGFloat { CGFloat(Settings.shared.values.focusMargin) }
	/// The focus capsule's height, whatever the icon or font size.
	@MainActor static var focusHeight: CGFloat { pillHeight - 2 * focusMargin }
	/// The capsule's horizontal padding around the icons. Auto matches the
	/// vertical inset, so a single icon sits in a circle.
	@MainActor static var focusPadding: CGFloat {
		if let padding = Settings.shared.values.focusPadding { return CGFloat(padding) }
		return max(1, (focusHeight - appIconSize) / 2)
	}
	/// `[workspaces] icon-size` in points.
	@MainActor static var appIconSize: CGFloat { CGFloat(Settings.shared.values.iconSize) }
	@MainActor static var appIcon: Font { Font(AppIcons.font(size: appIconSize)) }

	/// The pills' base colour without its alpha, which the glass tint supplies instead.
	static let glassBase = Color(argb: 0xff1e_1e2e)
	/// How strongly the glass is tinted dark. Raise it if text is hard to read over
	/// bright wallpapers; lower it to let more of the wallpaper through.
	static let glassTintOpacity = 0.55
	/// How strongly the default frost is tinted dark. Much lower and, over a plain
	/// wallpaper, the pill reads as just its rim, like an outline.
	static let frostTintOpacity = 0.45
	/// The ring's track on glass, standing in for the neutral border.
	static let glassTrack = Color.white.opacity(0.15)

	/// How strong an accent border is, unless `border-opacity` says otherwise.
	static let borderAccentOpacity = 0.6

	/// The focus capsule's green opacity in the default `.translucent` style.
	static let focusOpacity = 0.75

	/// The focus capsule's slide: a little bounce, so it overshoots and settles.
	static let focusSpring = Spring(duration: 0.38, bounce: 0.2)
	static let animation = Animation.smooth(duration: 0.35)
	/// Hover fades: quick, so the cursor never waits on them.
	static let hoverFade = Animation.easeOut(duration: 0.15)
	static let pressScale: CGFloat = 0.92
}

extension Color {
	init(argb: UInt32) {
		self.init(
			.sRGB,
			red: Double((argb >> 16) & 0xff) / 255,
			green: Double((argb >> 8) & 0xff) / 255,
			blue: Double(argb & 0xff) / 255,
			opacity: Double((argb >> 24) & 0xff) / 255
		)
	}
}

/// What a pill is made of. `.frost` is the
/// shipped look, `.flat` is the opt-out and Liquid Glass is an experiment.
enum PillMaterial: Equatable, Sendable {
	enum Glass: Equatable, Sendable {
		case regular, clear
	}

	case flat
	/// Liquid Glass, tinted dark by `tint` (0 is untinted). macOS 26 and later.
	case glass(Glass, tint: Double)
	/// A blurred window backdrop with a hand-drawn rim, the default; works on macOS 14 and later.
	case frost(tint: Double)

	var isFlat: Bool { self == .flat }
}

/// An optional outline drawn over the pill's backing.
enum PillBorder: Equatable, Sendable {
	case none
	/// A 1 pt line in `Theme.border`.
	case neutral
	/// A 1 pt line in the pill's accent colour at this opacity.
	case accent(opacity: Double)
}

/// A behind-window blur that stays in its active look although the panel never
/// becomes key, which `NSGlassEffectView` can't be told to do.
private struct FrostBlur: NSViewRepresentable {
	func makeNSView(context: Context) -> NSVisualEffectView {
		let view = NSVisualEffectView()
		view.material = .hudWindow
		view.blendingMode = .behindWindow
		view.state = .active
		return view
	}

	func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
	/// A pill's backing: the flat fill with the neutral outline, or the chosen
	/// material, which draws its own edge. `border` goes on top of either;
	/// `accent` is the colour of the `.accent` border.
	func pillBackground<S: InsettableShape>(_ shape: S, material: PillMaterial, border: PillBorder = .none, accent: Color) -> some View {
		materialBacked(shape, material: material, replacesStroke: border != .none)
			.overlay {
				switch border {
				case .none:
					EmptyView()
				case .neutral:
					shape.strokeBorder(Theme.border, lineWidth: 1)
				case .accent(let opacity):
					shape.strokeBorder(accent.opacity(opacity), lineWidth: 1)
				}
			}
	}

	@ViewBuilder
	private func materialBacked<S: InsettableShape>(_ shape: S, material: PillMaterial, replacesStroke: Bool) -> some View {
		switch material {
		case .flat:
			flatBacked(shape, stroked: !replacesStroke)
		case .glass(let style, let tint):
			if #available(macOS 26, *) {
				glassBacked(shape, style: style, tint: tint)
			} else {
				flatBacked(shape, stroked: !replacesStroke)
			}
		case .frost(let tint):
			frostBacked(shape, tint: tint)
		}
	}

	private func flatBacked<S: InsettableShape>(_ shape: S, stroked: Bool) -> some View {
		background(shape.fill(Theme.pill))
			.overlay { if stroked { shape.strokeBorder(Theme.border, lineWidth: 1) } }
	}

	@available(macOS 26, *)
	private func glassBacked<S: InsettableShape>(_ shape: S, style: PillMaterial.Glass, tint: Double) -> some View {
		let base: Glass = style == .clear ? .clear : .regular
		return glassEffect(tint > 0 ? base.tint(Theme.glassBase.opacity(tint)) : base, in: shape)
	}

	private func frostBacked<S: InsettableShape>(_ shape: S, tint: Double) -> some View {
		background {
			// The tint goes over the blur: a behind-window blur covers anything
			// drawn beneath it in the window.
			ZStack {
				FrostBlur()
				Theme.glassBase.opacity(tint)
			}
			.clipShape(shape)
		}
		.overlay {
			// Faint inner highlight just inside the rim, strongest at the top.
			shape.inset(by: 1).strokeBorder(
				LinearGradient(
					colors: [.white.opacity(0.12), .white.opacity(0)],
					startPoint: .top,
					endPoint: .center
				),
				lineWidth: 1
			)
		}
		.overlay {
			// The specular rim: bright where light would catch the top edge.
			shape.strokeBorder(
				LinearGradient(
					colors: [.white.opacity(0.35), .white.opacity(0.06)],
					startPoint: .top,
					endPoint: .bottom
				),
				lineWidth: 1
			)
		}
	}
}
