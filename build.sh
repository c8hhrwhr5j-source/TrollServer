#!/bin/bash
# ============================================================
#  TrollServer 构建脚本
#  用法:
#    ./build.sh             构建 Release IPA
#    ./build.sh debug       构建 Debug IPA (含调试符号)
#    ./build.sh daemon      构建系统级 daemon 纯二进制
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
OUTPUT_DAEMON="$BUILD_DIR/${APP_NAME}d"
ICON_SRC="$PROJECT_DIR/123.png"
ICON_DIR="$SRC_DIR/Assets.xcassets/AppIcon.appiconset"

# 编译模式
CONFIGURATION="Release"
BUILD_TARGET="ipa"
if [ "$1" = "debug" ]; then CONFIGURATION="Debug"; BUILD_TARGET="ipa"; fi
if [ "$1" = "daemon" ]; then BUILD_TARGET="daemon"; fi
if [ "$1" = "clean" ]; then
    echo "[Clean] 清理构建产物..."
    rm -rf "$BUILD_DIR" "$DERIVED_DATA"
    echo "[Clean] 完成"
    exit 0
fi

# 公共：获取 SDK 路径和参数
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_VERSION="14.0"
ARCH="arm64"
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)

# ============================================================
#  DAEMON 构建
# ============================================================
if [ "$BUILD_TARGET" = "daemon" ]; then
    echo "========================================"
    echo " TrollServer 系统级 Daemon 构建工具"
    echo "========================================"

    mkdir -p "$BUILD_DIR"

    # 仅编译 daemon 需要的文件（无 UIKit，无 UI 文件）
    DAEMON_SWIFT_FILES=(
        "$SRC_DIR/main.swift"
        "$SRC_DIR/TrollHTTPServer.swift"
        "$SRC_DIR/ServiceMonitor.swift"
        "$SRC_DIR/BootstrapServices.swift"
        "$SRC_DIR/UDPBroadcaster.swift"
    )

    SWIFT_FLAGS="-D DAEMON_MODE -sdk $SDK_PATH -target ${ARCH}-apple-ios${MIN_VERSION} -O -whole-module-optimization"

    echo "[1/3] 编译 daemon 二进制..."
    echo "  源文件: ${#DAEMON_SWIFT_FILES[@]} 个"
    echo "  Swift flags: $SWIFT_FLAGS"

    swiftc \
        ${DAEMON_SWIFT_FILES[@]} \
        $SWIFT_FLAGS \
        -framework Foundation \
        -framework Network \
        -Xlinker -dead_strip \
        -Xlinker -sdk_version -Xlinker $SDK_VERSION \
        -o "$OUTPUT_DAEMON"

    # Strip 符号表，减小体积
    strip -x "$OUTPUT_DAEMON" 2>/dev/null || true

    DAEMON_SIZE=$(du -h "$OUTPUT_DAEMON" | cut -f1)
    echo "  [OK] 编译完成"

    # 复制 plist 到 build 目录
    echo "[2/3] 准备 LaunchDaemon plist..."
    cp "$PROJECT_DIR/com.trollserver.daemon.plist" "$BUILD_DIR/com.trollserver.daemon.plist"

    echo "[3/3] 生成自包含安装脚本..."

    # 把二进制 + plist 用 base64 编码塞进脚本里，一个文件搞定
    B64_BIN=$(base64 "$OUTPUT_DAEMON" | tr -d '\n')
    B64_PLIST=$(base64 "$PROJECT_DIR/com.trollserver.daemon.plist" | tr -d '\n')

    cat > "$BUILD_DIR/trollserverd-install.sh" << INSTALL_SCRIPT
#!/bin/bash
# ===================================================
#  TrollServer Daemon — 自包含安装脚本
#  一个文件搞定，传到手机上直接跑！
#
#  用法:
#    chmod +x trollserverd-install.sh
#    ./trollserverd-install.sh
# ===================================================
set -e

DAEMON_PATH="/usr/local/bin/trollserverd"
PLIST_PATH="/Library/LaunchDaemons/com.trollserver.daemon.plist"
LOG_DIR="/var/mobile/Library/Logs"
TMP="/tmp/.trollserver_install"

echo "=== TrollServer Daemon 一键安装 ==="
echo ""

# 1. 检查权限（必须以 root 运行）
if [ "\$(id -u)" != "0" ]; then
    echo "❌ 请以 root 身份运行此脚本"
    echo "   sudo bash \$0"
    exit 1
fi

# 2. 停止旧服务
if launchctl list 2>/dev/null | grep -q com.trollserver.daemon; then
    echo "[1/6] 停止旧 daemon..."
    launchctl unload "\$PLIST_PATH" 2>/dev/null || true
    sleep 1
else
    echo "[1/6] 无旧 daemon 运行，跳过"
fi

# 3. 解码并写入二进制
echo "[2/6] 解码二进制..."
mkdir -p "\$TMP"
echo '$B64_BIN' | base64 -d > "\$TMP/trollserverd"
chmod 755 "\$TMP/trollserverd"

