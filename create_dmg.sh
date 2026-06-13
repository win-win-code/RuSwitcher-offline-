#!/bin/bash
set -e

APP_NAME="RuSwitcher"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Единый источник версии — version.json в корне репозитория.
VERSION=$(/usr/bin/python3 -c "import json;print(json.load(open('version.json'))['version'])")
BUILD=$(/usr/bin/python3 -c "import json;print(json.load(open('version.json')).get('build','1'))")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
# Keychain profile used for Apple notarization. Override with NOTARIZE_PROFILE=<name>.
# Skip notarization entirely with SKIP_NOTARIZE=1.
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-notarytool-studio}"
DMG_TEMP="${APP_NAME}-temp.dmg"
VOL_NAME="${APP_NAME}"
BACKGROUND="dmg_background.png"
APP_PATH="${APP_NAME}.app"
DMG_SIZE="10m"

echo "=== Creating styled DMG ==="

# 0. ВСЕГДА пересобираем приложение из исходников. Без этого шага DMG берёт имя
#    из version.json, а payload — из случайно лежащего рядом RuSwitcher.app.
#    Именно так в релиз 2.1.0 попал бандл 2.0.3: имя было 2.1.0, а внутри 2.0.3.
echo "→ Rebuilding app from source (build_app.sh)..."
"$SCRIPT_DIR/build_app.sh"

# 0a. Жёсткая проверка: версия в собранном бандле обязана совпадать с version.json,
#     иначе отказываемся паковать DMG.
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUNDLE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
if [ "$BUNDLE_VERSION" != "$VERSION" ] || [ "$BUNDLE_BUILD" != "$BUILD" ]; then
    echo "ERROR: bundle is $BUNDLE_VERSION (build $BUNDLE_BUILD) but version.json is $VERSION (build $BUILD)."
    echo "       Refusing to ship a version-mismatched DMG."
    exit 1
fi
echo "→ Verified bundle $BUNDLE_VERSION (build $BUNDLE_BUILD) matches version.json"

# Clean up
rm -f "$DMG_NAME" "$DMG_TEMP"

# 1. Create temporary writable DMG
echo "→ Creating temp DMG..."
hdiutil create -volname "$VOL_NAME" -fs HFS+ \
    -size "$DMG_SIZE" -layout NONE "$DMG_TEMP"

# 2. Mount it
echo "→ Mounting..."
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/')
echo "   Mounted at: $MOUNT_DIR"

# 3. Copy app and create Applications symlink
echo "→ Copying app..."
cp -R "$APP_PATH" "$MOUNT_DIR/"
ln -sf /Applications "$MOUNT_DIR/Applications"

# 4. Create .background directory and copy background image
mkdir -p "$MOUNT_DIR/.background"
cp "$BACKGROUND" "$MOUNT_DIR/.background/background.png"

# 5. Apply Finder settings via AppleScript
echo "→ Configuring Finder view..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 760, 500}

        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 13
        set background picture of theViewOptions to file ".background:background.png"

        -- Position: app icon on left, Applications on right
        set position of item "$APP_NAME.app" of container window to {170, 210}
        set position of item "Applications" of container window to {490, 210}

        close
        open

        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# 6. Set volume icon
if [ -f "${APP_NAME}.icns" ]; then
    cp "${APP_NAME}.icns" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
fi

# 7. Finalize permissions
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync

# 8. Unmount
echo "→ Unmounting..."
hdiutil detach "$MOUNT_DIR" -quiet

# 9. Convert to compressed read-only DMG
echo "→ Compressing..."
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"
rm -f "$DMG_TEMP"

# 10. Notarize with Apple (required for Gatekeeper to accept the DMG on end-user Macs).
# Signed-but-unnotarized DMGs trigger "Apple could not verify [app] is free of malware".
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "→ SKIP_NOTARIZE=1 — skipping notarization (DMG will NOT pass Gatekeeper on other Macs)"
else
    echo "→ Submitting to Apple notary service (profile: $NOTARIZE_PROFILE)..."
    xcrun notarytool submit "$DMG_NAME" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    echo "→ Stapling notarization ticket..."
    xcrun stapler staple "$DMG_NAME"
    xcrun stapler validate "$DMG_NAME"
fi

# 11. Записываем sha256 обратно в version.json и cask — хэш механически привязан
#     к реально собранному DMG, а не копируется руками (раньше это расходилось).
DMG_SHA=$(shasum -a 256 "$DMG_NAME" | awk '{print $1}')
echo "→ Writing sha256 into version.json and ruswitcher.rb..."
/usr/bin/python3 - "$DMG_SHA" <<'PY'
import json, sys
sha = sys.argv[1]
with open("version.json") as f:
    data = json.load(f)
data["sha256"] = sha
with open("version.json", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
/usr/bin/sed -i '' -E "s/^([[:space:]]*sha256 \").*(\")/\1${DMG_SHA}\2/" "$SCRIPT_DIR/ruswitcher.rb"
/usr/bin/sed -i '' -E "s/^([[:space:]]*version \").*(\")/\1${VERSION}\2/" "$SCRIPT_DIR/ruswitcher.rb"

echo ""
echo "=== Done! ==="
echo "DMG: $(pwd)/$DMG_NAME ($(du -h "$DMG_NAME" | cut -f1))"
echo "SHA256: $DMG_SHA"
echo "→ version.json and ruswitcher.rb updated with this hash."
