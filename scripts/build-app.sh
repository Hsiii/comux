#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/apple"
DERIVED_DATA_DIR="$ROOT_DIR/.build/xcodebuild"
XCODE_APP_DIR="$DERIVED_DATA_DIR/Build/Products/Debug/CodexMux.app"
TRACKED_BUNDLE_DIR="$ROOT_DIR"
APP_DIR="$BUILD_DIR/CodexMux.app"
ICONSET_DIR="$ROOT_DIR/.build/CodexMux.iconset"
ICON_SOURCE_PATH="$ROOT_DIR/assets/icon.png"
APP_ICON_PATH="$ROOT_DIR/assets/CodexMux.icns"
SYNC_TRACKED_BUNDLE="${CODEXMUX_SYNC_TRACKED_BUNDLE:-1}"

if ! command -v sips >/dev/null 2>&1; then
    echo "error: sips is required to render icon assets from $ICON_SOURCE_PATH" >&2
    exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
    echo "error: iconutil is required to build $APP_ICON_PATH" >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required to generate the native macOS project" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$APP_ICON_PATH"

xcodegen generate --spec "$ROOT_DIR/project.yml"
xcodebuild \
  -project "$ROOT_DIR/CodexMux.xcodeproj" \
  -scheme CodexMux \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

rm -rf "$APP_DIR"
cp -R "$XCODE_APP_DIR" "$APP_DIR"

if [[ "$SYNC_TRACKED_BUNDLE" == "1" ]]; then
    rm -rf "$TRACKED_BUNDLE_DIR/CodexMux.app"
    cp -R "$APP_DIR" "$TRACKED_BUNDLE_DIR/CodexMux.app"
fi

echo "$APP_DIR"
