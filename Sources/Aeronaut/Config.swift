import Foundation

enum MaterialChoice: String, CaseIterable, Sendable {
	case frost, flat, glass
	case clearGlass = "clear-glass"
}

enum BorderChoice: String, CaseIterable, Sendable {
	case none, neutral, accent
}

enum FontChoice: String, CaseIterable, Sendable {
	case pixel, rounded, mono, sf
}

/// Every option, as typed values. The defaults are the shipped look.
struct SettingsValues: Equatable, Sendable {
	var material = MaterialChoice.frost
	/// `nil` is the material's own default tint.
	var tint: Double?
	var border = BorderChoice.accent
	/// `nil` is `Theme.borderAccentOpacity`.
	var borderOpacity: Double?
	var workspaces = WorkspacesStyle.compact
	var focus = FocusStyle.translucent
	var focusOpacity = Theme.focusOpacity
	var iconSize = 16.0
	var focusMargin = 4.0
	var font = FontChoice.pixel
	var calendarIconSize = 17.0
	/// The workspace pill's accent, as 0xAARRGGBB.
	var accent: UInt32 = 0xffa6_e3a1
	/// `nil` is "auto": the capsule's horizontal padding matches its vertical inset.
	var focusPadding: Double?

	static let focusMarginRange = 0.0...6.0
	static let iconSizeRange = 12.0...20.0
	static let calendarIconSizeRange = 12.0...22.0
	static let focusPaddingRange = 0.0...12.0

	static let accentNames: [String: UInt32] = [
		"rosewater": 0xfff5_e0dc, "flamingo": 0xfff2_cdcd, "pink": 0xfff5_c2e7, "mauve": 0xffcb_a6f7,
		"red": 0xfff3_8ba8, "maroon": 0xffeb_a0ac, "peach": 0xfffa_b387, "yellow": 0xfff9_e2af,
		"green": 0xffa6_e3a1, "teal": 0xff94_e2d5, "sky": 0xff89_dceb, "sapphire": 0xff74_c7ec,
		"blue": 0xff89_b4fa, "lavender": 0xffb4_befe,
	]

	/// A Catppuccin Mocha colour name, `#rrggbb` or `#aarrggbb`.
	static func accent(from text: String) -> UInt32? {
		if let named = accentNames[text.lowercased()] { return named }
		guard text.hasPrefix("#"), [6, 8].contains(text.count - 1) else { return nil }
		let digits = text.dropFirst()
		guard digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
		return digits.count == 6 ? 0xff00_0000 | value : value
	}
}

/// The TOML subset of `config.toml`: `[section]` headers, `key = value` lines,
/// quoted strings, numbers and booleans, and `#` comments.
enum ConfigParser {
	fileprivate enum Value: Sendable {
		case string(String)
		case number(Double)
		case bool(Bool)

		var kind: String {
			switch self {
			case .string: "a string"
			case .number: "a number"
			case .bool: "a boolean"
			}
		}
	}

