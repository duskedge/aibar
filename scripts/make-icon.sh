#!/usr/bin/env bash
# 生成 Resources/AppIcon.icns。图标是代码画的，改了 make-icon.swift 重跑即可。
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swiftc -O -o "$TMP/make-icon" scripts/icon/make-icon.swift
"$TMP/make-icon" "$TMP/AppIcon.iconset" >/dev/null
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "✓ Resources/AppIcon.icns  ($(du -h Resources/AppIcon.icns | cut -f1))"
