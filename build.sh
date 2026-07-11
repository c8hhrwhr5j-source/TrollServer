#!/bin/bash
# ============================================================
#  TrollServer 构建脚本 v2.1
#  用法:
#    ./build.sh             构建 Release IPA
#    ./build.sh debug       构建 Debug IPA (含调试符号)
#    ./build.sh daemon      构建系统级 daemon 纯二进制
#    ./build.sh all         构建 IPA + daemon (完整构建)
#    ./build.sh validate    预打包检查（不构建）
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

# ============================================================
#  预打包环境校验 (所有目标共享)
# ============================================================
run_validate() {
    local errors=0
    local warnings=0
    echo "========================================"
    echo " TrollServer 预打包审查"
    echo "========================================"
    echo ""

    # ---- 编译环境 ----
    echo "--- [1/7] 编译环境 ---"
    if ! command -v swiftc &>/dev/null; then
        echo "  ❌ swiftc 未找到（需要 Xcode Command Line Tools）"
        ((errors++))
    else
        local ver=$(swiftc --version | head -1)
        echo "  ✅ $ver"
    fi
    if ! command -v xcrun &>/dev/null; then
        echo "  ❌ xcrun 未找到"
        ((errors++))
    else
        echo "  ✅ xcrun 可用"
    fi
    xcrun --sdk iphoneos --show-sdk-path &>/dev/null && echo "  ✅ iPhoneOS SDK 可用" || { echo "  ❌ iPhoneOS SDK 不可用"; ((errors++)); }

    # ---- 必需源文件 ----
    echo "--- [2/7] 必需源文件 ---"
    local required_files=(
        "main.swift"
        "AppDelegate.swift"
        "ViewController.swift"
        "TrollHTTPServer.swift"
        "ShellRunner.swift"
        "KeepAliveManager.swift"
        "SilentAudioPlayer.swift"
        "ServiceMonitor.swift"
        "BootstrapServices.swift"
        "UDPBroadcaster.swift"
        "DaemonBootstrap.swift"
        "SpoofConfig.swift"
        "MobileGestalt.swift"
    )
    for f in "${required_files[@]}"; do
        if [ -f "$SRC_DIR/$f" ]; then
            echo "  ✅ $f"
        else
            echo "  ❌ $f 缺失!"
            ((errors++))
        fi
    done

    # ---- 配置文件 ----
    echo "--- [3/7] 配置文件 ---"
    [ -f "$SRC_DIR/Info.plist" ] && echo "  ✅ Info.plist" || { echo "  ❌ Info.plist 缺失!"; ((errors++)); }
    [ -f "$SRC_DIR/TrollServer.entitlements" ] && echo "  ✅ TrollServer.entitlements" || { echo "  ⚠️  entitlements 缺失（巨魔安装时需要）"; ((warnings++)); }
    [ -f "$PROJECT_DIR/com.trollserver.daemon.plist" ] && echo "  ✅ com.trollserver.daemon.plist" || { echo "  ⚠️  daemon plist 缺失（daemon 构建需要）"; ((warnings++)); }

    # ---- 图标资源 ----
    echo "--- [4/7] 图标资源 ---"
    [ -f "$ICON_SRC" ] && echo "  ✅ $ICON_SRC" || { echo "  ⚠️  $ICON_SRC 不存在（IPA 图标将为默认图标）"; ((warnings++)); }

    # ---- Info.plist 完整性 ----
    echo "--- [5/7] Info.plist 完整性 ---"
    local plist="$SRC_DIR/Info.plist"
    if [ -f "$plist" ]; then
        grep -q "CFBundleIdentifier" "$plist" && echo "  ✅ CFBundleIdentifier: $BUNDLE_ID" || { echo "  ❌ CFBundleIdentifier 缺失"; ((errors++)); }
        grep -q "CFBundleExecutable" "$plist" && echo "  ✅ CFBundleExecutable: $APP_NAME" || { echo "  ❌ CFBundleExecutable 缺失"; ((errors++)); }
        grep -q "MinimumOSVersion" "$plist" && echo "  ✅ MinimumOSVersion" || echo "  ⚠️  MinimumOSVersion 缺失（将使用编译参数）"
        grep -q "CFBundleVersion" "$plist" && echo "  ✅ CFBundleVersion" || { echo "  ❌ CFBundleVersion 缺失"; ((errors++)); }
        grep -q "CFBundleShortVersionString" "$plist" && echo "  ✅ CFBundleShortVersionString" || echo "  ⚠️  CFBundleShortVersionString 缺失"
        grep -q "UIBackgroundModes" "$plist" && echo "  ✅ UIBackgroundModes (后台运行策略)" || echo "  ⚠️  无后台模式声明（App 模式下可能被杀）"
    fi

    # ---- 语法快速检查 ----
    echo "--- [6/7] Swift 语法快速检查 ---"
    SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
    # 使用所有文件一起解析（避免单文件因跨文件引用报错）
    if swiftc -parse -sdk "$SDK_PATH" -target arm64-apple-ios14.0 "$SRC_DIR"/*.swift 2>/dev/null; then
        echo "  ✅ 所有 Swift 文件语法检查通过"
    else
        echo "  ⚠️  Swift 语法检查存在警告（可能是跨文件引用，将在编译时验证）"
    fi

    # ---- API 兼容性检查 ----
    echo "--- [7/7] API 字段兼容性 ---"
    if grep -q '"uuid"' "$SRC_DIR/TrollHTTPServer.swift"; then
        echo "  ✅ /api/device 包含 uuid 字段"
    else
        echo "  ❌ /api/device 缺少 uuid 字段（Go 中控需要）"
        ((errors++))
    fi
    if grep -q '"systemVersion"' "$SRC_DIR/TrollHTTPServer.swift"; then
        echo "  ✅ /api/device 包含 systemVersion 字段"
    else
        echo "  ❌ /api/device 缺少 systemVersion 字段"
        ((errors++))
    fi
    if grep -q '"wifiIP"' "$SRC_DIR/TrollHTTPServer.swift"; then
        echo "  ✅ /api/device 包含 wifiIP 字段"
    else
        echo "  ❌ /api/device 缺少 wifiIP 字段"
        ((errors++))
    fi

    echo ""
    echo "========================================"
    echo " 审查结果: $errors 错误, $warnings 警告"
    echo "========================================"
    if [ $errors -gt 0 ]; then
        echo " ❌ 发现 $errors 个错误，请修复后重试"
        exit 1
    fi
    echo " ✅ 所有检查通过，可以开始构建"
    echo ""
}

# ============================================================
#  参数解析
# ============================================================
CONFIGURATION="Release"
BUILD_TARGET="ipa"

if [ "$1" = "validate" ]; then
    run_validate
    exit 0
fi
if [ "$1" = "debug" ]; then CONFIGURATION="Debug"; BUILD_TARGET="ipa"; fi
if [ "$1" = "daemon" ]; then BUILD_TARGET="daemon"; fi
if [ "$1" = "all" ]; then BUILD_TARGET="all"; fi
if [ "$1" = "clean" ]; then
    echo "[Clean] 清理构建产物..."
    rm -rf "$BUILD_DIR" "$DERIVED_DATA"
    echo "[Clean] 完成"
    exit 0
fi
if [ "$1" = "help" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "TrollServer 构建脚本 v2.1"
    echo ""
    echo "用法: ./build.sh [目标]"
    echo ""
    echo "目标:"
    echo "  (无参数)   构建 Release IPA"
    echo "  debug      构建 Debug IPA (含调试符号)"
    echo "  daemon     构建系统级 daemon 纯二进制 + 自包含安装脚本"
    echo "  all        构建 IPA + daemon (完整构建)"
    echo "  validate   预打包环境 & 代码审查（不构建）"
    echo "  clean      清理所有构建产物"
    echo ""
    exit 0
fi

# 构建前自动校验（除非显式跳过）
if [ "$SKIP_VALIDATE" != "1" ]; then
    run_validate
fi

# 公共：获取 SDK 路径和参数
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_VERSION="14.0"
ARCH="arm64"
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)

# ============================================================
#  DAEMON 构建
# ============================================================
if [ "$BUILD_TARGET" = "daemon" ] || [ "$BUILD_TARGET" = "all" ]; then
    echo "========================================"
    echo " TrollServer 系统级 Daemon 构建工具"
    echo "========================================"

    mkdir -p "$BUILD_DIR"

    # 仅编译 daemon 需要的文件（无 UIKit，无 UI 文件）
    DAEMON_SWIFT_FILES=(
        "$SRC_DIR/main.swift"
        "$SRC_DIR/TrollHTTPServer.swift"
        "$SRC_DIR/ShellRunner.swift"
        "$SRC_DIR/ServiceMonitor.swift"
        "$SRC_DIR/BootstrapServices.swift"
        "$SRC_DIR/UDPBroadcaster.swift"
        "$SRC_DIR/SpoofConfig.swift"
        "$SRC_DIR/MobileGestalt.swift"
    )

    SWIFT_FLAGS="-D DAEMON_MODE -sdk $SDK_PATH -target ${ARCH}-apple-ios${MIN_VERSION} -O -whole-module-optimization"

    echo "[1/3] 编译 daemon 二进制..."
    echo "  源文件: ${#DAEMON_SWIFT_FILES[@]} 个"
    echo "  Swift flags: $SWIFT_FLAGS"

    swiftc \
        ${DAEMON_SWIFT_FILES[@]} \
        $SWIFT_FLAGS \
        -framework Foundation \
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

    # 如果只是 daemon 构建则在此退出，all 模式继续到 IPA
    if [ "$BUILD_TARGET" = "daemon" ]; then
        exit 0
    fi
    echo ""
    echo "→ 继续构建 IPA..."
    echo ""
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
    "$SRC_DIR/ShellRunner.swift"
    "$SRC_DIR/KeepAliveManager.swift"
    "$SRC_DIR/SilentAudioPlayer.swift"
    "$SRC_DIR/ServiceMonitor.swift"
    "$SRC_DIR/BootstrapServices.swift"
    "$SRC_DIR/UDPBroadcaster.swift"
    "$SRC_DIR/DaemonBootstrap.swift"
    "$SRC_DIR/SpoofConfig.swift"
    "$SRC_DIR/SpoofSettingsViewController.swift"
    "$SRC_DIR/MobileGestalt.swift"
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
    -framework AVFoundation \
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
cp "$SRC_DIR/TrollServer.entitlements" "$APP_DIR/"

# 复制 AppIcon（如果有）
if [ -d "$SRC_DIR/Assets.xcassets/AppIcon.appiconset" ]; then
    cp -r "$SRC_DIR/Assets.xcassets/AppIcon.appiconset" "$APP_DIR/"
fi

echo "APPL????" > "$APP_DIR/PkgInfo"

# 注入 entitlements（确保 TrollStore 安装后获得 no-sandbox 等权限）
if command -v ldid &> /dev/null; then
    echo "  🔏 注入 entitlements..."
    if ldid -S"$SRC_DIR/TrollServer.entitlements" "$APP_DIR/$APP_NAME"; then
        echo "  ✅ entitlements 已注入"
    else
        echo "  ⚠️  ldid 注入失败，TrollStore 安装时可能需要手动注入权限"
    fi
else
    echo "  ⚠️  ldid 未安装，请确保通过 TrollStore 安装时手动注入权限:"
    echo "     ldid -S$SRC_DIR/TrollServer.entitlements $APP_DIR/$APP_NAME"
fi

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