	/// Parses `text` over the defaults. Bad lines and values become warnings
	/// ("line 3: ...") and leave the default in place; nothing else is affected.
	static func parse(_ text: String) -> (values: SettingsValues, warnings: [String]) {
		var values = SettingsValues()
		var warnings: [String] = []
		var section: String?
		var skipping = false
		let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
		for (index, raw) in lines.enumerated() {
			func warn(_ message: String) { warnings.append("line \(index + 1): \(message)") }
			let line = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
			if line.isEmpty { continue }
			if line.hasPrefix("[") {
				guard line.hasSuffix("]") else {
					warn("malformed section header")
					section = nil
					skipping = true
					continue
				}
				let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
				if settings.contains(where: { $0.section == name }) {
					section = name
					skipping = false
				} else {
					warn("unknown section [\(name)]")
					section = nil
					skipping = true
				}
				continue
			}
			guard let equals = line.firstIndex(of: "=") else {
				warn("expected key = value")
				continue
			}
			if skipping { continue }
			let key = line[..<equals].trimmingCharacters(in: .whitespaces)
			guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
				warn("malformed key")
				continue
			}
			guard let section else {
				warn("key '\(key)' outside any section")
				continue
			}
			guard let value = parseValue(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)) else {
				warn("malformed value for '\(key)'")
				continue
			}
			if let problem = apply(value, key: key, section: section, to: &values) { warn(problem) }
		}
		return (values, warnings)
	}

	/// Cuts a trailing `#` comment, ignoring any `#` inside a string.
	private static func stripComment(_ line: String) -> String {
		var inString = false
		var escaped = false
		for index in line.indices {
			let character = line[index]
			if inString {
				if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
			} else if character == "\"" {
				inString = true
			} else if character == "#" {
				return String(line[..<index])
			}
		}
		return line
	}

	private static func parseValue(_ text: String) -> Value? {
		if text == "true" { return .bool(true) }
		if text == "false" { return .bool(false) }
		if text.hasPrefix("\"") {
			var result = ""
			var escaped = false
			var rest = text.dropFirst()
			while let character = rest.popFirst() {
				if escaped {
					switch character {
					case "n": result.append("\n")
					case "t": result.append("\t")
					case "\"", "\\": result.append(character)
					default: return nil
					}
					escaped = false
				} else if character == "\\" {
					escaped = true
				} else if character == "\"" {
					return rest.isEmpty ? .string(result) : nil
				} else {
					result.append(character)
				}
			}
			return nil
		}
		// Swift's Double parser also takes "nan", "inf" and hex floats; TOML doesn't.
		guard let first = text.first, first.isNumber || first == "-" || first == "+" || first == ".",
			text.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }),
			let number = Double(text), number.isFinite
		else { return nil }
		return .number(number)
	}

	/// One option: where it lives in the file, the environment variable that
	/// overrides it, and how it validates and stores a value. The file parser
	/// and the environment share these, and the known sections come from them.
	private struct Setting: Sendable {
		let section: String
		let key: String
		let env: String?
		/// Rewrites an environment string into the file's vocabulary.
		var translate: (@Sendable (String) -> String)?
		let set: @Sendable (Value, inout SettingsValues) -> String?
	}

	private static func choice<T: RawRepresentable & CaseIterable & Sendable>(
		_ section: String, _ key: String, env: String? = nil,
		translate: (@Sendable (String) -> String)? = nil,
		store: @escaping @Sendable (inout SettingsValues, T) -> Void
	) -> Setting where T.RawValue == String {
		Setting(section: section, key: key, env: env, translate: translate) { value, values in
			guard case .string(let name) = value else { return "'\(key)' expects a string, got \(value.kind)" }
			guard let match = T.allCases.first(where: { $0.rawValue == name }) else {
				return "'\(key)' must be one of \(T.allCases.map(\.rawValue).joined(separator: ", ")), got \"\(name)\""
			}
			store(&values, match)
			return nil
		}
	}

	private static func number(
		_ section: String, _ key: String, _ range: ClosedRange<Double>, env: String? = nil,
		store: @escaping @Sendable (inout SettingsValues, Double) -> Void
	) -> Setting {
		Setting(section: section, key: key, env: env, translate: nil) { value, values in
			guard case .number(let number) = value else { return "'\(key)' expects a number, got \(value.kind)" }
			guard range.contains(number) else { return "'\(key)' must be between \(range.lowerBound) and \(range.upperBound), got \(number)" }
			store(&values, number)
			return nil
		}
	}

	private static let settings: [Setting] = [
		choice("pill", "material", env: "AERONAUT_GLASS", translate: {
			switch $0 {
			case "1", "regular": "glass"
			case "clear": "clear-glass"
			default: $0
			}
		}) { $0.material = $1 },
		number("pill", "tint", 0...1, env: "AERONAUT_GLASS_TINT") { $0.tint = $1 },
		choice("pill", "border", env: "AERONAUT_BORDER") { $0.border = $1 },
		number("pill", "border-opacity", 0...1, env: "AERONAUT_BORDER_OPACITY") { $0.borderOpacity = $1 },
		choice("workspaces", "style", env: "AERONAUT_WORKSPACES") { $0.workspaces = $1 },
		choice("workspaces", "focus", env: "AERONAUT_FOCUS") { $0.focus = $1 },
		number("workspaces", "focus-opacity", 0...1, env: "AERONAUT_FOCUS_OPACITY") { $0.focusOpacity = $1 },
		number("workspaces", "focus-margin", SettingsValues.focusMarginRange, env: "AERONAUT_FOCUS_MARGIN") { $0.focusMargin = $1 },
		number("workspaces", "icon-size", SettingsValues.iconSizeRange, env: "AERONAUT_ICON_SIZE") { $0.iconSize = $1 },
		Setting(section: "workspaces", key: "accent", env: "AERONAUT_ACCENT", translate: nil) { value, values in
			guard case .string(let text) = value else { return "'accent' expects a string, got \(value.kind)" }
			guard let color = SettingsValues.accent(from: text) else {
				return "'accent' must be a Catppuccin colour name or #rrggbb / #aarrggbb, got \"\(text)\""
			}
			values.accent = color
			return nil
		},
		Setting(section: "workspaces", key: "focus-padding", env: "AERONAUT_FOCUS_PADDING", translate: nil) { value, values in
			switch value {
			case .string("auto"):
				values.focusPadding = nil
				return nil
			case .number(let number) where SettingsValues.focusPaddingRange.contains(number):
				values.focusPadding = number
				return nil
			case .number(let number):
				return "'focus-padding' must be \"auto\" or between 0.0 and 12.0, got \(number)"
			default:
				return "'focus-padding' must be \"auto\" or a number, got \(value.kind)"
			}
		},
		number("calendar", "icon-size", SettingsValues.calendarIconSizeRange, env: "AERONAUT_CALENDAR_ICON_SIZE") { $0.calendarIconSize = $1 },
		choice("text", "font", env: "AERONAUT_FONT") { $0.font = $1 },
	]

	/// Stores one value, or returns what's wrong with it.
	private static func apply(_ value: Value, key: String, section: String, to values: inout SettingsValues) -> String? {
		guard let setting = settings.first(where: { $0.section == section && $0.key == key }) else {
			return "unknown key '\(key)' in [\(section)]"
		}
		return setting.set(value, &values)
	}

	/// Applies the `AERONAUT_*` variables over `values`. Each is read as a TOML
	/// scalar and validated like its file key; a bad one is returned as a
	/// warning and leaves the file's or the default value in place.
	static func apply(environment: [String: String], to values: SettingsValues) -> (values: SettingsValues, warnings: [String]) {
		var values = values
		var warnings: [String] = []
		for setting in settings {
			guard let name = setting.env, let raw = environment[name] else { continue }
			let text = setting.translate?(raw) ?? raw
			let value = parseValue(text) ?? .string(text)
			var attempt = values
			if let problem = setting.set(value, &attempt) {
				warnings.append("\(name): \(problem)")
			} else {
				values = attempt
			}
		}
		return (values, warnings)
	}
}
