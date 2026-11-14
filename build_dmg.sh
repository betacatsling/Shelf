#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Shelf"
APP_BUNDLE="$PROJECT_DIR/${APP_NAME}.app"
DMG_NAME="${1:-${APP_NAME}.dmg}"
DMG_PATH="$PROJECT_DIR/$DMG_NAME"
STAGE_DIR="$PROJECT_DIR/.build_dmg_stage"

echo "==> Building latest ${APP_NAME}.app (Release)..."
"$PROJECT_DIR/build_app.sh"

echo "==> Staging DMG contents..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

ditto "$APP_BUNDLE" "$STAGE_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGE_DIR/Applications"

# Attach custom volume icon when SetFile is available
ICON_SRC="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$STAGE_DIR/.VolumeIcon.icns"
    if xcrun --find SetFile >/dev/null 2>&1; then
        xcrun SetFile -c icnC "$STAGE_DIR/.VolumeIcon.icns" || true
        xcrun SetFile -a C "$STAGE_DIR" || true
    fi
fi

echo "==> Creating compressed macOS disk image: $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "Shelf (作品库)" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

rm -rf "$STAGE_DIR"
codesign --force --sign - "$DMG_PATH"

echo "==> Verifying DMG integrity..."
hdiutil verify "$DMG_PATH" >/dev/null

echo "==> DMG ready: $DMG_PATH ($(du -h "$DMG_PATH" | awk '{print $1}'))"
