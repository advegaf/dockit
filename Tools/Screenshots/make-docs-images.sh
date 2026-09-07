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
# No menu shot: screencapture cannot image a pop-up menu window (it answers
# "could not create image from window" for the menu's window number every time).

# The README hero icon, straight from the app icon's largest slot.
cp Sources/Dockit/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png docs/images/logo.png
echo "logo: docs/images/logo.png"
