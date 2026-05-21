#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/apple"
TRACKED_BUNDLE_DIR="$ROOT_DIR/bundle"
APP_DIR="$BUILD_DIR/CodexMux.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/CodexMux"
RESOURCE_BUNDLE_PATH="$BIN_DIR/CodexMux_CodexMux.bundle"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
VERSION="${CODEXMUX_VERSION:-1.0}"
BUILD_NUMBER="${CODEXMUX_BUILD_NUMBER:-1}"
SYNC_TRACKED_BUNDLE="${CODEXMUX_SYNC_TRACKED_BUNDLE:-0}"

mkdir -p "$BUILD_DIR"
rm -rf "$RESOURCE_BUNDLE_PATH"
swift build --product CodexMux --package-path "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/CodexMux"
cp -R "$RESOURCE_BUNDLE_PATH" "$RESOURCES_DIR/CodexMux_CodexMux.bundle"

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
