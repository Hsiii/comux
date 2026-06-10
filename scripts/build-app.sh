#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/apple"
DERIVED_DATA_DIR="$ROOT_DIR/.build/xcodebuild"
XCODE_APP_DIR="$DERIVED_DATA_DIR/Build/Products/Debug/comux.app"
TRACKED_DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$BUILD_DIR/comux.app"
ICONSET_DIR="$ROOT_DIR/.build/comux.iconset"
ICON_SOURCE_PATH="$ROOT_DIR/assets/app-icon.png"
APP_ICON_PATH="$ROOT_DIR/assets/comux.icns"
GENERATED_ICON_PATH="$ROOT_DIR/.build/comux.icns"
ASSETS_SOURCE_DIR="$ROOT_DIR/assets"
APP_ASSETS_DIR="$APP_DIR/Contents/Resources/assets"

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
mkdir -p "$TRACKED_DIST_DIR"

if [[ ! -f "$APP_ICON_PATH" ]]; then
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
  iconutil -c icns "$ICONSET_DIR" -o "$GENERATED_ICON_PATH"
  APP_ICON_PATH="$GENERATED_ICON_PATH"
fi

xcodegen generate --spec "$ROOT_DIR/project.yml"
xcodebuild \
  -project "$ROOT_DIR/Comux.xcodeproj" \
  -scheme Comux \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

rm -rf "$APP_DIR"
cp -R "$XCODE_APP_DIR" "$APP_DIR"
strip -S "$APP_DIR/Contents/MacOS/comux"
if [[ -f "$APP_ICON_PATH" ]]; then
  mkdir -p "$APP_DIR/Contents/Resources"
  rm -rf "$APP_ASSETS_DIR"
  cp -R "$ASSETS_SOURCE_DIR" "$APP_ASSETS_DIR"
  rm -f "$APP_ASSETS_DIR/.DS_Store"
  cp "$APP_ICON_PATH" "$APP_DIR/Contents/Resources/comux.icns"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string comux" "$APP_DIR/Contents/Info.plist"
  codesign --force --sign - "$APP_DIR"
fi
rm -rf "$ROOT_DIR/Comux.xcodeproj"
rm -rf "$TRACKED_DIST_DIR/comux.app"
cp -R "$APP_DIR" "$TRACKED_DIST_DIR/comux.app"

echo "$APP_DIR"
