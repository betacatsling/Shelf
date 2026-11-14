#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Shelf"
APP_BUNDLE="$PROJECT_DIR/${APP_NAME}.app"
BUILD_TMP="$PROJECT_DIR/.build_bundle"

echo "==> Preparing build directories..."
rm -rf "$BUILD_TMP"
mkdir -p "$BUILD_TMP"

# Choose SDK: If CommandLineTools MacOSX27.0.sdk lacks libSwiftUIMacros.dylib, use MacOSX26.sdk when available
SDK_PATH="$(xcrun --show-sdk-path)"
if [[ ! -f "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]] && [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk" ]]; then
    SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
fi
echo "==> Using SDK: $SDK_PATH"

echo "==> Generating macOS AppIcon.icns..."
ICONSET_DIR="$BUILD_TMP/AppIcon.iconset"
swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 "$PROJECT_DIR/scripts/generate_icon.swift" -o "$BUILD_TMP/gen_icon"
"$BUILD_TMP/gen_icon" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$BUILD_TMP/AppIcon.icns"

echo "==> Compiling Shelf native macOS binary (Release -O)..."
SOURCES=(
    "$PROJECT_DIR"/Sources/Shelf/*.swift
    "$PROJECT_DIR"/Sources/Shelf/Models/*.swift
    "$PROJECT_DIR"/Sources/Shelf/Store/*.swift
    "$PROJECT_DIR"/Sources/Shelf/Views/*.swift
)

swiftc \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macos14.0 \
    -O \
    -parse-as-library \
    "${SOURCES[@]}" \
    -o "$BUILD_TMP/$APP_NAME"

echo "==> Assembling ${APP_NAME}.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_TMP/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BUILD_TMP/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh_CN</string>
        <string>en</string>
    </array>
    <key>CFBundleDisplayName</key>
    <string>作品库</string>
    <key>CFBundleExecutable</key>
    <string>Shelf</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.shelf.mediatracker</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>作品库</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE"
rm -rf "$BUILD_TMP"

echo "==> Built successfully: $APP_BUNDLE"
