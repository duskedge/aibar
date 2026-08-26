#!/usr/bin/env bash
# Developer ID 签名 + 公证。
#
# aibar 不开 App Sandbox —— 它要读 ~/.claude、~/.codex、~/.grok 这些任意路径，
# 沙盒下拿不到。所以走 Developer ID 分发，签名与公证是必须的，
# 否则 Gatekeeper 会拦。
set -euo pipefail

APP="${1:?用法: sign-and-notarize.sh <path-to-.app>}"
: "${TEAM_ID:?需要 TEAM_ID}"
: "${NOTARY_APPLE_ID:?需要 NOTARY_APPLE_ID}"
: "${NOTARY_PASSWORD:?需要 NOTARY_PASSWORD（App 专用密码）}"

IDENTITY="Developer ID Application"

echo "→ 签名内嵌动态库"
find "$APP/Contents/Frameworks" -name '*.dylib' -print0 2>/dev/null |
  while IFS= read -r -d '' lib; do
    codesign --force --options runtime --timestamp \
      --sign "$IDENTITY" "$lib"
  done

echo "→ 签名应用包"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$APP"

echo "→ 校验"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "→ 提交公证"
ZIP="$(dirname "$APP")/$(basename "$APP" .app)-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
  --apple-id "$NOTARY_APPLE_ID" \
  --password "$NOTARY_PASSWORD" \
  --team-id "$TEAM_ID" \
  --wait
rm -f "$ZIP"

echo "→ 装订公证票据"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "✓ 已签名并公证：$APP"
