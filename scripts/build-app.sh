#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/apple"
APP_DIR="$BUILD_DIR/CodexMux.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/CodexMux"
RESOURCE_BUNDLE_PATH="$BIN_DIR/CodexMux_CodexMux.bundle"
PLIST_PATH="$CONTENTS_DIR/Info.plist"

mkdir -p "$BUILD_DIR"
swift build --product CodexMux --package-path "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/CodexMux"
cp -R "$RESOURCE_BUNDLE_PATH" "$RESOURCES_DIR/CodexMux_CodexMux.bundle"

cat > "$PLIST_PATH" <<'EOF'
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
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "$APP_DIR"
