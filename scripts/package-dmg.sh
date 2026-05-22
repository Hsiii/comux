#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$BUILD_DIR/dist"
STAGING_DIR="$BUILD_DIR/dmg"
APP_BUILD_DIR="$BUILD_DIR/apple"
MOUNT_DIR="$BUILD_DIR/dmg-mount"
APP_NAME="CodexMux"
APP_BUNDLE_PATH="$APP_BUILD_DIR/${APP_NAME}.app"

VERSION=""
VOLUME_NAME="$APP_NAME"

usage() {
    cat <<'EOF'
Usage: scripts/package-dmg.sh [--version <version>] [--volume-name <name>]

Options:
  --version <version>      Include the version in the DMG filename.
  --volume-name <name>     Volume name shown when the DMG is mounted.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --volume-name)
            VOLUME_NAME="${2:-}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if ! command -v hdiutil >/dev/null 2>&1; then
    echo "error: hdiutil is required to build a DMG" >&2
    exit 1
fi

if ! command -v osascript >/dev/null 2>&1; then
    echo "error: osascript is required to style the DMG window" >&2
    exit 1
fi

"$ROOT_DIR/scripts/build-app.sh" >/dev/null

if [[ ! -d "$APP_BUNDLE_PATH" ]]; then
    echo "error: expected app bundle at $APP_BUNDLE_PATH" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
rm -rf "$MOUNT_DIR"

cp -R "$APP_BUNDLE_PATH" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"

dmg_name="$APP_NAME"
if [[ -n "$VERSION" ]]; then
    dmg_name="${dmg_name}-${VERSION}"
fi

dmg_path="$DIST_DIR/${dmg_name}.dmg"
temp_dmg_path="$BUILD_DIR/${dmg_name}-temp.dmg"

rm -f "$dmg_path" "$temp_dmg_path"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDRW \
    "$temp_dmg_path" >/dev/null

mkdir -p "$MOUNT_DIR"
hdiutil attach \
    "$temp_dmg_path" \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$MOUNT_DIR" >/dev/null

cleanup_mount() {
    if [[ -d "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
        rm -rf "$MOUNT_DIR"
    fi
}

trap cleanup_mount EXIT

sleep 1

osascript <<EOF
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set containerWindow to container window
        set current view of containerWindow to icon view
        set toolbar visible of containerWindow to false
        set statusbar visible of containerWindow to false
        set bounds of containerWindow to {120, 120, 700, 430}

        set viewOptions to the icon view options of containerWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 14
        set background color of viewOptions to {59000, 60200, 62000}

        set position of item "${APP_NAME}.app" to {170, 170}
        set position of item "Applications" to {430, 170}

        close
        open
        update without registering applications
    end tell
end tell
EOF

sleep 1
sync
hdiutil detach "$MOUNT_DIR" -quiet >/dev/null
rm -rf "$MOUNT_DIR"
trap - EXIT

hdiutil convert "$temp_dmg_path" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$dmg_path" >/dev/null

rm -f "$temp_dmg_path"

printf '%s\n' "$dmg_path"
