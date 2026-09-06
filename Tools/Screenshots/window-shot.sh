#!/usr/bin/env bash
# Captures a real dockit window through the window server.
#
# Usage: Tools/Screenshots/window-shot.sh [--shadow] <out.png> [env assignments...]
#   Tools/Screenshots/window-shot.sh --shadow docs/images/hero.png HOLD=editor DOCKIT_DEMO_APPEARANCE=dark
#
# The app runs with DOCKIT_DEMO=1 (seeded profiles, the real Dock is never
# touched) and DOCKIT_WINDOW_HOLD=<surface>, opens that surface, prints its
# window number, and stays open so screencapture can shoot the real thing.
# Needs Screen Recording permission for the terminal, granted once.
#
#   --shadow      keep the window server's drop shadow and alpha. Evidence rows
#                 want it off, since the shadow is noise around the thing under
#                 test; README shots want it on, because it is macOS drawing its
#                 own window and no redrawn frame can match it.
#
# HOLD selects the surface: editor or settings. Everything else on the
# command line is passed to the app as environment.
set -euo pipefail
cd "$(dirname "$0")/.."

SHADOW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --shadow) SHADOW=1; shift ;;
    *) break ;;
  esac
done

OUT="$1"; shift
APP="${DOCKIT_APP:-$(xcodebuild -project Dockit.xcodeproj -scheme Dockit -configuration Debug \
      -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/dockit.app}"
HOLD=editor
for assignment in "$@"; do
  case "$assignment" in
    HOLD=*) HOLD="${assignment#HOLD=}" ;;
  esac
done

mkdir -p "$(dirname "$OUT")"
META="$(mktemp)"

# Any dockit still running from an earlier shot owns windows too, and
# window-id.swift resolves by owner across every process. A leftover instance
# with a document open is larger than the panel being captured, so it wins and
# the shot silently shows the wrong window.
pkill -x dockit 2>/dev/null || true
# Wait for the old process to actually exit, then let its window finish tearing
# down. Sleeping a fixed amount was wrong twice over: too short and screencapture
# answers "could not create image from window" for a window that is plainly on
# screen, and a window caught mid-teardown is still in the window list at a
# shrinking size, which reads as the app collapsing its own window.
for _ in $(seq 1 40); do
  pgrep -x dockit >/dev/null 2>&1 || break
  /usr/bin/osascript -e 'delay 0.25' >/dev/null 2>&1
done
/usr/bin/osascript -e 'delay 0.8' >/dev/null 2>&1
env "$@" DOCKIT_DEMO=1 DOCKIT_WINDOW_HOLD="$HOLD" "$APP/Contents/MacOS/dockit" > "$META" 2>/dev/null &
APP_PID=$!

# Poll rather than sleeping a fixed amount, so a slow first launch does not
# produce a shot of an empty screen.
WINDOW=""
for _ in $(seq 1 60); do
  WINDOW="$(sed -n 's/.*windownumber=\([0-9]*\).*/\1/p' "$META" | head -1)"
  [ -n "$WINDOW" ] && break
  /usr/bin/osascript -e 'delay 0.25' >/dev/null 2>&1
done

# Let entrance animations finish and fonts settle. Without this the shot catches
# a staggered list halfway in, which looks like a rendering bug rather than motion.
/usr/bin/osascript -e 'delay 1.2' >/dev/null 2>&1

METRICS="$(grep -o 'document=.*' "$META" | head -1 || true)"

if [ -z "$WINDOW" ]; then
  echo "no window number reported; app output was:" >&2
  cat "$META" >&2
  kill "$APP_PID" 2>/dev/null || true
  exit 1
fi

# screencapture intermittently answers "could not create image from window" for a
# window that is on screen, alpha 1, and correctly sized. It is a race inside the
# window server, not a wrong window number. Edit mode fails most often, which fits:
# the caret blinks, so the window is redrawing continuously. Retrying across
# several blink cycles clears it. A shot pipeline that dies one image into eight is
# worse than one that waits.
CAPTURED=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if [ "$SHADOW" -eq 1 ]; then
    screencapture -x -l"$WINDOW" "$OUT" 2>/dev/null && CAPTURED=1 && break
  else
    screencapture -x -o -l"$WINDOW" "$OUT" 2>/dev/null && CAPTURED=1 && break
  fi
  /usr/bin/osascript -e 'delay 1.0' >/dev/null 2>&1
done

if [ "$CAPTURED" -eq 0 ]; then
  echo "screencapture failed for window $WINDOW after 12 attempts" >&2
  kill "$APP_PID" 2>/dev/null || true
  exit 1
fi
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
# Do not return while this shot's window is still tearing down: the next call in a
# batch would otherwise resolve or capture against a shrinking ghost.
for _ in $(seq 1 40); do
  pgrep -x dockit >/dev/null 2>&1 || break
  /usr/bin/osascript -e 'delay 0.25' >/dev/null 2>&1
done
rm -f "$META"

echo "$OUT"
# Plain `[ -n ... ] && echo` as the last line makes the script exit 1 whenever
# there are no metrics, which is every non-document shot.
if [ -n "$METRICS" ]; then echo "$METRICS"; fi
