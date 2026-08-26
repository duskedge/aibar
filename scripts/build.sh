#!/usr/bin/env bash
# 直接用 swiftc 构建，绕过 SwiftPM。
#
# 存在的原因：部分 macOS Command Line Tools 安装是坏的 —— ManifestAPI 目录里
# libPackageDescription.dylib 与 PackageDescription.swiftinterface 版本不一致，
# 导致任何 swift-tools-version 的 manifest 都链接失败：
#
#   Undefined symbols: PackageDescription.Package.__allocating_init(... swiftLanguageVersions: [SwiftVersion] ...)
#
# 排查：ls -la $(xcrun --show-sdk-platform-path 2>/dev/null)/../../usr/lib/swift/pm/ManifestAPI/
# 修复：装完整版 Xcode，或从 swift.org 装官方 toolchain。
# 环境正常时请直接用 `swift build`。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=.build/manual
mkdir -p "$OUT"
FLAGS=(-swift-version 6 -O -target arm64-apple-macosx14.0 -enable-testing)

echo "→ 编译 AibarCore"
swiftc "${FLAGS[@]}" \
  -emit-module -emit-module-path "$OUT/AibarCore.swiftmodule" \
  -emit-library -o "$OUT/libAibarCore.dylib" \
  -module-name AibarCore -lsqlite3 \
  -Xlinker -install_name -Xlinker @rpath/libAibarCore.dylib \
  $(find Sources/AibarCore -name "*.swift")

echo "→ 编译 aibar"
swiftc "${FLAGS[@]}" \
  -I "$OUT" -L "$OUT" -lAibarCore -lsqlite3 \
  -Xlinker -rpath -Xlinker "@executable_path" \
  -o "$OUT/aibar" \
  Sources/aibarCLI/main.swift

echo "✓ $OUT/aibar"
