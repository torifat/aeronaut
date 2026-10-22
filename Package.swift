// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Aeronaut",
	platforms: [.macOS(.v14)],
	targets: [
		.executableTarget(
			name: "Aeronaut",
			resources: [.copy("Resources/icon_map.json")]
		),
	]
)
