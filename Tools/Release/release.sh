#!/bin/bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly BUILD_DIR="$ROOT_DIR/.build-release"
readonly WORK_DIR="${DOCKIT_RELEASE_WORK_DIR:-$HOME/Library/Caches/com.advegaf.dockit/release}"
readonly ARCHIVE_PATH="$BUILD_DIR/dockit.xcarchive"
readonly EXPORT_DIR="$BUILD_DIR/export"
readonly APP_PATH="$EXPORT_DIR/dockit.app"
readonly UPLOAD_PATH="$BUILD_DIR/dockit-notarization-upload.zip"
readonly NOTARY_RESULT_PATH="$BUILD_DIR/notary-result.json"
readonly NOTARY_LOG_PATH="$BUILD_DIR/notary-log.json"
readonly DIST_DIR="$ROOT_DIR/dist"
readonly PROJECT_PATH="$ROOT_DIR/Dockit.xcodeproj"
readonly EXPORT_OPTIONS_PATH="$SCRIPT_DIR/ExportOptions.plist"
readonly APP_GROUP="group.com.advegaf.dockit"
readonly APP_IDENTIFIER="com.advegaf.dockit"
readonly FOCUS_EXTENSION_IDENTIFIER="com.advegaf.dockit.focus"
readonly TEAM_IDENTIFIER="DV483F72N3"
STAGING_DIR=""

fail() {
    printf 'release: %s\n' "$*" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "Required tool is missing: $1"
}

