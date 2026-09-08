<p align="center">
  <img src="docs/images/logo.png" width="120" alt="dockit">
</p>

<h1 align="center">dockit</h1>

<p align="center">
  Saved Dock layouts for macOS. Keep one Dock for work, one for reading, one for games, and switch between them from the menu bar or with a Focus.
</p>

<p align="center">
  <img src="docs/images/hero.png" width="960" alt="dockit work profile editor and profile switching menu on a blue and lavender background">
</p>

dockit edits the real macOS Dock. It is not a replacement Dock and it draws nothing on top of it. A profile is a list of pinned apps and spacers. Applying a profile writes that list into the Dock's preferences and restarts the Dock so it picks the list up. Everything else about your Dock (folders, recents, size, position, hiding) stays as you set it.

<p align="center">
  <img src="docs/images/settings.png" width="960" alt="dockit settings with general, focus, data and privacy, and about sections">
</p>

<p align="center">
  <img src="docs/images/guide.png" width="960" alt="The quick guide sheet: choose a dock, make it yours, use this dock, switch from the menu bar">
</p>

The quick guide opens once, after the first profile is saved, and again from Help, quick guide. It covers the four things there are to do: pick a profile, arrange it, apply it, and switch from the menu bar.

<p align="center">
  <img src="docs/images/menu.png" width="760" alt="The dockit menu bar menu listing every profile with the active one checked">
</p>

The menu bar menu is a plain native menu: every profile, the active one checked, then manage docks, settings, and quit.

The editor is one window: a profile picker in the title bar, the profile's name and status, the apply button, and a preview of the Dock it will produce. Selecting a profile only inspects it. Nothing touches the Dock until you apply. The menu bar menu is a plain native menu that lists every profile and marks the active one. A Focus filter (System Settings, Focus, add a filter, dockit) applies a profile when that Focus turns on and leaves the Dock alone when it turns off.

<p align="center">
  <img src="docs/images/profile-selection.png" width="760" alt="The profile picker open in the dockit editor">
</p>

<p align="center">
  <img src="docs/images/editing.png" width="760" alt="Editing the work profile in dockit">
</p>

<p align="center">
  <img src="docs/images/editor.png" width="960" alt="The work profile editor in light mode">
</p>

<p align="center">
  <img src="docs/images/editor-dark.png" width="960" alt="The work profile editor in dark mode">
</p>

## Build

Requires Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project Dockit.xcodeproj -scheme Dockit -configuration Debug build
```

Tests run in three lanes:

```sh
swift test                                    # DockitCore
xcodebuild test -project Dockit.xcodeproj -scheme DockitAppTests
node --test Tools/*Tests.mjs                  # timing evaluator, feature ledger, reference video
```

The real Dock probe in `Tools/run-dock-probe.sh` mutates your actual Dock, backs it up first, and restores it. Read the script before running it.

## Layout

```
Sources/DockitCore         profiles, Dock preferences, restart, verification, recovery
Sources/Dockit             the app: editor, settings, menu bar, Focus bridge
Sources/DockitFocusExtension   the Focus filter intent
Tests/                     core (swift-testing) and app (XCTest, test host) suites
Tools/DockProbe.swift      real Dock probe and reload experiments
Tools/Screenshots/         the README screenshot pipeline
Tools/Release/             signing, notarization, DMG, GitHub release
Design/                    app icon source and installer artwork
docs/                      reviews and the feature ledger
```

## License

MIT. See LICENSE.
