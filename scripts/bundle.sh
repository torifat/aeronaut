#!/usr/bin/env bash
# Builds Aeronaut.app, signs it ad-hoc and zips it. Used by local builds and CI.
set -euo pipefail

usage() {
	cat <<'U'
Usage: scripts/bundle.sh --version X.Y.Z [--binary PATH] [--out DIR]

  --version X.Y.Z  App version (required)
  --binary PATH    Prebuilt executable, such as CI's universal binary.
                   Without it, runs `swift build -c release` for this machine.
  --out DIR        Output directory (default: dist)

Writes DIR/Aeronaut.app and DIR/Aeronaut-<version>.zip.
U
}

version="" binary="" out="dist"
while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) version="${2:?--version needs a value}"; shift 2 ;;
		--binary) binary="${2:?--binary needs a value}"; shift 2 ;;
		--out) out="${2:?--out needs a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done
[[ -n "$version" ]] || { echo "--version is required" >&2; usage >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if [[ -z "$binary" ]]; then
	swift build -c release
	binary="$(swift build -c release --show-bin-path)/Aeronaut"
fi
[[ -x "$binary" ]] || { echo "binary not found: $binary" >&2; exit 1; }

app="$out/Aeronaut.app"
zip="$out/Aeronaut-$version.zip"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rm -rf "$app" "$zip"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$binary" "$app/Contents/MacOS/Aeronaut"
cp Sources/Aeronaut/Resources/icon_map.json "$app/Contents/Resources/icon_map.json"

swift scripts/icon.swift "$tmp"
cp "$tmp/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>dev.rifat.aeronaut</string>
	<key>CFBundleName</key><string>Aeronaut</string>
	<key>CFBundleDisplayName</key><string>Aeronaut</string>
	<key>CFBundleExecutable</key><string>Aeronaut</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$version</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSUIElement</key><true/>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSCalendarsFullAccessUsageDescription</key><string>Aeronaut shows your next calendar event in the menu bar.</string>
</dict>
</plist>
P
plutil -lint "$app/Contents/Info.plist"

# Ad-hoc, without the hardened runtime: Calendar access then needs no entitlement.
codesign --force --deep --sign - "$app"
codesign --verify --strict "$app"

ditto -c -k --keepParent "$app" "$zip"
echo "App: $app"
echo "Zip: $zip"
echo "SHA-256: $(shasum -a 256 "$zip" | cut -d' ' -f1)"
