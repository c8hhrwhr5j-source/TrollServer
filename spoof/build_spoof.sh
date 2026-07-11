#!/bin/bash
# ============================================================
#  build_spoof.sh — 编译 libiPadSpoof.dylib (arm64 / iOS)
#
#  必须在 macOS + Xcode 命令行工具 下运行：
#    xcode-select --install
#
#  产物: ./libiPadSpoof.dylib
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS="14.0"

echo "==> SDK: $SDK"
echo "==> 编译 libiPadSpoof.dylib ..."

clang -arch arm64 \
      -isysroot "$SDK" \
      -miphoneos-version-min="$MIN_IOS" \
      -dynamiclib \
      -fobjc-arc \
      fishhook.c libiPadSpoof.m \
      -framework Foundation \
      -framework UIKit \
      -o libiPadSpoof.dylib

# TrollStore 通过 skip-library-validation 允许未签名 dylib；
# 若需兼容更严格环境，可用 ldid 做 adhoc 签名（失败不影响）。
ldid -S libiPadSpoof.dylib 2>/dev/null || true

echo "✅ 已生成: $SCRIPT_DIR/libiPadSpoof.dylib"
echo ""
echo "下一步：把 dylib 注入 QQ / 微信 IPA（见 README.md）"
