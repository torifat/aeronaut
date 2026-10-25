# Aeronaut

<img src="docs/icon.png" align="right" width="128" height="128" alt="Aeronaut's icon, a green blimp">

A small SwiftUI status bar for macOS and [AeroSpace](https://github.com/nikitabobko/AeroSpace), replacing a sketchybar setup.

It draws two pills on the primary display, and both fade out while the auto-hidden menu bar is showing.

The workspace pill sits top-left:

<img src="docs/workspaces.gif" width="204" alt="The workspace pill. A green capsule slides from workspace 2 to 3, 1 and 4 and back, showing each workspace's app icons.">

- Workspaces with windows are shown, plus the focused one even if it's empty.
- The focused workspace has a green highlight that slides between workspaces and shows its app icons.
- The focused window's icon is drawn at full strength, and the other icons are dimmed.
- Clicking a number switches to that workspace. Clicking an icon focuses that window.

The calendar pill sits top-right:

<img src="docs/calendar.gif" width="250" alt="The calendar pill. It shows in 3h, expands to a yellow in 2m with the title Standup and a draining ring, turns red at in 1m, then goes back to in 3h.">

- It shows the time until your next timed event, such as "in 7h", in a capsule that's neutral, then yellow at 5 minutes and red at 1 minute.
- It expands to show the event's title on hover, for the last 5 minutes before the event, and briefly whenever the next event changes.
- Clicking it opens Calendar.

State comes from `aerospace subscribe --all` events, backed by a 5-second refresh for changes AeroSpace doesn't report. App icons use [sketchybar-app-font](https://github.com/kvndrsslr/sketchybar-app-font) ligatures. The font and its `icon_map.json` ship inside the app, so you don't need the font installed.

## Requirements

- macOS 14 or later
- AeroSpace with `aerospace` on `PATH`, or at a Nix or Homebrew location (override with `AERONAUT_AEROSPACE=/path/to/aerospace`)
- The fonts `Pixel Code` and `Liga SFMono Nerd Font` (for the calendar icon)
- Calendar access, which macOS asks for on first launch (under `swift run`, it asks for your terminal)

## Installation

1. Download `Aeronaut-<version>.zip` from [Releases](https://github.com/torifat/aeronaut/releases).
2. Unzip it and move `Aeronaut.app` to `/Applications`.
3. The app isn't notarized, so Gatekeeper blocks the first launch. Right-click it and choose Open, or run `xattr -dr com.apple.quarantine /Applications/Aeronaut.app`.
4. On first launch it asks for Calendar access. 0.1.x releases are ad-hoc signed, so macOS asks again after each update.
5. To start it at login, add it in System Settings › General › Login Items.

## Build and run

The Command Line Tools toolchain is enough. If `xcode-select` points somewhere else, such as a Nix SDK, set:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
```

Then build and run it:

```sh
swift build
swift run Aeronaut
```

To render both pills once to a PNG without starting the bar, run:

```sh
swift run Aeronaut --snapshot pill.png
```

To build the app bundle yourself, run `scripts/bundle.sh --version 0.1.0`. It builds a release binary, then writes `dist/Aeronaut.app` (signed ad-hoc) and `dist/Aeronaut-0.1.0.zip`. `--binary PATH` uses a prebuilt executable and `--out DIR` changes the output directory.

To re-record the animations in this README, run `swift scripts/readme-media.swift` with no other Aeronaut running. Your terminal needs Screen Recording permission, and AGENTS.md has the details.

To pull the latest app icons, run `swift scripts/update-icons.swift`. It downloads the font and `icon_map.json` from the newest sketchybar-app-font release into `Sources/Aeronaut/Resources/`. Pass a tag such as `v3.0.12` to pin a release instead.

## Configuration

Aeronaut works without a config file. To change its look, create `~/.config/aeronaut/config.toml`, or put it under `$XDG_CONFIG_HOME` if you set that. Saving the file updates the bar immediately. Here are all the options at their defaults:

```toml
[pill]
material = "frost"        # frost | flat | glass | clear-glass
tint = 0.45               # 0 to 1: dark tint over the material
border = "accent"         # none | neutral | accent
border-opacity = 0.6      # 0 to 1, for the accent border
focus-opacity = 0.75      # 0 to 1: fill of the translucent workspace capsule and the calendar's yellow and red one
focus-margin = 4          # 0 to 6: gap between those capsules and the pill's edge

[workspaces]
style = "compact"         # compact | all (every workspace shows its icons)
focus = "translucent"     # translucent | solid | glossy | tint | outline | underline
icon-size = 16            # 12 to 20
focus-padding = "auto"    # "auto" (a lone icon sits in a circle) or 0 to 12
accent = "green"          # a Catppuccin Mocha name (teal, sky, mauve, peach, …) or "#rrggbb"

[text]
font = "pixel"            # pixel | rounded | mono | sf

[calendar]
style = "capsule"         # capsule | plain
icon-size = 17            # 12 to 22
```

For example, `focus-margin = 0` under `[pill]` makes the focus capsule fill the pill's height:

<img src="docs/focus-margin-0.png" width="204" alt="The workspace pill with focus-margin = 0. The green capsule runs the full height of the pill.">

If a line is invalid, Aeronaut prints a warning naming the line and uses that option's default. `glass` and `clear-glass` use Liquid Glass (macOS 26). In a status bar panel it currently renders flat, so `frost` is the recommended material.

## Layout

| File | Purpose |
| --- | --- |
| `AeroSpace.swift` | CLI client, the state model and the event stream |
| `WorkspaceStore.swift` | Observable state, with event handling and coalesced refreshes |
| `WorkspacesPill.swift` | The workspace pill and its animations |
| `NextEvent.swift` | Calendar pill state: label, colour and urgency |
| `CalendarStore.swift` | EventKit lookup of the next event, refreshed on the minute |
| `NextEventPill.swift` | The calendar pill, with hover, peek and expand |
| `PillPanel.swift` | Transparent, non-activating panel at menu-bar level |
| `MenuBarWatcher.swift` | Fades the panels out while the menu bar is showing |
| `Config.swift`, `Settings.swift`, `ConfigWatcher.swift` | The config file: parsing, the live settings, and reload on save |
| `Theme.swift` | Colours, fonts and the animation curve |

## Roadmap

- Per-monitor pills
