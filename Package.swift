// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Aeronaut",
	platforms: [.macOS(.v14)],
	targets: [
		.executableTarget(
			name: "Aeronaut",
			exclude: ["Resources/sketchybar-app-font.version"],
			resources: [
				.copy("Resources/icon_map.json"),
				.copy("Resources/sketchybar-app-font.ttf"),
			]
		),
	]
)
