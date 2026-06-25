#!/bin/bash
# ============================================================
#  TrollServer IPA 构建脚本
#  用法:
#    chmod +x build.sh
#    ./build.sh             构建 Release IPA
#    ./build.sh debug       构建 Debug IPA (含调试符号)
#    ./build.sh clean       清理构建产物
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
SRC_DIR="$PROJECT_DIR/TrollServer"
BUILD_DIR="$PROJECT_DIR/build"
DERIVED_DATA="$PROJECT_DIR/DerivedData"
PAYLOAD_DIR="$BUILD_DIR/Payload"
APP_NAME="TrollServer"
BUNDLE_ID="com.trollserver.fileserver"
OUTPUT_IPA="$BUILD_DIR/${APP_NAME}.ipa"
ICON_SRC="$PROJECT_DIR/123.png"
ICON_DIR="$SRC_DIR/Assets.xcassets/AppIcon.appiconset"

# 编译模式
CONFIGURATION="Release"
if [ "$1" = "debug" ]; then CONFIGURATION="Debug"; fi
if [ "$1" = "clean" ]; then
    echo "[Clean] 清理构建产物..."
    rm -rf "$BUILD_DIR" "$DERIVED_DATA"
    echo "[Clean] 完成"
    exit 0
fi

echo "========================================"
echo " TrollServer IPA 构建工具"
echo " 配置: $CONFIGURATION"
echo "========================================"

# ---- 0. 从 123.png 生成 AppIcon 多尺寸图片 ----
echo "[1/4] 生成 AppIcon 多尺寸图片..."

generate_icon() {
    local size=$1
    local name=$2
    sips -z $size $size "$ICON_SRC" --out "$ICON_DIR/$name" > /dev/null 2>&1
    echo "  -> $name ($size x $size)"
}

mkdir -p "$ICON_DIR"
generate_icon 1024 "icon-1024.png"
generate_icon 120  "icon-120.png"
generate_icon 180  "icon-180.png"
generate_icon 76   "icon-76.png"
generate_icon 152  "icon-152.png"

# ---- 1. 编译 Swift 项目 ----
echo "[2/4] 使用 xcodebuild 编译 (${CONFIGURATION})..."

# 用 swiftc 直接编译（免 Xcode 项目）
mkdir -p "$BUILD_DIR"

SWIFT_FILES=(
    "$SRC_DIR/main.swift"
    "$SRC_DIR/AppDelegate.swift"
    "$SRC_DIR/ViewController.swift"
    "$SRC_DIR/DaemonServerRunner.swift"
    "$SRC_DIR/DaemonInstaller.swift"
    "$SRC_DIR/WebDAVServer.swift"
    "$SRC_DIR/ScriptControlServer.swift"
    "$SRC_DIR/FileOperations.swift"
    "$SRC_DIR/HTTPRequestParser.swift"
)

# 创建临时 Info.plist 复制（避免编译时路径问题）
TMP_INFO="$BUILD_DIR/Info.plist"
cp "$SRC_DIR/Info.plist" "$TMP_INFO"

# 编译参数
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_VERSION="14.0"
ARCH="arm64"
SWIFT_FLAGS="-sdk $SDK_PATH -target ${ARCH}-apple-ios${MIN_VERSION} -O -whole-module-optimization"
DEBUG_FLAGS=""
if [ "$CONFIGURATION" = "Debug" ]; then
    SWIFT_FLAGS="-sdk $SDK_PATH -target ${ARCH}-apple-ios${MIN_VERSION} -Onone -g"
fi

echo "  Swift flags: $SWIFT_FLAGS"

# 编译为可执行文件
swiftc \
    ${SWIFT_FILES[@]} \
    $SWIFT_FLAGS \
    -framework UIKit \
    -framework Foundation \
    -framework Network \
    -Xlinker -rpath -Xlinker /usr/lib/swift \
    -Xlinker -sdk_version -Xlinker $(xcrun --sdk iphoneos --show-sdk-version) \
    -o "$BUILD_DIR/$APP_NAME"

echo "  [OK] 编译完成: $BUILD_DIR/$APP_NAME"

# ---- 2. 打包为 .app Bundle ----
echo "[3/4] 打包 .app Bundle..."

APP_DIR="$PAYLOAD_DIR/${APP_NAME}.app"
mkdir -p "$APP_DIR"

# 复制可执行文件
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/$APP_NAME"
chmod +x "$APP_DIR/$APP_NAME"

# 复制 Info.plist
cp "$SRC_DIR/Info.plist" "$APP_DIR/Info.plist"

# 复制 AppIcon
cp -r "$SRC_DIR/Assets.xcassets/AppIcon.appiconset" "$APP_DIR/"

# 创建 PkgInfo
echo "APPL????" > "$APP_DIR/PkgInfo"

echo "  [OK] .app Bundle 创建完成: $APP_DIR"

# ---- 3. 打包为 IPA ----
echo "[4/4] 打包 IPA..."

cd "$BUILD_DIR"
zip -qr "$OUTPUT_IPA" Payload/
cd "$PROJECT_DIR"

echo "  [OK] IPA 创建完成: $OUTPUT_IPA"

# ---- 结果 ----
IPA_SIZE=$(du -h "$OUTPUT_IPA" | cut -f1)
echo ""
echo "========================================"
echo " 构建成功!"
echo "========================================"
echo " 文件:    $OUTPUT_IPA"
echo " 大小:    $IPA_SIZE"
echo " 架构:    arm64"
echo " 系统:    iOS $MIN_VERSION+"
echo " Bundle:  $BUNDLE_ID"
echo " 图标:    由 $ICON_SRC 生成"
echo ""
echo " 安装:    通过巨魔(TrollStore)安装 IPA 文件"
echo ""
