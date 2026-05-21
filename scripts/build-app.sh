#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/apple"
TRACKED_BUNDLE_DIR="$ROOT_DIR/bundle"
APP_DIR="$BUILD_DIR/CodexMux.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$ROOT_DIR/.build/CodexMux.iconset"
ICON_SOURCE_PATH="$ROOT_DIR/assets/codex-menubar.svg"
MENUBAR_ICON_PATH="$ROOT_DIR/assets/codex-menubar.png"
APP_ICON_PATH="$ROOT_DIR/assets/CodexMux.icns"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/CodexMux"
RESOURCE_BUNDLE_PATH="$BIN_DIR/CodexMux_CodexMux.bundle"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
VERSION="${CODEXMUX_VERSION:-1.0}"
BUILD_NUMBER="${CODEXMUX_BUILD_NUMBER:-1}"
SYNC_TRACKED_BUNDLE="${CODEXMUX_SYNC_TRACKED_BUNDLE:-0}"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "error: rsvg-convert is required to render icon assets from $ICON_SOURCE_PATH" >&2
    exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
    echo "error: iconutil is required to build $APP_ICON_PATH" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
mkdir -p "$ICONSET_DIR"

rsvg-convert "$ICON_SOURCE_PATH" -w 32 -h 32 -o "$MENUBAR_ICON_PATH"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
rsvg-convert "$ICON_SOURCE_PATH" -w 16 -h 16 -o "$ICONSET_DIR/icon_16x16.png"
rsvg-convert "$ICON_SOURCE_PATH" -w 32 -h 32 -o "$ICONSET_DIR/icon_16x16@2x.png"
rsvg-convert "$ICON_SOURCE_PATH" -w 32 -h 32 -o "$ICONSET_DIR/icon_32x32.png"
rsvg-convert "$ICON_SOURCE_PATH" -w 64 -h 64 -o "$ICONSET_DIR/icon_32x32@2x.png"
rsvg-convert "$ICON_SOURCE_PATH" -w 128 -h 128 -o "$ICONSET_DIR/icon_128x128.png"
rsvg-convert "$ICON_SOURCE_PATH" -w 256 -h 256 -o "$ICONSET_DIR/icon_128x128@2x.png"
rsvg-convert "$ICON_SOURCE_PATH" -w 256 -h 256 -o "$ICONSET_DIR/icon_256x256.png"
rsvg-convert "$ICON_SOURCE_PATH" -w 512 -h 512 -o "$ICONSET_DIR/icon_256x256@2x.png"
rsvg-convert "$ICON_SOURCE_PATH" -w 512 -h 512 -o "$ICONSET_DIR/icon_512x512.png"
rsvg-convert "$ICON_SOURCE_PATH" -w 1024 -h 1024 -o "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$APP_ICON_PATH"

rm -rf "$RESOURCE_BUNDLE_PATH"
swift build --product CodexMux --package-path "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/CodexMux"
cp -R "$RESOURCE_BUNDLE_PATH" "$RESOURCES_DIR/CodexMux_CodexMux.bundle"
if [[ -f "$APP_ICON_PATH" ]]; then
    cp "$APP_ICON_PATH" "$RESOURCES_DIR/CodexMux.icns"
fi

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CodexMux</string>
    <key>CFBundleIdentifier</key>
    <string>dev.hsi.codexmux</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>CodexMux</string>
    <key>CFBundleName</key>
    <string>CodexMux</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

if [[ "$SYNC_TRACKED_BUNDLE" == "1" ]]; then
    mkdir -p "$TRACKED_BUNDLE_DIR"
    rm -rf "$TRACKED_BUNDLE_DIR/CodexMux.app"
    cp -R "$APP_DIR" "$TRACKED_BUNDLE_DIR/CodexMux.app"
fi

echo "$APP_DIR"
