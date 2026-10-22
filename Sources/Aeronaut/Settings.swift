import Foundation
import Observation

/// The live options. Views read them in `body`, directly or through the
/// `Theme` accessors, so a reload re-renders whatever depends on what changed.
@MainActor
@Observable
final class Settings {
	static let shared = Settings()

	private(set) var values = SettingsValues()

	var material: PillMaterial {
		let tint = values.tint
		switch values.material {
		case .flat:
			return .flat
		case .frost:
			return .frost(tint: tint ?? Theme.frostTintOpacity)
		case .glass:
			guard #available(macOS 26, *) else { return .flat }
			return .glass(.regular, tint: tint ?? Theme.glassTintOpacity)
		case .clearGlass:
			guard #available(macOS 26, *) else { return .flat }
			return .glass(.clear, tint: tint ?? Theme.glassTintOpacity)
		}
	}

	var border: PillBorder {
		switch values.border {
		case .none: .none
		case .neutral: .neutral
		case .accent: .accent(opacity: values.borderOpacity ?? Theme.borderAccentOpacity)
		}
	}

	/// Reads the config file (if any), then the environment, over the defaults.
	/// Warnings go to stderr.
	func reload(path: String = ConfigWatcher.configPath()) {
		var next = SettingsValues()
		if let text = try? String(contentsOfFile: path, encoding: .utf8) {
			let (parsed, warnings) = ConfigParser.parse(text)
			for warning in warnings {
				FileHandle.standardError.write(Data("aeronaut: \(path):\(warning)\n".utf8))
			}
			next = parsed
		}
		let (overridden, warnings) = ConfigParser.apply(environment: ProcessInfo.processInfo.environment, to: next)
		for warning in warnings {
			FileHandle.standardError.write(Data("aeronaut: \(warning)\n".utf8))
		}
		next = overridden
		if next != values { values = next }
	}
}