# 4. 解码并写入 plist
echo "[3/6] 解码 LaunchDaemon plist..."
echo '$B64_PLIST' | base64 -d > "\$TMP/com.trollserver.daemon.plist"

# 5. 安装文件
echo "[4/6] 安装文件..."
mkdir -p /usr/local/bin "\$LOG_DIR"
mv "\$TMP/trollserverd" "\$DAEMON_PATH"
mv "\$TMP/com.trollserver.daemon.plist" "\$PLIST_PATH"
chown root:wheel "\$DAEMON_PATH" "\$PLIST_PATH"
chmod 755 "\$DAEMON_PATH"
chmod 644 "\$PLIST_PATH"
rm -rf "\$TMP"

# 6. 加载服务
echo "[5/6] 加载 daemon..."
launchctl load "\$PLIST_PATH"
sleep 1

# 7. 验证
echo "[6/6] 验证..."
if launchctl list | grep -q com.trollserver.daemon; then
    BIN_SIZE=\$(du -h "\$DAEMON_PATH" | cut -f1)
    echo ""
    echo "========================================"
    echo " ✅ 安装成功!"
    echo "========================================"
    echo " 二进制: \$DAEMON_PATH (\$BIN_SIZE)"
    echo " Plist:  \$PLIST_PATH"
    echo " 日志:   \$LOG_DIR/trollserver.log"
    echo ""
    echo " 管理命令:"
    echo "   查看状态: launchctl list | grep trollserver"
    echo "   停止服务: launchctl unload \$PLIST_PATH"
    echo "   启动服务: launchctl load \$PLIST_PATH"
    echo "   实时日志: tail -f \$LOG_DIR/trollserver.log"
    echo ""
else
    echo ""
    echo "❌ daemon 启动失败，查看日志:"
    echo "   cat \$LOG_DIR/trollserver.log"
    echo "   cat \$LOG_DIR/trollserver_err.log"
    exit 1
fi
INSTALL_SCRIPT

    chmod +x "$BUILD_DIR/trollserverd-install.sh"
    SCRIPT_SIZE=$(du -h "$BUILD_DIR/trollserverd-install.sh" | cut -f1)

    echo ""
    echo "========================================"
    echo " Daemon 构建成功!"
    echo "========================================"
    echo " 自包含安装脚本:  build/trollserverd-install.sh ($SCRIPT_SIZE)"
    echo ""
    echo " === 部署只需一步 ==="
    echo " 把 trollserverd-install.sh 传到手机上，SSH 执行:"
    echo ""
    echo "   scp build/trollserverd-install.sh root@<设备IP>:/tmp/"
    echo "   ssh root@<设备IP> 'bash /tmp/trollserverd-install.sh'"
    echo ""
    echo " 或者在手机上用终端工具(如 NewTerm)直接:"
    echo "   bash /路径/trollserverd-install.sh"
    echo ""
    exit 0
fi

# ============================================================
#  IPA 构建（App 模式）
# ============================================================
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
echo "[2/4] 编译 (${CONFIGURATION})..."

mkdir -p "$BUILD_DIR"

SWIFT_FILES=(
    "$SRC_DIR/main.swift"
    "$SRC_DIR/AppDelegate.swift"
    "$SRC_DIR/ViewController.swift"
    "$SRC_DIR/TrollHTTPServer.swift"
    "$SRC_DIR/KeepAliveManager.swift"
    "$SRC_DIR/ServiceMonitor.swift"
    "$SRC_DIR/BootstrapServices.swift"
    "$SRC_DIR/UDPBroadcaster.swift"
)

# 创建临时 Info.plist 复制
TMP_INFO="$BUILD_DIR/Info.plist"
cp "$SRC_DIR/Info.plist" "$TMP_INFO"

SWIFT_FLAGS="-sdk $SDK_PATH -target ${ARCH}-apple-ios${MIN_VERSION} -O -whole-module-optimization"
if [ "$CONFIGURATION" = "Debug" ]; then
    SWIFT_FLAGS="-sdk $SDK_PATH -target ${ARCH}-apple-ios${MIN_VERSION} -Onone -g"
fi

echo "  Swift flags: $SWIFT_FLAGS"

swiftc \
    ${SWIFT_FILES[@]} \
    $SWIFT_FLAGS \
    -framework UIKit \
    -framework Foundation \
    -framework Network \
    -Xlinker -rpath -Xlinker /usr/lib/swift \
    -Xlinker -sdk_version -Xlinker $SDK_VERSION \
    -o "$BUILD_DIR/$APP_NAME"

echo "  [OK] 编译完成: $BUILD_DIR/$APP_NAME"

# ---- 2. 打包为 .app Bundle ----
echo "[3/4] 打包 .app Bundle..."

APP_DIR="$PAYLOAD_DIR/${APP_NAME}.app"
mkdir -p "$APP_DIR"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/$APP_NAME"
chmod +x "$APP_DIR/$APP_NAME"

cp "$SRC_DIR/Info.plist" "$APP_DIR/Info.plist"
cp -r "$SRC_DIR/Assets.xcassets/AppIcon.appiconset" "$APP_DIR/"

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
