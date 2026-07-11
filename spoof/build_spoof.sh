#!/bin/bash
# ============================================================
#  build_spoof.sh — 编译 libiPadSpoof 三变体 (arm64 / arm64e)
#
#  必须在 macOS + Xcode 命令行工具 下运行
#
#  产物:
#    libiPadSpoof.dylib          — 完整版 (Foundation + UIKit)
#    libiPadSpoof_noUI.dylib     — 无UIKit版 (仅 Foundation，用于诊断)
#    libiPadSpoof_weakUI.dylib   — 弱链UIKit版 (UIKit weak-link)
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS="14.0"
COMMON_FLAGS="-isysroot $SDK -miphoneos-version-min=$MIN_IOS -dynamiclib -fobjc-arc"
SRCS="fishhook.c libiPadSpoof.m"

echo "==> SDK: $SDK"
echo ""

# ── 变体1: 完整版 (Foundation + UIKit 强链接) ──
echo "=== 变体1: libiPadSpoof.dylib (完整版, 强链 UIKit) ==="
clang -arch arm64 -arch arm64e \
      $COMMON_FLAGS \
      $SRCS \
      -framework Foundation \
      -framework UIKit \
      -o libiPadSpoof.dylib
ldid -S libiPadSpoof.dylib 2>/dev/null || true
echo "   ✅ libiPadSpoof.dylib ($(stat -f%z libiPadSpoof.dylib 2>/dev/null || wc -c < libiPadSpoof.dylib | tr -d ' ') bytes)"
echo ""

# ── 变体2: 无UIKit版 (仅 Foundation) ──
echo "=== 变体2: libiPadSpoof_noUI.dylib (无 UIKit, 仅 Foundation) ==="
clang -arch arm64 -arch arm64e \
      $COMMON_FLAGS \
      -DNO_UIKIT=1 \
      $SRCS \
      -framework Foundation \
      -o libiPadSpoof_noUI.dylib
ldid -S libiPadSpoof_noUI.dylib 2>/dev/null || true
echo "   ✅ libiPadSpoof_noUI.dylib ($(stat -f%z libiPadSpoof_noUI.dylib 2>/dev/null || wc -c < libiPadSpoof_noUI.dylib | tr -d ' ') bytes)"
echo ""

# ── 变体3: 弱链UIKit版 (Foundation + UIKit weak-link) ──
echo "=== 变体3: libiPadSpoof_weakUI.dylib (弱链 UIKit) ==="
clang -arch arm64 -arch arm64e \
      $COMMON_FLAGS \
      $SRCS \
      -framework Foundation \
      -weak_framework UIKit \
      -o libiPadSpoof_weakUI.dylib
ldid -S libiPadSpoof_weakUI.dylib 2>/dev/null || true
echo "   ✅ libiPadSpoof_weakUI.dylib ($(stat -f%z libiPadSpoof_weakUI.dylib 2>/dev/null || wc -c < libiPadSpoof_weakUI.dylib | tr -d ' ') bytes)"

echo ""
echo "=============================="
echo " 测试步骤（每次只注入一个到微信）:"
echo ""
echo " 1️⃣ libiPadSpoof_noUI.dylib   — 无UIKit，验证崩溃是否消失"
echo " 2️⃣ libiPadSpoof_weakUI.dylib — 弱链UIKit，验证弱链接是否可行"
echo " 3️⃣ libiPadSpoof.dylib        — 完整版（若前两步通过）"
echo ""
echo " 日志位置: Filza 打开微信沙箱 tmp 目录"
echo "   路径: /var/mobile/Containers/Data/Application/<微信UUID>/tmp/libiPadSpoof_boot.log"
echo "   或用 Filza 搜索 libiPadSpoof_boot.log"
echo "=============================="
