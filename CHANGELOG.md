# Changelog

## 1.0.0

- First public release. Saved Dock profiles, one-click apply from the editor or the menu bar, a Focus filter that switches profiles with a Focus, and .dockit export and import.
- Fixed: a second profile switch within about four seconds of the first failed and restarted the Dock twice. A relaunched Dock rewrites its pinned apps from memory about 4.1 seconds after it starts, and a write that lands before that rewrite is lost. dockit now waits for that rewrite before it writes again.
- Fixed: recovery after an interrupted switch restarted the Dock even when the Dock had already relaunched with the written layout. The pending record now carries the Dock process id from before the write, and recovery skips the restart when a newer Dock is running.
- Fixed: the app learned that the Dock was back up to 100 ms late. The process poll now runs every 20 ms.
- The desktop no longer flashes black during a switch. The Dock process owns the wallpaper window, so killing it blanked every display for about 70 ms. dockit now shows the wallpaper image in a window at the desktop level from just before the kill until the new Dock has drawn its own wallpaper. Needs a readable wallpaper file, or Screen Recording already granted so it can copy the wallpaper from the screen; otherwise that screen keeps the flash.
- Measured on macOS 26.4: after the kill, launchd brings a new Dock process back in about 320 ms and the Dock strip is off screen for four or five frames at 30 fps. Forced termination, graceful termination, SIGTERM, and launchctl kickstart all measured the same, so the default stays forced termination.
- Known: macOS offers no way to reload pinned Dock items without restarting the Dock. Posting com.apple.dock.prefchanged after writing persistent-apps leaves the Dock unchanged; the Dock kept showing the old layout for five seconds with the new preferences on disk. Firefox and dockutil restart the Dock for the same reason.
- Known: the forcedTerminationAndExplicitRelaunch strategy does not work on macOS 26. NSWorkspace declines to launch Dock.app, and the probe's own recovery path failed with it. It stays selectable for the probe only.
- Known: no Homebrew cask yet. Download the DMG from the GitHub release.
