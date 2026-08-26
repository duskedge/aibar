#!/usr/bin/env bash
# 构建 aibar.app（菜单栏应用）。
# 同样绕过坏掉的 SwiftPM，原因见 build.sh 顶部注释。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=.build/manual
APP="$OUT/aibar.app"
FLAGS=(-swift-version 6 -O -target arm64-apple-macosx14.0)

bash scripts/build.sh >/dev/null

echo "→ 编译 aibarApp"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" \
  -parse-as-library \
  -I "$OUT" -L "$OUT" -lAibarCore -lsqlite3 \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -o "$APP/Contents/MacOS/aibar" \
  $(find Sources/aibarApp -name "*.swift")

mkdir -p "$APP/Contents/Frameworks"
cp "$OUT/libAibarCore.dylib" "$APP/Contents/Frameworks/"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 本地构建用临时签名即可；正式分发走 Developer ID + 公证（M5）
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || true

echo "✓ $APP"
echo "  运行: open $APP"

# 离屏渲染工具（生成 README 截图）
echo "→ 编译 aibar-shot"
swiftc "${FLAGS[@]}" \
  -I "$OUT" -L "$OUT" -lAibarCore -lsqlite3 \
  -Xlinker -rpath -Xlinker "@executable_path" \
  -o "$OUT/aibar-shot" \
  $(find Sources/aibarApp -name "*.swift" ! -name "AibarApp.swift") \
  Sources/aibarShot/main.swift
echo "✓ $OUT/aibar-shot"
