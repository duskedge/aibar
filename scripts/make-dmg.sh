#!/usr/bin/env bash
# 打一个带 /Applications 快捷方式的 DMG。
set -euo pipefail

APP="${1:?用法: make-dmg.sh <path-to-.app> [version]}"
VERSION="${2:-dev}"
NAME=$(basename "$APP" .app)
OUT="dist/${NAME}-${VERSION}.dmg"

rm -rf dist/stage "$OUT"
mkdir -p dist/stage
cp -R "$APP" dist/stage/
ln -s /Applications dist/stage/Applications

hdiutil create -volname "$NAME" \
  -srcfolder dist/stage \
  -ov -format UDZO \
  "$OUT" >/dev/null

rm -rf dist/stage
SHA=$(shasum -a 256 "$OUT" | awk '{print $1}')
echo "$SHA  $(basename "$OUT")" > "${OUT}.sha256"

# 顺手产出一份填好 version / sha256 的 Cask，直接可以贴进 tap 仓库
if [ -f packaging/aibar.rb ]; then
  sed -e "s/^  version \".*\"/  version \"${VERSION#v}\"/" \
      -e "s/REPLACE_WITH_DMG_SHA256/$SHA/" \
      packaging/aibar.rb > "dist/aibar.rb"
  echo "✓ dist/aibar.rb"
fi

echo "$SHA"
echo "✓ $OUT"
