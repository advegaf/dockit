<p align="center">
  <img src="docs/images/logo.png" width="120" alt="dockit">
</p>

<h1 align="center">dockit</h1>

<p align="center">
  Saved Dock layouts for macOS. Keep one Dock for work, one for reading, one for games, and switch between them from the menu bar or with a Focus.
</p>

<table>
  <tr>
    <td><img src="docs/images/hero.png" alt="The dockit editor in dark mode with a profile selected and its Dock preview"></td>
    <td><img src="docs/images/editor.png" alt="The dockit editor in light mode"></td>
  </tr>
</table>

dockit edits the real macOS Dock. It is not a replacement Dock and it draws nothing on top of it. A profile is a list of pinned apps and spacers. Applying a profile writes that list into the Dock's preferences and restarts the Dock so it picks the list up. Everything else about your Dock (folders, recents, size, position, hiding) stays as you set it.

<p align="center">
  <img src="docs/images/settings.png" width="560" alt="dockit settings with general, focus, data and privacy, and about sections">
</p>

The editor is one window: a profile picker in the title bar, the profile's name and status, the apply button, and a preview of the Dock it will produce. Selecting a profile only inspects it. Nothing touches the Dock until you apply. The menu bar menu is a plain native menu that lists every profile and marks the active one. A Focus filter (System Settings, Focus, add a filter, dockit) applies a profile when that Focus turns on and leaves the Dock alone when it turns off.

## Why the Dock restarts

macOS has no supported way to reload pinned Dock items without restarting the Dock process. Posting the `com.apple.dock.prefchanged` notification after writing `persistent-apps` does nothing for pinned items; the Dock keeps showing the old layout with the new preferences on disk. Firefox's own "add to Dock" code and dockutil restart the Dock for the same reason, so dockit does too.

Measured on macOS 26.4, launchd brings the new Dock process back about 320 ms after the old one is killed, and the Dock strip is off screen for one or two frames at 30 fps. Forced termination, a graceful quit, SIGTERM, and `launchctl kickstart` all measured the same, so dockit uses forced termination. One thing the restart does need: the relaunched Dock rewrites its pinned apps from memory about four seconds after it starts, and a write that lands before that rewrite is lost. dockit waits for that rewrite before it writes again, which is why two switches in quick succession run back to back instead of failing.

Compared with dockutil, which edits one item at a time from a shell and needs the same restart, dockit keeps whole layouts, verifies the Dock matches after every switch, rolls back when it does not, and recovers a switch that was interrupted mid-way.

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

## Screenshots

`Tools/Screenshots/make-docs-images.sh` regenerates every image in `docs/images/`. Each shot is the real window captured through the window server with its own shadow, then placed on a plain backdrop. The app runs in demo mode for every shot, so the real Dock is never touched.

## Release

`Tools/Release/release.sh all` archives, exports with Developer ID, notarizes, staples, and packages `dist/dockit-<version>.dmg`. `Tools/Release/publish.sh <notes.md>` tags the version and creates the GitHub release with that DMG. Details in `Tools/Release/DMG.md`.

## License

MIT. See LICENSE.