remove_build_item() {
    local path="$1"

    case "$path" in
        "$BUILD_DIR"/*) ;;
        *) fail "Refusing to remove a path outside $BUILD_DIR"
    esac

    if [[ -e "$path" ]]; then
        /usr/bin/find "$path" -depth -delete
    fi
}

remove_work_item() {
    local path="$1"

    case "$path" in
        "$WORK_DIR"/*) ;;
        *) fail "Refusing to remove a path outside $WORK_DIR" ;;
    esac

    if [[ -e "$path" ]]; then
        /usr/bin/find "$path" -depth -delete
    fi
}

cleanup_staging() {
    if [[ -n "$STAGING_DIR" && -e "$STAGING_DIR" ]]; then
        remove_work_item "$STAGING_DIR"
    fi
}

read_entitlements() {
    local bundle="$1"
    local output="$2"

    /usr/bin/codesign --display --entitlements :- --xml "$bundle" >"$output" 2>/dev/null
}

verify_signature() {
    local bundle="$1"
    local label="$2"
    local identifier="$3"
    local details

    /usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"
    details="$(/usr/bin/codesign --display --verbose=4 "$bundle" 2>&1)"
    grep -Fxq "Identifier=$identifier" <<<"$details" || fail "$label has the wrong bundle identifier."
    grep -Fxq "TeamIdentifier=$TEAM_IDENTIFIER" <<<"$details" || fail "$label has the wrong signing team."
    grep -Fq 'Authority=Developer ID Application:' <<<"$details" || fail "$label is not signed with Developer ID Application."
    grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' <<<"$details" || fail "$label does not have hardened runtime enabled."
    grep -Eq '^Timestamp=' <<<"$details" || fail "$label is missing a trusted signing timestamp."
}

plist_array_contains() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local index=0
    local value

    while value="$(/usr/libexec/PlistBuddy -c "Print :$key:$index" "$plist" 2>/dev/null)"; do
        [[ "$value" == "$expected" ]] && return 0
        index=$((index + 1))
    done
    return 1
}

verify_profile() {
    local profile="$1"
    local label="$2"
    local identifier="$3"
    local output="$4"

    [[ -f "$profile" ]] || fail "$label is missing its Developer ID provisioning profile."
    /usr/bin/security cms -D -i "$profile" >"$output" 2>/dev/null || fail "$label has an unreadable provisioning profile."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$output")" == "$TEAM_IDENTIFIER.$identifier" ]] || fail "$label has a provisioning profile for the wrong identifier."
    plist_array_contains "$output" 'Entitlements:com.apple.security.application-groups' "$APP_GROUP" || fail "$label provisioning profile does not authorize the App Group."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$output")" == "true" ]] || fail "$label does not have a Developer ID provisioning profile."
}

verify_entitlements() {
    local app_path="$1"
    local focus_extension_path="$2"
    local work_dir="$BUILD_DIR/entitlements"
    local app_entitlements
    local app_profile
    local extension_entitlements
    local extension_profile

    remove_build_item "$work_dir"
    mkdir -p "$work_dir"
    app_entitlements="$work_dir/app.plist"
    app_profile="$work_dir/app-profile.plist"
    extension_entitlements="$work_dir/extension.plist"
    extension_profile="$work_dir/extension-profile.plist"
    read_entitlements "$app_path" "$app_entitlements"
    read_entitlements "$focus_extension_path" "$extension_entitlements"
    verify_profile "$app_path/Contents/embedded.provisionprofile" "dockit" "$APP_IDENTIFIER" "$app_profile"
    verify_profile "$focus_extension_path/Contents/embedded.provisionprofile" "The Focus extension" "$FOCUS_EXTENSION_IDENTIFIER" "$extension_profile"

    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$app_entitlements")" == "$APP_GROUP" ]] || fail "dockit is missing the App Group entitlement."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$extension_entitlements")" == "$APP_GROUP" ]] || fail "The Focus extension is missing the App Group entitlement."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$extension_entitlements")" == "true" ]] || fail "The Focus extension is not sandboxed."
    if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$app_entitlements" >/dev/null 2>&1; then
        fail "dockit must remain outside the App Sandbox so it can manage the Dock."
    fi

    remove_build_item "$work_dir"
}

verify_export() {
    local export_dir="${1:-$EXPORT_DIR}"
    local app_path="$export_dir/dockit.app"
    local focus_extension_path="$app_path/Contents/Extensions/DockitFocusExtension.appex"
    local app_info="$app_path/Contents/Info.plist"
    local focus_info="$focus_extension_path/Contents/Info.plist"

    [[ -d "$app_path" ]] || fail "Export did not produce $app_path"
    "${DOCKIT_DMG_PYTHON:-python3}" "$SCRIPT_DIR/validate-packaged-app.py" "$app_path" release
    [[ -d "$focus_extension_path" ]] || fail "Export did not contain the Focus extension."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app_info")" == "dockit" ]] || fail "The app display name is not lowercase dockit."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app_info")" == "dockit" ]] || fail "The app bundle name is not lowercase dockit."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_info")" == "dockit" ]] || fail "The app executable name is not lowercase dockit."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$focus_info")" == "dockit" ]] || fail "The Focus extension display name is not lowercase dockit."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$focus_info")" == "dockit" ]] || fail "The Focus extension bundle name is not lowercase dockit."
    verify_signature "$app_path" "dockit" "$APP_IDENTIFIER"
    verify_signature "$focus_extension_path" "The Focus extension" "$FOCUS_EXTENSION_IDENTIFIER"
    verify_entitlements "$app_path" "$focus_extension_path"
}

build_release() {
    local staged_archive
    local staged_export

    mkdir -p "$BUILD_DIR" "$WORK_DIR"
    STAGING_DIR="$(mktemp -d "$WORK_DIR/staging.XXXXXX")"
    staged_archive="$STAGING_DIR/dockit.xcarchive"
    staged_export="$STAGING_DIR/export"

    xcodegen generate --quiet --spec "$ROOT_DIR/project.yml" --project "$ROOT_DIR"
    if ! xcodebuild -quiet \
        -project "$PROJECT_PATH" \
        -scheme Dockit \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$staged_archive" \
        -allowProvisioningUpdates \
        clean archive; then
        fail "The Release archive failed."
    fi
    if ! xcodebuild -quiet \
        -exportArchive \
        -archivePath "$staged_archive" \
        -exportPath "$staged_export" \
        -exportOptionsPlist "$EXPORT_OPTIONS_PATH" \
        -allowProvisioningUpdates; then
        fail "The Developer ID export failed. Confirm that Apple owns the bundle identifiers and App Group for team $TEAM_IDENTIFIER, then retry."
    fi
    verify_export "$staged_export"
    remove_build_item "$ARCHIVE_PATH"
    remove_build_item "$EXPORT_DIR"
    /bin/mv "$staged_archive" "$ARCHIVE_PATH"
    /bin/mv "$staged_export" "$EXPORT_DIR"
    remove_work_item "$STAGING_DIR"
    STAGING_DIR=""
    printf 'Signed export ready at %s\n' "$APP_PATH"
}

verify_notary_profile() {
    local profile="${NOTARY_KEYCHAIN_PROFILE:-}"
    local check_path

    [[ -n "$profile" ]] || fail "Set NOTARY_KEYCHAIN_PROFILE to a notarytool keychain profile created with 'xcrun notarytool store-credentials'."
    mkdir -p "$BUILD_DIR"
    check_path="$(mktemp "$BUILD_DIR/notary-profile.XXXXXX")"
    if ! xcrun notarytool history --keychain-profile "$profile" --output-format json >"$check_path"; then
        /usr/bin/find "$check_path" -delete
        fail "The notarytool keychain profile '$profile' is missing, invalid, or unavailable."
    fi
    /usr/bin/find "$check_path" -delete
}

notarize_release() {
    local version
    local final_path
    local status
    local submission_id

    verify_notary_profile
    verify_export
    remove_build_item "$UPLOAD_PATH"
    remove_build_item "$NOTARY_RESULT_PATH"
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$UPLOAD_PATH"

    if ! xcrun notarytool submit "$UPLOAD_PATH" \
        --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
        --wait \
        --timeout 60m \
        --output-format json >"$NOTARY_RESULT_PATH"; then
        fail "Apple did not complete the notarization request. See $NOTARY_RESULT_PATH"
    fi

    if ! status="$(/usr/bin/plutil -extract status raw -o - "$NOTARY_RESULT_PATH")"; then
        fail "Apple returned an unreadable notarization result. See $NOTARY_RESULT_PATH"
    fi
    if ! submission_id="$(/usr/bin/plutil -extract id raw -o - "$NOTARY_RESULT_PATH")"; then
        fail "Apple returned a notarization result without a submission ID. See $NOTARY_RESULT_PATH"
    fi
    if [[ "$status" != "Accepted" ]]; then
        remove_build_item "$NOTARY_LOG_PATH"
        if xcrun notarytool log "$submission_id" "$NOTARY_LOG_PATH" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE"; then
            fail "Apple returned notarization status '$status' for submission $submission_id. See $NOTARY_LOG_PATH"
        fi
        fail "Apple returned notarization status '$status' for submission $submission_id. See $NOTARY_RESULT_PATH"
    fi

    xcrun stapler staple -v "$APP_PATH"
    xcrun stapler validate -v "$APP_PATH"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
    verify_export

    version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Contents/Info.plist")"
    final_path="$DIST_DIR/dockit-$version.zip"
    mkdir -p "$DIST_DIR"
    if [[ -e "$final_path" ]]; then
        /usr/bin/find "$final_path" -depth -delete
    fi
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$final_path"
    printf 'Apple accepted submission %s. Notarized release ready at %s\n' "$submission_id" "$final_path"
    notarize_dmg "$version"
}

notarize_dmg() {
    local version="$1"
    local dmg_path="$BUILD_DIR/dockit-$version.dmg"
    local final_dmg_path="$DIST_DIR/dockit-$version.dmg"
    local result_path="$BUILD_DIR/dmg-notary-result.json"
    local identity

    [[ ! -e "$final_dmg_path" ]] || fail "A DMG already exists at $final_dmg_path. Preserve or move that existing release image before retrying."
    if [[ ! -e "$dmg_path" ]]; then
        /bin/bash "$SCRIPT_DIR/package-dmg.sh" "$APP_PATH" "$dmg_path" release
    else
        fail "An unfinished DMG remains at $dmg_path. Preserve or remove that exact staging artifact before retrying. Nothing was published."
    fi
    identity="$(/usr/bin/codesign --display --verbose=4 "$APP_PATH" 2>&1 | /usr/bin/sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | /usr/bin/head -1)"
    [[ -n "$identity" ]] || fail "Cannot determine the verified app's Developer ID identity."
    /usr/bin/codesign --sign "$identity" --timestamp "$dmg_path"
    if ! xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
        --wait --timeout 60m --output-format json >"$result_path"; then
        fail "DMG notarization did not complete. Staging artifact retained at $dmg_path. See $result_path. Nothing was published."
    fi
    [[ "$(/usr/bin/plutil -extract status raw -o - "$result_path")" == Accepted ]] || fail "DMG notarization was not accepted. See $result_path"
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
    /usr/bin/codesign --verify --strict "$dmg_path"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
    /bin/mv "$dmg_path" "$final_dmg_path"
    printf 'Notarized installer ready at %s\n' "$final_dmg_path"
}

usage() {
    printf 'Usage: %s build|verify|notarize|all\n' "$0"
}

require_tool xcodegen
require_tool xcodebuild
require_tool xcrun
require_tool codesign
require_tool plutil
require_tool ditto
require_tool spctl

trap cleanup_staging EXIT

case "${1:-all}" in
    build)
        build_release
        ;;
    verify)
        verify_export
        printf 'Developer ID export verified at %s\n' "$APP_PATH"
        ;;
    notarize)
        notarize_release
        ;;
    all)
        verify_notary_profile
        build_release
        notarize_release
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac
