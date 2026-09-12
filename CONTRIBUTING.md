# Contributing

```sh
brew install xcodegen   # once
xcodegen generate       # after a clone, and after every project.yml edit
xcodebuild -project Dockit.xcodeproj -scheme Dockit -configuration Debug build
```

`Dockit.xcodeproj` is generated and gitignored, so a fresh clone has nothing to
open until `xcodegen generate` has run. `project.yml` is the source of truth for
the project, and `MARKETING_VERSION` in it is the source of truth for the
version: `Info.plist` interpolates it and `Tools/Release/publish.sh` reads it
back out to name the disk image and the tag.

The Focus extension needs a provisioning profile for `com.advegaf.dockit.focus`,
so a build on a machine without one fails on signing rather than on code. To
check that a change compiles without an Apple account, add
`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.

## Three test lanes

```sh
swift test                                               # DockitCore
xcodebuild test -project Dockit.xcodeproj -scheme DockitAppTests
node --test Tools/*Tests.mjs                             # timing, feature ledger, reference video
```

`Tools/run-dock-probe.sh` is the one that touches your real Dock. It backs the
preferences up first and restores them, and it is worth reading before running.

## Images

```sh
Tools/Screenshots/make-docs-images.sh
```

It regenerates six of the ten images on the README: the hero, the editor, the
settings page, the guide, the logo and the download button. Each shot launches
the app in demo mode, so no capture touches the real Dock, photographs it
through the window server with its own shadow, and stands it on a backdrop with
`FrameShot.swift`. Nothing draws a window frame, because the capture already
contains the real one.

The other four (`editing`, `editor-dark`, `profile-selection`, `menu`) came out
of `ArticleImages.swift`, which composites captures taken separately rather than
taking them. `menu.png` is hand-taken: `screencapture` answers "could not create
image from window" for a pop-up menu's window number every time.

## What this project holds itself to

- A claim in the README that cannot be pointed at in the code gets cut rather
  than softened. The signing sentence is there because `release.sh` earns it.
- Decisions that cost a measurement get the number written down beside them, in
  a comment or in the commit, rather than only the conclusion. The CHANGELOG's
  note on SIGKILL is the shape to copy.
