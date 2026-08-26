#!/usr/bin/env bash
# 打印当前版本号。唯一来源是 Sources/AibarCore/Version.swift。
set -euo pipefail
cd "$(dirname "$0")/.."
grep -oE 'current = "[^"]+"' Sources/AibarCore/Version.swift | head -1 | sed 's/.*"\(.*\)"/\1/'
