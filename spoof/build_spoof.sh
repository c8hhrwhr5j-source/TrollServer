#!/bin/bash
# ============================================================
#  build_spoof.sh — 编译 libiPadSpoof 三变体 (arm64 / arm64e)
#  每个变体独立编译，失败不阻断其他变体
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

# 计算文件大小的辅助函数
filesize() {
    if [ -f "$1" ]; then
        stat -f%z "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || echo "?"
    else
        echo "N/A"
    fi
}

# ── 变体1: 完整版 ──
echo "=== 变体1: libiPadSpoof.dylib (完整版) ==="
if clang -arch arm64 -arch arm64e \
      $COMMON_FLAGS \
      $SRCS \
      -framework Foundation \
      -framework UIKit \
      -o libiPadSpoof.dylib; then
    ldid -S libiPadSpoof.dylib 2>/dev/null || true
    echo "   ✅ libiPadSpoof.dylib ($(filesize libiPadSpoof.dylib) bytes)"
else
    echo "   ❌ libiPadSpoof.dylib 编译失败"
fi
echo ""

# ── 变体2: 无UIKit版 ──
echo "=== 变体2: libiPadSpoof_noUI.dylib (无 UIKit) ==="
if clang -arch arm64 -arch arm64e \
      $COMMON_FLAGS \
      -DNO_UIKIT=1 \
      $SRCS \
      -framework Foundation \
      -o libiPadSpoof_noUI.dylib; then
    ldid -S libiPadSpoof_noUI.dylib 2>/dev/null || true
    echo "   ✅ libiPadSpoof_noUI.dylib ($(filesize libiPadSpoof_noUI.dylib) bytes)"
else
    echo "   ❌ libiPadSpoof_noUI.dylib 编译失败"
fi
echo ""

# ── 变体3: 弱链UIKit版 (用 -Wl 传递弱链接) ──
echo "=== 变体3: libiPadSpoof_weakUI.dylib (弱链 UIKit) ==="
if clang -arch arm64 -arch arm64e \
      $COMMON_FLAGS \
      $SRCS \
      -framework Foundation \
      -Wl,-weak_framework,UIKit \
      -o libiPadSpoof_weakUI.dylib; then
    ldid -S libiPadSpoof_weakUI.dylib 2>/dev/null || true
    echo "   ✅ libiPadSpoof_weakUI.dylib ($(filesize libiPadSpoof_weakUI.dylib) bytes)"
else
    echo "   ❌ libiPadSpoof_weakUI.dylib 编译失败"
fi

echo ""
echo "=============================="
echo " 产物列表:"
ls -la *.dylib 2>/dev/null || echo "（无 .dylib 文件）"
echo ""
echo " 测试步骤（每次只注入一个到微信）:"
echo " 1️⃣ libiPadSpoof_noUI.dylib   — 无UIKit，验证崩溃是否消失"
echo " 2️⃣ libiPadSpoof_weakUI.dylib — 弱链UIKit，验证弱链接是否可行"
echo " 3️⃣ libiPadSpoof.dylib        — 完整版（若前两步通过）"
echo ""
echo " 日志位置: Filza 搜索 libiPadSpoof_boot.log"
echo "=============================="
