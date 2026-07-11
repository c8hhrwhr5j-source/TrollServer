#!/bin/bash
# ============================================================
#  build_testboot.sh — 编译极简探针 dylib (仅用于诊断)
#  不链 UIKit，无 hook，仅验证 dylib 能否被 dyld 加载
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS="14.0"

echo "==> SDK: $SDK"
echo "==> 编译 libTestBoot.dylib (诊断探针) ..."

clang -arch arm64 -arch arm64e \
      -isysroot "$SDK" \
      -miphoneos-version-min="$MIN_IOS" \
      -dynamiclib \
      -fobjc-arc \
      libTestBoot.m \
      -framework Foundation \
      -o libTestBoot.dylib

ldid -S libTestBoot.dylib 2>/dev/null || true

echo "✅ 已生成: $SCRIPT_DIR/libTestBoot.dylib"
echo ""
echo "用 TrollFools 注入微信，打开微信后检查:"
echo "  Filza: /tmp/libTestBoot.log"
echo "  或: /var/mobile/Documents/libTestBoot.log"
echo "  Mac: idevicesyslog | grep TestBoot"
