#!/usr/bin/env bash
# Regenerates every screenshot in docs/images/.
#
# Two steps per shot: window-shot.sh takes the window through the window server
# with its own shadow, then FrameShot.swift stands it on a backdrop. Nothing here
# draws a window frame, because the capture already contains the real one.
#
# The app runs in demo mode for every shot, so the real Dock is never touched.
set -euo pipefail
cd "$(dirname "$0")/../.."

RAW="$(mktemp -d)"
trap 'rm -rf "$RAW"' EXIT
mkdir -p docs/images

shot() {              # shot <name> <ground> [env...]
  local name="$1" ground="$2"; shift 2
  Tools/Screenshots/window-shot.sh --shadow "$RAW/$name.png" "$@" > /dev/null
  swift Tools/Screenshots/FrameShot.swift "$RAW/$name.png" "docs/images/$name.png" "$ground"
}

shot hero     dark  HOLD=editor   DOCKIT_DEMO_APPEARANCE=dark
shot editor   light HOLD=editor   DOCKIT_DEMO_APPEARANCE=light
shot settings light HOLD=settings DOCKIT_DEMO_APPEARANCE=light
shot guide    dark  HOLD=guide    DOCKIT_DEMO_APPEARANCE=dark
# No menu shot here: screencapture cannot image a pop-up menu window (it answers
# "could not create image from window" for the menu's window number every time).
# docs/images/menu.png is a hand-taken screenshot of the open menu, cropped to
# the card with rounded corners and a shadow, then framed with FrameShot.swift.

# The README logo, from the app icon's largest slot, at the size the page draws
# it. The 1024 original is 816KB of detail nobody can see at 120 points, on the
# first image the page loads.
sips -Z 512 -s format png Sources/Dockit/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png \
  --out docs/images/logo.png >/dev/null
echo "logo: docs/images/logo.png"

# The download button. Drawn, not captured: there is no such button in the app.
swift Tools/Screenshots/DownloadBadge.swift docs/images/download.png

# What this script does NOT regenerate, so nobody goes looking for the command:
# editing.png, editor-dark.png, profile-selection.png and menu.png came out of
# the article pass in Tools/Screenshots/ArticleImages.swift, which composites
# captures taken separately rather than taking them. menu.png is hand-taken
# because screencapture cannot image a pop-up menu window at all.
