#!/bin/bash

# ============================================================
#  无忧辅助控制 - 脚本控制服务构建脚本
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/TrollServer"
BUILD_DIR="$SCRIPT_DIR/build"

APP_NAME="TrollServer"
BUNDLE_ID="com.trollserver.app"
VERSION="1.0"

# 清理旧构建
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/$APP_NAME.app"

# 编译所有 Swift 源文件
echo "[*] Compiling..."
SWIFT_FILES=(
    "main.swift"
    "AppDelegate.swift"
    "DaemonServerRunner.swift"
    "ScriptControlServer.swift"
    "InstallAPI.swift"
    "SilentInstall.swift"
    "ViewController.swift"
)

SRC_ARGS=""
for f in "${SWIFT_FILES[@]}"; do
    SRC_ARGS="$SRC_ARGS $SRC_DIR/$f"
done

if [ "${1:-}" = "debug" ]; then
    swiftc $SRC_ARGS \
        -sdk $(xcrun --sdk iphoneos --show-sdk-path) \
        -target arm64-apple-ios15.0 \
        -O0 \
        -g \
        -framework UIKit \
        -framework Foundation \
        -framework Network \
        -lz \
        -o "$BUILD_DIR/$APP_NAME.app/$APP_NAME"
else
    swiftc $SRC_ARGS \
        -sdk $(xcrun --sdk iphoneos --show-sdk-path) \
        -target arm64-apple-ios15.0 \
        -O \
        -framework UIKit \
        -framework Foundation \
        -framework Network \
        -lz \
        -o "$BUILD_DIR/$APP_NAME.app/$APP_NAME"
fi

echo "[*] Copying Info.plist..."
cp "$SRC_DIR/Info.plist" "$BUILD_DIR/$APP_NAME.app/"

echo "[*] Copying app icons..."
ICONSET_DIR="$SRC_DIR/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICONSET_DIR" ]; then
    cp "$ICONSET_DIR"/*.png "$BUILD_DIR/$APP_NAME.app/"
fi

echo "[*] Signing..."
ldid2 -S"$SRC_DIR/TrollServer.entitlements" "$BUILD_DIR/$APP_NAME.app/$APP_NAME"

echo "[*] Creating IPA..."
mkdir -p "$BUILD_DIR/Payload"
cp -R "$BUILD_DIR/$APP_NAME.app" "$BUILD_DIR/Payload/"

rm -f "$BUILD_DIR/$APP_NAME.ipa"
cd "$BUILD_DIR"
zip -qr "$APP_NAME.ipa" Payload
rm -rf Payload

echo ""
echo "[✓] Build complete: $BUILD_DIR/$APP_NAME.ipa"
echo "    Install via TrollStore on your device."
