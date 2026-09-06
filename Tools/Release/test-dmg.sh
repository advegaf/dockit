#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${1:?provide an isolated ad-hoc-signed test app}"
WORK_PATH="$(mktemp -d "${TMPDIR:-/tmp}/dockit-dmg-test.XXXXXX")"
trap '/usr/bin/find "$WORK_PATH" -depth -delete' EXIT

/bin/bash -n "$SCRIPT_DIR/package-dmg.sh" "$SCRIPT_DIR/release.sh"
"${DOCKIT_DMG_PYTHON:-python3}" "$SCRIPT_DIR/test-packaged-app.py"
/bin/bash "$SCRIPT_DIR/package-dmg.sh" "$APP_PATH" "$WORK_PATH/test-preview.dmg" preview
if /bin/bash "$SCRIPT_DIR/package-dmg.sh" "$APP_PATH" "$WORK_PATH/test-preview.dmg" preview; then
    printf 'FAIL: existing output was overwritten\n' >&2
    exit 1
fi
if /bin/bash "$SCRIPT_DIR/package-dmg.sh" "$APP_PATH" "$WORK_PATH/release.dmg" release; then
    printf 'FAIL: ad-hoc app passed the release gate\n' >&2
    exit 1
fi
[[ ! -e "$WORK_PATH/release.dmg" ]]
if /bin/bash "$SCRIPT_DIR/package-dmg.sh" "$APP_PATH" "$WORK_PATH/test-development.dmg" development; then
    printf 'FAIL: test app passed the usable development gate\n' >&2
    exit 1
fi
[[ ! -e "$WORK_PATH/test-development.dmg" ]]
if /bin/bash "$SCRIPT_DIR/package-dmg.sh" "$APP_PATH" "$WORK_PATH/unmarked.dmg" preview; then
    printf 'FAIL: preview artifact was not labeled\n' >&2
    exit 1
fi
printf 'PASS: mounted contents, relocated alias, signatures, output protection and release gates\n'
