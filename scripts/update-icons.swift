// Updates the bundled app icons from a sketchybar-app-font release: the name-to-icon map and the font.
//
// Run from the repo root (needs the Command Line Tools toolchain, see AGENTS.md):
//   swift scripts/update-icons.swift [TAG]
// TAG is a release tag such as v3.0.11 or 3.0.11, and defaults to the latest release. Set GITHUB_TOKEN
// to authenticate the release lookup against the GitHub API's rate limit.
// Downloads icon_map.json and sketchybar-app-font.ttf from github.com/kvndrsslr/sketchybar-app-font,
// checks their SHA-256 digests, checks that every icon in the map resolves to one glyph in the font,
// then writes both files and sketchybar-app-font.version into Sources/Aeronaut/Resources/.

import CoreText
import CryptoKit
import Foundation

let repo = "kvndrsslr/sketchybar-app-font"
let fontName = "sketchybar-app-font"
let resources = URL(fileURLWithPath: #filePath)
	.deletingLastPathComponent().deletingLastPathComponent()
	.appendingPathComponent("Sources/Aeronaut/Resources")

func fail(_ message: String, _ code: Int32) -> Never {
	FileHandle.standardError.write(Data((message + "\n").utf8))
	exit(code)
}

struct Entry: Decodable {
	let iconName: String
	let appNames: [String]
}

struct Asset: Decodable {
	let name: String
	let browserDownloadURL: URL
	let digest: String?
	enum CodingKeys: String, CodingKey {
		case name, digest
		case browserDownloadURL = "browser_download_url"
	}
}

struct Release: Decodable {
	let tagName: String
	let assets: [Asset]
	enum CodingKeys: String, CodingKey {
		case assets
		case tagName = "tag_name"
	}
}

/// Only API requests carry the token. Asset downloads don't count against the
/// API rate limit, and they redirect off api.github.com.
func fetch(_ url: URL, api: Bool = false) async -> Data {
	var request = URLRequest(url: url)
	if api {
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty {
			request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}
	}
	do {
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse else { fail("\(url): not an HTTP response", 1) }
		switch http.statusCode {
		case 200: return data
		case 404: fail("\(url): not found (404). Check the tag.", 1)
		case 403, 429: fail("\(url): HTTP \(http.statusCode), probably rate limited. Set GITHUB_TOKEN.", 1)
		default: fail("\(url): HTTP \(http.statusCode)", 1)
		}
	} catch {
		fail("\(url): \(error.localizedDescription)", 1)
	}
}

func sha256(_ data: Data) -> String {
	SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Downloads a release asset and checks it against the digest GitHub reports for it.
func download(_ name: String, from release: Release) async -> Data {
	guard let asset = release.assets.first(where: { $0.name == name }) else {
		fail("release \(release.tagName) has no asset named \(name)", 1)
	}
	let data = await fetch(asset.browserDownloadURL)
	if let digest = asset.digest {
		guard digest.hasPrefix("sha256:") else { fail("\(name): unsupported digest \(digest)", 1) }
		let expected = String(digest.dropFirst("sha256:".count))
		let actual = sha256(data)
		guard actual == expected else { fail("\(name): SHA-256 mismatch, expected \(expected) but got \(actual)", 1) }
	} else {
		FileHandle.standardError.write(Data("warning: \(name) has no digest, so it is not verified\n".utf8))
	}
	return data
}

func readEntries(_ url: URL) -> [Entry]? {
	guard let data = try? Data(contentsOf: url) else { return nil }
	return try? JSONDecoder().decode([Entry].self, from: data)
}

func appNames(_ entries: [Entry]) -> Set<String> {
	Set(entries.flatMap(\.appNames))
}

// MARK: Fetch

var tag = "latest"
let args = Array(CommandLine.arguments.dropFirst())
if args.contains("-h") || args.contains("--help") {
	print("usage: swift scripts/update-icons.swift [TAG]   (TAG: v3.0.11 or 3.0.11, default: latest release)")
	exit(0)
}
if args.count > 1 { fail("usage: swift scripts/update-icons.swift [TAG]", 2) }
if let arg = args.first {
	tag = "tags/" + (arg.hasPrefix("v") ? arg : "v" + arg)
}

let releaseURL = URL(string: "https://api.github.com/repos/\(repo)/releases/\(tag)")!
let release: Release
do {
	release = try JSONDecoder().decode(Release.self, from: await fetch(releaseURL, api: true))
} catch {
	fail("could not read the release from \(releaseURL): \(error)", 1)
}
let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName

let mapData = await download("icon_map.json", from: release)
let fontData = await download("sketchybar-app-font.ttf", from: release)

// MARK: Validate

let entries: [Entry]
do {
	entries = try JSONDecoder().decode([Entry].self, from: mapData)
} catch {
	fail("icon_map.json does not decode as [{iconName, appNames}]: \(error)", 1)
}
guard !entries.isEmpty else { fail("icon_map.json is empty", 1) }
guard entries.contains(where: { $0.iconName == ":default:" }) else { fail("icon_map.json has no :default: icon", 1) }

guard let descriptor = CTFontManagerCreateFontDescriptorFromData(fontData as CFData) else {
	fail("sketchybar-app-font.ttf does not load as a font", 1)
}
let postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
guard postScriptName == fontName else {
	fail("font PostScript name is \(postScriptName ?? "missing"), expected \(fontName)", 1)
}

// An icon resolves when its ligature shapes to a single glyph.
let font = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
let unresolved = entries.map(\.iconName).filter { name in
	let text = NSAttributedString(string: name, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
	return CTLineGetGlyphCount(CTLineCreateWithAttributedString(text)) != 1
}
guard unresolved.isEmpty else {
	fail("\(unresolved.count) icons in the map do not resolve to one glyph in the font:\n  " + unresolved.joined(separator: "\n  "), 1)
}

// MARK: Write

let mapURL = resources.appendingPathComponent("icon_map.json")
let ttfURL = resources.appendingPathComponent("sketchybar-app-font.ttf")
let versionURL = resources.appendingPathComponent("sketchybar-app-font.version")

let oldEntries = readEntries(mapURL) ?? []
let oldVersion = (try? String(contentsOf: versionURL, encoding: .utf8))?
	.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"

do {
	try mapData.write(to: mapURL, options: .atomic)
	try fontData.write(to: ttfURL, options: .atomic)
	try Data((version + "\n").utf8).write(to: versionURL, options: .atomic)
} catch {
	fail("could not write into \(resources.path): \(error)", 1)
}

// MARK: Summary

let oldNames = appNames(oldEntries)
let newNames = appNames(entries)
let removed = oldNames.subtracting(newNames).sorted()
print("version:   \(oldVersion.isEmpty ? "unknown" : oldVersion) -> \(version)")
print("icons:     \(oldEntries.count) -> \(entries.count)")
print("app names: \(oldNames.count) -> \(newNames.count), \(newNames.subtracting(oldNames).count) added, \(removed.count) removed")
if !removed.isEmpty {
	print("removed (these fall back to :default: unless renamed):")
	for name in removed { print("  \(name)") }
}
