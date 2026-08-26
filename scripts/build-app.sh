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

# 版本号盖章。唯一来源是 Sources/AibarCore/Version.swift，
# Info.plist 里的占位值不作数。
VERSION=$(bash scripts/version.sh)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# 应用图标。用代码画的，改 scripts/icon/make-icon.swift 后跑 make-icon.sh 重生成。
[ -f Resources/AppIcon.icns ] || bash scripts/make-icon.sh >/dev/null
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 本地化资源。中文是开发语言（原文即 key），所以 zh-Hans.lproj 是空的，
# 它存在只为让 macOS 把 zh-Hans 认成受支持语言。
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done

# 本地构建用临时签名。钥匙串「始终允许」绑的是这次二进制，
# 所以重编译后还会再问一次；同一次运行里凭据会缓存在内存，不再反复弹。
codesign --force --sign - --identifier dev.aibar.app --timestamp=none "$APP" 2>/dev/null || true

echo "✓ $APP"
echo "  运行: open $APP"

# 离屏渲染工具（生成 README 截图）
echo "→ 编译 aibar-shot"
swiftc "${FLAGS[@]}" \
  -I "$OUT" -L "$OUT" -lAibarCore -lsqlite3 \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -o "$APP/Contents/MacOS/aibar-shot" \
  $(find Sources/aibarApp -name "*.swift" ! -name "AibarApp.swift") \
  Sources/aibarShot/main.swift
# 刻意不建符号链接：通过符号链接调用会让 Bundle.main 指向链接所在目录，
# 于是找不到 .lproj，本地化静默失效。必须用真实路径调用。
echo "✓ $APP/Contents/MacOS/aibar-shot"

# 签名必须放在最后：往已签名的 bundle 里再塞二进制会让签名失效，
# dyld 会直接拒绝加载内嵌的 dylib。踩过一次。
# 本地用临时签名；正式分发走 Developer ID + 公证，见 scripts/sign-and-notarize.sh
codesign --force --deep --sign - --identifier dev.aibar.app --timestamp=none "$APP" 2>/dev/null || true

echo "✓ $APP"
