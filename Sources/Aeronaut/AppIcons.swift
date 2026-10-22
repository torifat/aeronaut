import CoreText
import Foundation

/// Maps app names to sketchybar-app-font ligatures such as ":ghostty:".
enum AppIcons {
	private struct Entry: Decodable {
		let iconName: String
		let appNames: [String]
	}

	private static let byAppName: [String: String] = {
		guard
			let url = Bundle.module.url(forResource: "icon_map", withExtension: "json"),
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
		let font = CTFontCreateWithName(Theme.appIconFont as CFString, size, nil)
		let text = NSAttributedString(string: glyph, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
		let ink = CTLineGetImageBounds(CTLineCreateWithAttributedString(text), nil).maxX.rounded()
		let width = ink > 0 ? ink : size
		inkWidths[key] = width
		return width
	}
}
