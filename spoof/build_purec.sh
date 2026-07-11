#!/bin/bash
# ============================================================
#  build_purec.sh — 编译纯C探针 (三个变体，逐一定位问题)
#
#  变体1: libPureC_arm64.dylib  — 纯C, 仅arm64
#  变体2: libPureC_arm64e.dylib — 纯C, arm64+arm64e
#  变体3: libTestBoot_arm64.dylib — Foundation, 仅arm64
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS="14.0"

echo "==> SDK: $SDK"
echo "==> 变体1: 纯C, 仅 arm64"
clang -arch arm64 \
      -isysroot "$SDK" \
      -miphoneos-version-min="$MIN_IOS" \
      -dynamiclib \
      libPureC.m \
      -o libPureC_arm64.dylib
ldid -S libPureC_arm64.dylib 2>/dev/null || true
echo "   ✅ libPureC_arm64.dylib"

echo "==> 变体2: 纯C, arm64 + arm64e"
clang -arch arm64 -arch arm64e \
      -isysroot "$SDK" \
      -miphoneos-version-min="$MIN_IOS" \
      -dynamiclib \
      libPureC.m \
      -o libPureC_arm64e.dylib
ldid -S libPureC_arm64e.dylib 2>/dev/null || true
echo "   ✅ libPureC_arm64e.dylib"

echo "==> 变体3: Foundation, 仅 arm64"
clang -arch arm64 \
      -isysroot "$SDK" \
      -miphoneos-version-min="$MIN_IOS" \
      -dynamiclib \
      -fobjc-arc \
      libTestBoot.m \
      -framework Foundation \
      -o libTestBoot_arm64.dylib
ldid -S libTestBoot_arm64.dylib 2>/dev/null || true
echo "   ✅ libTestBoot_arm64.dylib"

echo ""
echo "=============================="
echo " 测试步骤（按顺序，每个单独注入微信测试）:"
echo ""
echo " 1️⃣ 注入 libPureC_arm64.dylib (纯C, arm64) → 查 /tmp/libPureC.log"
echo " 2️⃣ 注入 libPureC_arm64e.dylib (纯C, arm64e) → 查 /tmp/libPureC.log"
echo " 3️⃣ 注入 libTestBoot_arm64.dylib (Foundation, arm64) → 查 /tmp/libTestBoot.log"
echo ""
echo " 每步都只注入一个 dylib，不要同时注入多个。"
echo "=============================="
