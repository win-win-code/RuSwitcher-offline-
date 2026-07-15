#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RuSwitcher"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
BUILD_DIR="$PROJECT_DIR/.build/apple/Products/Release"
VERSION_JSON="$PROJECT_DIR/version.json"

# version.json — единый источник правды. Значения в Info.plist в репо
# игнорируются: скрипт штампует CFBundleShortVersionString и CFBundleVersion
# в копию Info.plist внутри собранного бандла.
SHORT_VERSION=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$VERSION_JSON'))['version'])")
BUILD_VERSION=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$VERSION_JSON')).get('build','1'))")
DEV_TAG=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$VERSION_JSON')).get('dev',''))")

if [ -z "$SHORT_VERSION" ]; then
    echo "ERROR: could not read version from $VERSION_JSON"
    exit 1
fi

echo "=== Building $APP_NAME v$SHORT_VERSION (build $BUILD_VERSION) ==="

# 1. Собираем release — universal (arm64 + x86_64), чтобы работало и на Intel-маках
cd "$PROJECT_DIR"
NATIVE_ONLY=0
if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]; then
    NATIVE_ONLY=1
    BUILD_DIR="$PROJECT_DIR/.build/release"
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
    export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/ruswitcher-clang-cache}"
    export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/ruswitcher-swiftpm-modules}"
    SWIFT_BUILD_ARGS=(-c release --disable-sandbox --sdk "$SDKROOT" --cache-path /tmp/ruswitcher-swiftpm-cache --scratch-path .build)
else
    SWIFT_BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
fi
if [ "$NATIVE_ONLY" = "1" ]; then
    echo "→ swift build ${SWIFT_BUILD_ARGS[*]} (native)..."
else
    echo "→ swift build ${SWIFT_BUILD_ARGS[*]} (universal)..."
fi
swift build "${SWIFT_BUILD_ARGS[@]}"

# 2. Создаём .app bundle
echo "→ Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 3. Копируем бинарник
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 3a. Самопроверка: бинарь обязан быть universal (arm64 + x86_64), иначе Intel-маки не запустят
ARCHS=$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")
if [ "$NATIVE_ONLY" = "0" ] && [[ "$ARCHS" != *"arm64"* || "$ARCHS" != *"x86_64"* ]]; then
    echo "ERROR: бинарь не universal (получено: $ARCHS)"; exit 1
fi
echo "→ Binary archs OK: $ARCHS"

# 4. Копируем Info.plist и штампуем версию из version.json
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP_BUNDLE/Contents/Info.plist"
# Dev-метка (буква) для непубликуемых сборок — пусто для релиза. Показывается в About/меню.
/usr/libexec/PlistBuddy -c "Set :RSDevTag $DEV_TAG" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :RSDevTag string $DEV_TAG" "$APP_BUNDLE/Contents/Info.plist"
echo "→ Stamped Info.plist: CFBundleShortVersionString=$SHORT_VERSION$DEV_TAG CFBundleVersion=$BUILD_VERSION"

# 5. Копируем иконку
cp "$PROJECT_DIR/RuSwitcher.icns" "$APP_BUNDLE/Contents/Resources/RuSwitcher.icns"

# 6. Создаём PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 7. По умолчанию используем локальную ad-hoc подпись. Для релизной подписи передайте
#    SIGN_ID="Developer ID Application: ..." явно в окружении.
SIGN_ID="${SIGN_ID:--}"
echo "→ Code signing with: $SIGN_ID"
codesign --force --deep --sign "$SIGN_ID" \
    --options runtime \
    --entitlements "$PROJECT_DIR/RuSwitcher.entitlements" \
    "$APP_BUNDLE"

echo ""
echo "=== Done! ==="
echo "App bundle: $APP_BUNDLE"
echo "Signed with: $SIGN_ID"
echo ""
echo "To install:"
echo "  cp -R $APP_BUNDLE /Applications/"
