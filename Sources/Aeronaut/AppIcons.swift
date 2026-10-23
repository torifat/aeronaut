import CoreText
import Foundation

/// Maps app names to sketchybar-app-font ligatures such as ":ghostty:".
enum AppIcons {
	private struct Entry: Decodable {
		let iconName: String
		let appNames: [String]
	}

	/// A signed .app has its resources in Contents/Resources. Only `swift run`
	/// needs `Bundle.module`, which calls fatalError when its bundle is missing,
	/// so it must not be touched when the main bundle has the file.
	private static func resourceURL(_ name: String, _ ext: String) -> URL? {
		if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
		return Bundle.module.url(forResource: name, withExtension: ext)
	}

	/// The font that ships with the app, so icons match `icon_map.json` whatever
	/// copy is installed. Registering it for this process makes a lookup by
	/// name find it ahead of any installed copy. The descriptor always points
	/// at the bundled file.
	@MainActor private static let bundledFont: CTFontDescriptor? = {
		guard let url = resourceURL("sketchybar-app-font", "ttf") else { return nil }
		CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
		let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
		return descriptors?.first
	}()

	/// The icon font at `size`: the bundled copy, or an installed one if the
	/// bundled file couldn't load.
	@MainActor
	static func font(size: CGFloat) -> CTFont {
		if let descriptor = bundledFont { return CTFontCreateWithFontDescriptor(descriptor, size, nil) }
		return CTFontCreateWithName(Theme.appIconFont as CFString, size, nil)
	}

	private static let byAppName: [String: String] = {
		guard
			let url = resourceURL("icon_map", "json"),
			let data = try? Data(contentsOf: url),
			let entries = try? JSONDecoder().decode([Entry].self, from: data)
		else { return [:] }
		var map: [String: String] = [:]
		for entry in entries {
			for name in entry.appNames {
				map[name] = entry.iconName
			}
		}
		return map
	}()

	static func glyph(for appName: String) -> String {
		byAppName[appName] ?? ":default:"
	}

	private struct InkKey: Hashable {
		let glyph: String
		let size: CGFloat
	}

	@MainActor private static var inkWidths: [InkKey: CGFloat] = [:]

	/// How wide a glyph actually draws. Every glyph advances about 1.41 em but
	/// draws within the first em, and some (Ghostty) in less.
	@MainActor
	static func inkWidth(of glyph: String) -> CGFloat {
		let size = Theme.appIconSize
		let key = InkKey(glyph: glyph, size: size)
		if let width = inkWidths[key] { return width }
		let font = font(size: size)
		let text = NSAttributedString(string: glyph, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
		let ink = CTLineGetImageBounds(CTLineCreateWithAttributedString(text), nil).maxX.rounded()
		let width = ink > 0 ? ink : size
		inkWidths[key] = width
		return width
	}
}
