#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_PATH="${1:?usage: package-dmg.sh app-path output.dmg preview|development|release}"
OUTPUT_PATH="${2:?provide output.dmg}"
MODE="${3:?choose preview or release}"
PYTHON="${DOCKIT_DMG_PYTHON:-python3}"
MOUNT_PATH=""
WORK_PATH=""

fail() { printf 'dmg: %s\n' "$*" >&2; exit 1; }
verify_background() {
    local metadata
    metadata="$(/usr/bin/sips -g pixelWidth -g pixelHeight -g dpiWidth -g dpiHeight "$1")"
    /usr/bin/grep -Fq 'pixelWidth: 1320' <<<"$metadata" || fail "background width must be 1320 pixels"
    /usr/bin/grep -Fq 'pixelHeight: 800' <<<"$metadata" || fail "background height must be 800 pixels"
    /usr/bin/grep -Fq 'dpiWidth: 144.000' <<<"$metadata" || fail "background horizontal DPI must be 144"
    /usr/bin/grep -Fq 'dpiHeight: 144.000' <<<"$metadata" || fail "background vertical DPI must be 144"
}
cleanup() {
    if [[ -n "$MOUNT_PATH" ]] && /sbin/mount | /usr/bin/grep -Fq " on $MOUNT_PATH ("; then
        /usr/bin/hdiutil detach "$MOUNT_PATH" -quiet || return
    fi
    if [[ -n "$WORK_PATH" && -d "$WORK_PATH" ]]; then
        /usr/bin/find "$WORK_PATH" -depth -delete
    fi
}

[[ "$MODE" == preview || "$MODE" == development || "$MODE" == release ]] || fail "mode must be preview, development or release"
[[ "$APP_PATH" == /* && -d "$APP_PATH/Contents" ]] || fail "use an absolute app bundle path"
[[ "$OUTPUT_PATH" == /* && "$OUTPUT_PATH" == *.dmg ]] || fail "use an absolute .dmg output path"
[[ ! -e "$OUTPUT_PATH" ]] || fail "output already exists; choose a new output path"
[[ "$MODE" != preview || "$OUTPUT_PATH" == *preview*.dmg ]] || fail "preview filename must include preview"
[[ "$MODE" != development || "$OUTPUT_PATH" == *development*.dmg ]] || fail "development filename must include development"
"$PYTHON" "$SCRIPT_DIR/validate-packaged-app.py" "$APP_PATH" "$MODE"
"$PYTHON" -c 'import ds_store, mac_alias' || fail "install build-only dependencies from Tools/Release/dmg-requirements.txt"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
if [[ "$MODE" == release ]]; then
    /usr/bin/codesign -dv "$APP_PATH" 2>&1 | /usr/bin/grep -Fq 'Authority=Developer ID Application:' || fail "release requires Developer ID signing"
    xcrun stapler validate "$APP_PATH"
    /usr/sbin/spctl --assess --type execute "$APP_PATH"
fi
WORK_PATH="$(mktemp -d "${TMPDIR:-/tmp}/dockit-dmg.XXXXXX")"
MOUNT_PATH="$WORK_PATH/mounted"
trap cleanup EXIT
mkdir "$MOUNT_PATH"
volume="dockit"
app_name="dockit.app"
if [[ "$MODE" == preview ]]; then
    volume="dockit preview"
    app_name="dockit preview.app"
elif [[ "$MODE" == development ]]; then
    volume="dockit development"
fi
mkdir "$WORK_PATH/input" "$WORK_PATH/seed"
/usr/bin/ditto "$APP_PATH" "$WORK_PATH/input/$app_name"
npx --yes create-dmg@8.1.0 --no-code-sign --no-version-in-filename --dmg-title="$volume" \
    "$WORK_PATH/input/$app_name" "$WORK_PATH/seed"
seed_images=("$WORK_PATH/seed/"*.dmg)
[[ ${#seed_images[@]} == 1 && -f "${seed_images[0]}" ]] || fail "seed tool did not produce exactly one disk image"
/usr/bin/hdiutil convert -quiet "${seed_images[0]}" -format UDRW -o "$WORK_PATH/writable.dmg"
/usr/bin/hdiutil attach -quiet -readwrite -nobrowse -noautoopen -mountpoint "$MOUNT_PATH" "$WORK_PATH/writable.dmg"
xcrun swift "$SCRIPT_DIR/InstallerBackground.swift" "$ROOT_DIR/Design/Installer/installer-art-white.png" "$WORK_PATH/artwork"
xcrun swift "$SCRIPT_DIR/InstallerBackgroundTests.swift" "$WORK_PATH/artwork"
/bin/cp "$WORK_PATH/artwork/background.tiff" "$MOUNT_PATH/.bg.tiff"
verify_background "$MOUNT_PATH/.bg.tiff"
if [[ -d "$MOUNT_PATH/.background" ]]; then
    /usr/bin/find "$MOUNT_PATH/.background" -depth -delete
fi
if [[ -f "$MOUNT_PATH/.VolumeIcon.icns" ]]; then
    /usr/bin/find "$MOUNT_PATH/.VolumeIcon.icns" -delete
fi
"$PYTHON" "$SCRIPT_DIR/dmg-layout.py" "$MOUNT_PATH" "$app_name"
/usr/bin/chflags hidden "$MOUNT_PATH/.bg.tiff" "$MOUNT_PATH/.DS_Store"
/usr/bin/codesign --verify --deep --strict "$MOUNT_PATH/$app_name"
source_hash="$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 | /usr/bin/grep '^CDHash=')"
copy_hash="$(/usr/bin/codesign -dv --verbose=4 "$MOUNT_PATH/$app_name" 2>&1 | /usr/bin/grep '^CDHash=')"
[[ "$source_hash" == "$copy_hash" ]] || fail "app signature changed during packaging"
/usr/bin/hdiutil detach -quiet "$MOUNT_PATH"
mkdir -p "$(dirname "$OUTPUT_PATH")"
/usr/bin/hdiutil convert -quiet "$WORK_PATH/writable.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_PATH"
/usr/bin/hdiutil verify "$OUTPUT_PATH"
MOUNT_PATH="$WORK_PATH/readonly"
mkdir "$MOUNT_PATH"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_PATH" "$OUTPUT_PATH"
"$PYTHON" "$SCRIPT_DIR/dmg-layout.py" "$MOUNT_PATH" "$app_name" --verify
verify_background "$MOUNT_PATH/.bg.tiff"
"$PYTHON" "$SCRIPT_DIR/validate-packaged-app.py" "$MOUNT_PATH/$app_name" "$MODE"
/usr/bin/codesign --verify --deep --strict "$MOUNT_PATH/$app_name"
[[ "$(/usr/bin/codesign -dv --verbose=4 "$MOUNT_PATH/$app_name" 2>&1 | /usr/bin/grep '^CDHash=')" == "$source_hash" ]] || fail "converted image changed the app signature"
/usr/bin/hdiutil detach -quiet "$MOUNT_PATH"
printf '%s dmg ready: %s\n' "$MODE" "$OUTPUT_PATH"
