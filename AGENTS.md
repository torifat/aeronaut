# Aeronaut: notes for contributors and coding agents

Aeronaut is a SwiftUI status bar for macOS and [AeroSpace](https://github.com/nikitabobko/AeroSpace). It draws two floating pills in the menu bar row, one for workspaces and one for the next calendar event, and puts most of its care into motion. It started as a replacement for a sketchybar setup. Sketchybar's tweens break when an item's icon string changes, so a focused app and an unfocused app couldn't look different while the pill animated.

Read this before changing anything. It records why things are the way they are, including approaches that were tried and dropped.

## Working agreements

- Ask the maintainer before any git commit, push, tag or release. Commits use the repo-local git identity, so don't override it.
- Keep the build free of warnings. The package builds in Swift 6 language mode with strict concurrency.
- Check visual changes with `--snapshot`, or with a live capture when snapshots can't show the thing (see below). Ask a human to judge motion.

## Build and verify

The Command Line Tools toolchain (Swift 6.4 or later) is enough, and Xcode isn't needed. If `xcode-select` points at an SDK with no Swift stdlib for this target, a Nix SDK for example, set the toolchain explicitly:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
swift build
swift run Aeronaut                      # live bar, Ctrl-C to quit
swift run Aeronaut --snapshot pill.png  # render every pill state once and exit
```

Quirks of this toolchain:
- **Sandboxes:** in sandboxed agent environments, `swift build` and the Swift scripts can fail because xcrun can't write its cache under `/var/folders`. Run them unsandboxed.
- **Linker warning:** the linker warns that `Developer/usr/lib` and `Developer/Library/Frameworks` are missing. Those are Xcode-only XCTest paths, so the warning is harmless.
- **No `@State`.** In current SDKs it's a macro, and the Command Line Tools ship without the `SwiftUIMacros` plugin ("external macro implementation type 'SwiftUIMacros.StateMacro' could not be found"). Hold view state in an `ObservableObject` with `@StateObject`, as `NextEventPill` does. `@Entry` and `@Previewable` are affected too. `@Observable` works, because its macro plugin ships with Swift.
- **No `if flag, #available(macOS 26, *)` in a `@ViewBuilder`.** It crashes the compiler with "failed to produce diagnostic". Nest the checks (`if flag { if #available … }`) and move each branch into its own helper.

### Snapshots

`--snapshot` renders from live AeroSpace state, falling back to `Snapshot.sample`. It adds the calendar pill in every state, plus frozen frames of the focus slide, and writes a PNG.
- It renders through `NSHostingView.cacheDisplay`, as the live bar does. `ImageRenderer` doesn't clip glyphs that overflow their advance, so it hides bugs like the cropped calendar icon.
- `cacheDisplay` draws small vertical ticks at the rounded ends of pill borders. They only appear in snapshots.
- Snapshots always render the flat material. Frost and glass composite what's behind the window, so an offscreen render can't show them.

### Live captures

To check materials or exact geometry on screen, launch the built binary with the settings you want, wait about 5 s, run `screencapture -x -R0,0,330,36 out.png` for the left pill (or `-R<x>,0,<w>,36` for the right one), then kill it.
- The terminal running the commands needs Screen Recording permission.
- macOS draws a purple recording dot near the top-right corner while capturing. It isn't part of Aeronaut.
- Make sure no other Aeronaut is running, or you'll capture two bars on top of each other.

### Reproducing AeroSpace behaviour

Point `AERONAUT_AEROSPACE` at a fake `aerospace` script. It answers `list-workspaces` and `list-windows` (with `--json`) with canned JSON, and makes `subscribe --all` print scripted events. That reproduces timing bugs, such as the focus rebound below, without touching anyone's real workspaces. To see what real AeroSpace sends, record `aerospace subscribe --all` while pressing the bindings.

## How it works

| File | What it does |
| --- | --- |
| `main.swift` | Entry point. Handles `--snapshot`, otherwise sets the accessory activation policy and runs the app |
| `AppDelegate.swift` | Creates and places the left and right panels and re-places them when screens change |
| `PillPanel.swift` | Borderless, non-activating `NSPanel` hosting SwiftUI. Registers itself with `MenuBarWatcher` |
| `MenuBarWatcher.swift` | Fades every `PillPanel` out while the auto-hidden menu bar is showing |
| `AeroSpace.swift` | Models, the CLI client, and the event stream |
| `WorkspaceStore.swift` | `@Observable` workspace state. Applies events, absorbs focus flicker, coalesces refreshes |
| `WorkspacesPill.swift` | The workspace pill and the compact style. `AppIcon` is the single place for icon styling |
| `AllWorkspaces.swift` | The experimental "all" style, where every workspace shows its icons and the highlight is masked |
| `SlidingHighlight.swift` | The pill-level focus highlight and its spring slide (`SlideMotion`, `SlideState`, `ItemBounds`) |
| `HoverTracker.swift` | Hover tracking that works in a never-active panel, plus the `Hoverable` wrapper |
| `PressStyle.swift` | A button style with no chrome: shrinks while pressed and springs back |
| `NextEvent.swift` | Calendar models, and the pure label and colour logic in `CalendarState` |
| `CalendarStore.swift` | `@Observable` EventKit state. Finds the next event and refreshes on the minute |
| `NextEventPill.swift` | The calendar pill: collapse and expand, countdown ring, `PillOutline` |
| `Config.swift` | The config keys (one table: section, key, env var, validation), `SettingsValues` defaults, and the TOML-subset parser |
| `Settings.swift` | `Settings.shared`, the `@Observable` store every view reads its look from |
| `ConfigWatcher.swift` | Watches the config directory and reloads on save, debounced by 100 ms |
| `Theme.swift` | Catppuccin Mocha colours, fonts, sizes, materials (`pillBackground`) and animation constants |
| `AppIcons.swift` | App name to sketchybar-app-font ligature, from `Resources/icon_map.json`. Loads the bundled font and measures ink widths |
| `Snapshot+Render.swift` | Sample data and the PNG renderer |

### AeroSpace integration

- Aeronaut talks to AeroSpace only through the `aerospace` CLI. It looks for the binary in `AERONAUT_AEROSPACE`, then `PATH`, then the usual Nix and Homebrew locations. A launchd agent's `PATH` is minimal, so packages should set `AERONAUT_AEROSPACE`.
- `aerospace subscribe --all` prints one JSON object per line. The events used are:
  - `focused-workspace-changed`, with `workspace` and `prevWorkspace`
  - `focus-changed`, with `windowId` and `workspace`
  - `focused-monitor-changed`
  - `mode-changed`

  The stream restarts 2 seconds after AeroSpace exits.
- **Focus events** update the focus at once, so the highlight moves with no CLI round trip. Every event then triggers a refresh from `list-workspaces` and `list-windows` with `--json`. Refreshes are coalesced, so a burst of events costs at most one extra run.
- **A safety refresh** also runs every 5 seconds, to catch changes AeroSpace has no event for, such as a background window closing.
- **Window order:** `list-windows` output is sorted by app name, then window title, whatever the layout. So icons appear in that order rather than layout order; see "Known limitation" below.

#### Focus rebound with Chromium apps

When AeroSpace focuses a Chromium-based app (Chrome, Arc, Edge, also VS Code), focus can bounce back to the previous window and forward again. The stream shows `focused-workspace-changed` going 4→1, 1→4, then 4→1 within about 65 ms, with matching `focus-changed` events.
- **Why:** AeroSpace takes macOS's word for which window is focused, and Chromium re-keys its windows or activates slowly. See AeroSpace discussion #1375 and issues #1097 and #101.
- **Upstream workaround:** turning off "Displays have separate Spaces" is the usual workaround.

Applied naively, the bounce restarted the capsule slide mid-flight and made it jump. `WorkspaceStore` absorbs it:
- **Hold window:** a focus change shows at once, then further focus updates are held for 100 ms. The latest is applied only if it differs. So a bounce never shows, and normal switches get no added latency.
- **Window id:** `focusedWindowID` changes only when a `focus-changed` event actually supplied one.
- **Refreshes:** the event-triggered refresh waits for the hold to close. A refresh that began before the latest focus event (tracked by `focusGeneration`) applies its windows but keeps the shown focus, then reruns once. A slow CLI read can't put the old workspace back, and constant focus changes can't starve window updates.

Keep the hold even if upstream is fixed, because other apps can rebound focus too.

### Panel placement

- **Level:** each panel sits in the menu bar row, at `NSWindow.Level.mainMenu - 1`, so an auto-hidden menu bar slides over it. Its collection behaviour is `canJoinAllSpaces`, `stationary`, `ignoresCycle` and `fullScreenAuxiliary`.
- **`constrainFrameRect`** is overridden to return the requested frame. Without it, AppKit pushes the panel below the notch's safe area (32 pt on a notched built-in display), under the menu bar.
- **Width:** the left panel is as wide as `auxiliaryTopLeftArea` (everything left of the notch), and the right one as `auxiliaryTopRightArea`, pinned to the right edge. Displays without a notch get half the screen width each. Clicks on transparent pixels should fall through to what's underneath, but nobody has tested that deliberately.
- **Height:** the bar is 34 pt tall and the pills are 30 pt (`Theme.pillHeight`). AeroSpace's default top outer gaps leave room for it.

### Hiding under the menu bar

The menu bar is transparent on macOS 26, so when the auto-hidden menu bar slides in, the pills would show through behind its titles and status items. `MenuBarWatcher` fades them out (alpha 0 over 0.2 s, with `ignoresMouseEvents` on) and fades them back once it has hidden again.
- **Detection:** nothing notifies an app when the menu bar is revealed, and `NSMenu.menuBarVisible()` always returns false. Instead, the watcher reads the frame of the Window Server window named "Menubar" (layer 24, one per display).
  - While hidden it sits just above the screen, at Y = −33 with height 33 on a notched built-in display. It counts as showing once it has moved more than 1 pt down.
  - The watcher reads that one window with `CGWindowListCreateDescriptionFromArray` and caches its ID. It looks the ID up again when the read fails or the screens change.
- **Polling:** 30 Hz while the cursor is in the top 40 pt of a screen or the menu bar is showing, 1 Hz otherwise. A global `mouseMoved` monitor starts the fast polling. Mouse monitors need no Accessibility permission.
- **Known gaps:**
  - With the menu bar set to always show, the pills stay faded.
  - Reveals that don't come from the mouse, such as keyboard menu access, are only caught by the 1 Hz poll.
  - It hasn't been tried with more than one display.

### Configuration

Aeronaut must look right with no config file at all. The file only overrides the defaults in `SettingsValues`.
- **Location and format:** `~/.config/aeronaut/config.toml`, or `$XDG_CONFIG_HOME/aeronaut/config.toml`. It's read by a small, dependency-free parser for the TOML subset needed: sections, `key = value`, strings, numbers, booleans and comments.
- **Live reload:** saving updates the bar immediately. `ConfigWatcher` watches the directory, so atomic saves (write a temp file, then rename) work. It copes with the file or directory not existing yet. While it waits on an ancestor directory, it reacts only when the next expected path component appears.
- **Bad lines** print `aeronaut: <path>:line N: …` to stderr, and that value falls back to its default.
- **Precedence:** defaults, then the file, then `AERONAUT_*` env vars.
  - Each key is defined once in `Config.swift`'s table with its section, env var name and validation, so the file and env can't drift.
  - An invalid env value warns, naming the variable, and is ignored.
  - `AERONAUT_GLASS` keeps its historic values: `1`, `regular`, `clear`, `frost` and `flat`.

| Section | Key | Values (default first) |
| --- | --- | --- |
| `[pill]` | `material` | `frost`, `flat`, `glass`, `clear-glass` |
| `[pill]` | `tint` | 0 to 1 (frost 0.45, glass 0.55) |
| `[pill]` | `border` | `accent`, `neutral`, `none` |
| `[pill]` | `border-opacity` | 0 to 1 (0.6) |
| `[workspaces]` | `style` | `compact`, `all` |
| `[workspaces]` | `focus` | `translucent`, `solid`, `glossy`, `tint`, `outline`, `underline` |
| `[workspaces]` | `focus-opacity` | 0 to 1 (0.75) |
| `[workspaces]` | `focus-margin` | 0 to 6 (4): the gap between the capsule and the pill's edge |
| `[workspaces]` | `focus-padding` | `"auto"`, or 0 to 12 |
| `[workspaces]` | `accent` | A Catppuccin Mocha name (`green`, then rosewater to lavender) or `"#rrggbb"` / `"#aarrggbb"` |
| `[workspaces]` | `icon-size` | 12 to 20 (16) |
| `[text]` | `font` | `pixel`, `rounded`, `mono`, `sf` |
| `[calendar]` | `icon-size` | 12 to 22 (17) |

### Visuals

The palette is Catppuccin Mocha. Colour only appears where it means something: the accent (green by default) marks focus, and yellow and red mark calendar urgency.

**Pills**
- Each pill is 30 pt tall.
- **Material:** the default is **frost**, an `NSVisualEffectView` (`.hudWindow`, `.behindWindow`, `state = .active`) clipped to the pill. A dark tint of `Theme.frostTintOpacity` (0.45) sits over the blur, under a hand-drawn rim: a white gradient from 0.35 at the top to 0.06 at the bottom, plus a faint inner highlight. Below about 0.3 tint, frost over a plain wallpaper reads as just its rim, like an outline.
- **Border:** the default is **accent**: the workspace pill's accent colour, or the calendar pill's state tint, at 0.6.
- **Liquid Glass (`glass`, `clear-glass`, macOS 26)** is kept only as an experiment. In a panel that never becomes key, every variant (tinted or not, regular or clear) renders as a flat translucent shape with no specular rim. `NSGlassEffectView` has no public way to force the active state, unlike `NSVisualEffectView.state`. Prefer frost unless Apple adds such an API.

**Workspace pill**
- **What's shown:** each workspace that has windows, plus the focused one.
- **Unfocused numbers** are Pixel Code 14 in `Theme.grey` (overlay1, 4.4:1 contrast). They're deliberately subdued, because they orient rather than inform, and brighter numbers read as noise. Don't brighten them.
- **The focused workspace** shows its app icons on the accent capsule, without its number: the capsule already marks it. An empty focused workspace shows its number in the capsule instead. The number scales and fades out as the capsule arrives, and stays grey meanwhile, so it never flashes dark.
- **Icons:** the bundled sketchybar-app-font, 16 pt by default. The focused window's icon is drawn at full opacity and the rest at 0.4.
  - Every glyph in this font advances about 1.41 em but draws within the first em, and some, such as Ghostty, draw in less. `AppIcons.inkWidth(of:)` measures each glyph once with CoreText, cached per size, and `AppIcon` is boxed to that width, so spacing is even.
  - Icons are 6 pt apart.
- **Capsule geometry:**
  - The capsule is `Theme.focusHeight` tall: the pill height minus twice `focus-margin`.
  - With `focus-padding = auto`, its sides are padded by the same amount as its top and bottom, so a single icon sits in a circle at any margin.
  - **Anchor gotcha:** the capsule's rect comes from an `ItemBounds` anchor on a view with an explicit frame. Don't anchor a padded view: padding enlarges the anchored bounds rather than insetting them, so the capsule would fill the whole item.
- **Capsule fill:** the default focus style is `translucent`, the accent at 0.75 opacity. Fully opaque pastel looks pasted on, and below about 0.65 the colour turns grey and the dimmed icons vanish. `solid`, `glossy`, `tint`, `outline` and `underline` are experiments.
- **Hover:** hovering an unfocused number brightens it and fades in a surface0 ghost capsule with the same geometry, previewing where focus would go. Hovering a dimmed icon in the capsule raises it to 0.7.
- **Buttons:** workspace items, icons and the calendar pill are `Button`s with `PressStyle`, which scales to 0.92 and springs back. Buttons are never nested. In the compact style, an unfocused item is just its number and the focused item is just its icons. No hover or press effect changes a width, so click targets never move under the cursor. That's also why hover doesn't reveal the focused number.
- **Clicks:** a number runs `aerospace workspace N`, and an icon runs `aerospace focus --window-id ID`.

**Focus motion**
- The capsule slides as one piece on `Theme.focusSpring` (`Spring(duration: 0.38, bounce: 0.2)`). It's a single highlight drawn behind the items (`SlidingHighlight`).
- **How a slide works:** when focus changes, `SlideState` records the rect on screen and the time. Each frame draws `mix(start, liveTarget, progress)`, with progress taken from the spring's analytic curve, `spring.value(target: 1, time: elapsed)`.
  - Progress isn't clamped, so values past 1 overshoot.
  - The target is resolved from the anchors on every frame, so the capsule lands correctly while the items are still re-laying out.
  - Width changes that aren't focus changes just ease.
  - A retarget mid-flight starts from wherever the capsule is.
  - A `TimelineView` with a finite schedule ticks at 120 Hz only until the spring settles.
- **Reduce Motion** removes the bounce. `SlideFreeze` is a snapshot-only hook that renders frames at fixed times.
- **Don't use `keyframeAnimator` for this.** When its trigger changes while a run is still settling, it keeps delivering the old run's tail values (for example 1.011 or 0.9998) instead of restarting at 0. Combined with the focus rebound, that made the capsule jump.
- **Rejected:** a water-drop motion, where the front edge led, the tail followed 70 ms later and the height squashed, was hard to notice in practice.
- **Layout animation:** `.smooth(duration: 0.35)` at the pill root, keyed on the whole `Snapshot`. The highlight opts out and runs its own motion.

**The "all" style** (`[workspaces] style = "all"`) is experimental. Every visible workspace shows its number and icons in grey, and the focused one sits on the capsule. Widths don't depend on focus, so only the capsule moves.
- Content is dark exactly where the capsule is, pixel for pixel, even mid-slide. That's done with three copies of the content:
  - an invisible copy that owns the layout and reports bounds
  - a grey copy that takes taps, with the capsule cut out of it
  - a dark copy masked to the capsule
- One rect source (`HighlightCapsule`, sharing `SlideMotion.rect`) drives the fill and both masks.
- `HighlightSlide` renders the capsule partway between two workspaces for snapshots.

### Calendar pill

- **What it shows:** the next timed event that hasn't started, looking up to 30 days ahead. All-day, cancelled and declined events are skipped. The full label is `<when> • <title>`:
  - `when` is "in <1m", "in Nm", "in Nh" (hours rounded down), or "EEE HH:mm" from 24 hours out.
  - The title is truncated to 28 characters (graphemes, so emoji survive) plus "…".
  - With nothing coming up, or without Calendar access, it shows "No events".
- **Countdown:** measured from the start of the current minute, which rounds the time left up. An event at 10:05 reads "in 5m" at 10:00 and "in 1m" in its last minute. "in <1m" only appears for events that don't start on a whole minute.
- **Refresh:** on `EKEventStoreChanged`, on wake, and on a timer aligned to the minute boundary.
- **Collapsed by default:** icon and time, or just the icon with no events. It expands to the full label:
  - while hovered, and for 1 s after
  - while the event is 5 minutes away or less
  - for a 4 s peek when the next event changes, keyed on start and title so minute ticks don't trigger it ("No events" never peeks)
- **Hover** comes from `HoverTracker`, an `NSTrackingArea` with `.activeAlways`, because SwiftUI's `onHover` may not fire in a panel of an app that's never active. While the cursor is inside, it also checks the cursor position every 0.2 s, because exits can be missed while the panel is ignoring mouse events.
- **Glyph:** U+F00F6 in "Liga SFMono Nerd Font" (Pixel Code lacks it), 17 pt by default. A smaller glyph makes the pill look shorter than the workspace pill, even though both are 30 pt.
  - The glyph's ink is wider than its advance, and the live `NSHostingView` clips text to its advance. `.tracking(Theme.symbolOverhang)` widens the Text to fit, with the overhang measured with CoreText for the current size (1.85 pt at 14, 2.24 pt at 17). `.frame(width:)` doesn't help, because the Text still clips to its own bounds.
- **State colours** show in the glyph and the accent border: blue at rest, yellow at 5 minutes or less, red at 1 minute or less. The label is Catppuccin text, and the " • " separator overlay1.
- **Countdown ring:** while urgent, the border becomes a ring that drains clockwise from twelve o'clock, like a clock hand.
  - `PillOutline` is a capsule path starting at the top centre, drawn with `trim(from: 1 - fraction, to: 1)`.
  - The ring is drawn over a neutral track, never over the accent border, or the drained part would stay tinted.
  - `CountdownSchedule` drives a `TimelineView` once a second, only while urgent, with a 1 s linear trim animation between ticks.
  - The pill pulses once (to 1.05 scale, about 0.6 s) when it turns red.
- **Clicking** opens Calendar.app.
- **Permission:** `requestFullAccessToEvents` (macOS 14). Under `swift run`, macOS asks the terminal for Calendar access. A bundled app needs `NSCalendarsFullAccessUsageDescription`.

### App icon

A green blimp: the app's pill as an airship. Its gondola is a tiny workspace pill with a green focused dot, under a moonlit night sky.
- What makes it read is a solid, lit object with a crisp silhouette: cylindrical shading, a teal bounce rim underneath, a dark contour and a rim light. Keep those if you touch the art.
- The tail has top and bottom fins only.
- `scripts/icon.swift` draws it in CoreGraphics on Apple's continuous-corner 824 pt squircle. Run `swift scripts/icon.swift <outdir>` to write `AppIcon.iconset/`, `AppIcon.icns` and `AppIcon-1024.png`. Generated icons are gitignored, and the bundle step generates them.

### Icon map and font

`Resources/icon_map.json` and `Resources/sketchybar-app-font.ttf` come from the same [sketchybar-app-font](https://github.com/kvndrsslr/sketchybar-app-font) release. The font is CC0, so it can ship in the app. `Resources/sketchybar-app-font.version` records which release it is.
- **Updating:** `swift scripts/update-icons.swift [TAG]` pulls the latest release, or TAG (`v3.0.12` or `3.0.12`). Before it replaces anything, it checks each download against the SHA-256 digest GitHub lists for it, and checks that every icon in the map resolves to a single glyph in the font. It then prints the old and new versions and any app names the new map dropped. Set `GITHUB_TOKEN` if the API rate-limits you.
- **The app only uses the bundled font.** `AppIcons` builds the icon font from the bundled file. It also registers that file for the process, so a lookup by name finds it before any installed copy. An installed copy can be any version, and when it's older than the map, icons it lacks don't render as icons.
- **Default icon:** an app missing from the map shows `:default:`. Upstream adds apps often, so updating may be enough.
- **Weekly PR:** `.github/workflows/update-icons.yml` runs the script every Monday, and on demand with an optional tag. When the release has changed, it force-pushes the `update-icons` branch and opens a PR, or updates the one already open, so a single PR tracks the newest release. The PR body is the script's summary. The repo setting "Allow GitHub Actions to create and approve pull requests" has to be on, otherwise the push works but opening the PR fails.

## Known limitation: window order

Icons appear in app-name order, not layout order, because AeroSpace sorts `list-windows` output by app name and then window title, whatever the layout (as of 0.21.3).

Two workarounds were ruled out:
- **Sorting by on-screen frame.** It works for tiles, but accordion layouts have padding offsets that aren't in order and tie with four or more windows.
- **`focus --dfs-index`,** which steals focus.

Upstream discussion is in nikitabobko/AeroSpace#491, with PRs #1932 (`--sort`) and #1958 (`get-tree`). If AeroSpace ever outputs tree order, Aeronaut needs no change, because `Dictionary(grouping:)` keeps the order within each workspace.

## Roadmap

### 1. App bundle (implemented)

`scripts/bundle.sh --version X.Y.Z [--binary PATH] [--out DIR]` is the one bundling script, used by local builds and CI. Without `--binary` it runs `swift build -c release` for the native architecture. It writes `DIR/Aeronaut.app` (default `dist/`, which is gitignored) and `DIR/Aeronaut-<version>.zip`, then prints the zip's SHA-256.
- **Contents:** `Contents/Info.plist`, `Contents/MacOS/Aeronaut`, `Contents/Resources/icon_map.json`, `Contents/Resources/sketchybar-app-font.ttf` and `Contents/Resources/AppIcon.icns`, generated by `scripts/icon.swift`.
- **`Info.plist`:** `CFBundleIdentifier` `dev.rifat.aeronaut`, `CFBundleIconFile` `AppIcon`, `LSUIElement` true, `LSMinimumSystemVersion` 14.0, `NSCalendarsFullAccessUsageDescription`, and the version for `CFBundleShortVersionString` and `CFBundleVersion`. It's checked with `plutil -lint`.
- **Signing:** ad-hoc (`codesign --force --deep --sign -`), then `codesign --verify --strict`. It doesn't use the hardened runtime, which would need the `com.apple.security.personal-information.calendars` entitlement for Calendar access. There's no notarization.
- **Resources:** `Bundle.module` won't work in a signed `.app`. SwiftPM's generated accessor looks for `Aeronaut_Aeronaut.bundle` at the `.app` root, and codesign rejects anything there. `AppIcons` loads `icon_map.json` and the font from `Bundle.main` first and only falls back to `Bundle.module` for `swift run`. `Bundle.module` calls `fatalError` when it can't find its bundle, so the `Bundle.main` check has to come first. Keep any new resource lookup the same way.

### 2. Release CI (implemented)

`.github/workflows/release.yml` runs on pushed `v*` tags, with `contents: write`.
- **Runner:** `macos-26` (arm64), with Xcode 26.6 selected explicitly through `xcode-select`. That's Swift 6.3.3, older than a current Command Line Tools install (6.4), so don't use language features newer than CI's compiler. v0.1.0 built cleanly on it. The code uses macOS 26 SDK APIs (Liquid Glass) behind `#available`, so it needs Xcode 26 to compile. The log prints `swift --version` and `xcodebuild -version`.
- **Steps:** check out, `swift build -c release --arch arm64 --arch x86_64` (output in `.build/apple/Products/Release/Aeronaut`), `scripts/bundle.sh --version "${GITHUB_REF_NAME#v}" --binary ...`, print `lipo -archs`, then `gh release create` with the zip and generated notes (SHA-256, install steps, the Gatekeeper note and the ad-hoc signing note).
- **Signing:** v0.1.x is ad-hoc signed. An ad-hoc signature's designated requirement is its cdhash, so macOS drops the Calendar grant on every update, and users re-grant Calendar access after upgrading. A later release should sign with a stable self-signed certificate, imported from a CI secret into a temporary keychain, so the grant survives.

### 3. Packaging

- **Nix:** a package that fetches the release zip, plus a nix-darwin or Home Manager module with a launchd user agent (`RunAtLoad`, `KeepAlive`, `ProcessType = Interactive`). Set `AERONAUT_AEROSPACE` to the AeroSpace binary, because a launchd agent's `PATH` is minimal.
- **Config clash:** if a module manages `~/.config/aeronaut/config.toml`, Home Manager refuses to overwrite an existing hand-made file, so users have to remove theirs first.

## Later ideas

- Per-monitor pills: today everything is drawn on the primary display.
- Tree-ordered icons once AeroSpace supports it.
- More items, such as date, weather, battery and volume.
