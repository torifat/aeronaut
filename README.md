# Aeronaut

A small SwiftUI status bar for macOS and [AeroSpace](https://github.com/nikitabobko/AeroSpace), replacing a sketchybar setup.

It draws two pills on the primary display, and both fade out while the auto-hidden menu bar is showing.

The workspace pill sits top-left:

- Workspaces with windows are shown, plus the focused one even if it's empty.
- The focused workspace has a green highlight that slides between workspaces and shows its app icons.
- The focused window's icon is drawn at full strength, and the other icons are dimmed.
- Clicking a number switches to that workspace. Clicking an icon focuses that window.

The calendar pill sits top-right:

- It shows the time until your next timed event, such as "in 7h", with a border that turns yellow at 5 minutes and red at 1 minute.
- It expands to show the event's title on hover, for the last 5 minutes before the event, and briefly whenever the next event changes.
- Clicking it opens Calendar.

State comes from `aerospace subscribe --all` events, backed by a 5-second refresh for changes AeroSpace doesn't report. App icons use [sketchybar-app-font](https://github.com/kvndrsslr/sketchybar-app-font) ligatures, mapped through `Sources/Aeronaut/Resources/icon_map.json`.

## Requirements

- macOS 14 or later
- AeroSpace with `aerospace` on `PATH`, or at a Nix or Homebrew location (override with `AERONAUT_AEROSPACE=/path/to/aerospace`)
- The fonts `Pixel Code`, `sketchybar-app-font` and `Liga SFMono Nerd Font` (for the calendar icon)
- Calendar access, which macOS asks for on first launch (under `swift run`, it asks for your terminal)

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

## Configuration

Aeronaut works without a config file. To change its look, create `~/.config/aeronaut/config.toml`, or put it under `$XDG_CONFIG_HOME` if you set that. Saving the file updates the bar immediately. Here are all the options at their defaults:

```toml
[pill]
material = "frost"        # frost | flat | glass | clear-glass
tint = 0.45               # 0 to 1: dark tint over the material
border = "accent"         # none | neutral | accent
border-opacity = 0.6      # 0 to 1, for the accent border

[workspaces]
style = "compact"         # compact | all (every workspace shows its icons)
focus = "translucent"     # translucent | solid | glossy | tint | outline | underline
focus-opacity = 0.75      # 0 to 1, for translucent
icon-size = 18            # 12 to 20
focus-margin = 4          # 0 to 6: gap between the green capsule and the pill's edge
focus-padding = "auto"    # "auto" (a lone icon sits in a circle) or 0 to 12
accent = "green"          # a Catppuccin Mocha name (teal, sky, mauve, peach, …) or "#rrggbb"

[text]
font = "pixel"            # pixel | rounded | mono | sf

[calendar]
icon-size = 17            # 12 to 22
```

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

- App bundle and release builds
- Nix packaging and a launchd agent
- Per-monitor pills
