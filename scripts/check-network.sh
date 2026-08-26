#!/usr/bin/env bash
# 白名单静态检查：源码里出现非白名单 host 的网络调用，构建直接失败。
#
# aibar 默认联网并读取用户凭据，"只连这几个域名"必须是能被验证的事实，
# 而不是 README 里的一句承诺。CI 每次都跑这条。
set -euo pipefail
cd "$(dirname "$0")/.."

ALLOWED='api\.anthropic\.com'
FAIL=0

# 1) 源码里出现的所有 https:// URL，除白名单外一律不允许
echo "→ 检查源码中的出网地址"
HITS=$(grep -rnoE 'https?://[a-zA-Z0-9._-]+' Sources/ \
        --include='*.swift' \
        | grep -vE "https://($ALLOWED)" \
        | grep -vE 'https?://(www\.)?(apple\.com|swift\.org|github\.com)' || true)
if [ -n "$HITS" ]; then
  echo "✗ 发现非白名单地址："
  echo "$HITS" | sed 's/^/    /'
  FAIL=1
fi

# 2) 出网必须走 NetworkGuard，不允许直接用 URLSession
echo "→ 检查是否绕过 NetworkGuard"
BYPASS=$(grep -rn 'URLSession' Sources/ --include='*.swift' \
          | grep -v 'Sources/AibarCore/Network/NetworkGuard.swift' || true)
if [ -n "$BYPASS" ]; then
  echo "✗ 以下位置绕过了 NetworkGuard："
  echo "$BYPASS" | sed 's/^/    /'
  FAIL=1
fi

# 3) 凭据不得出现在日志或导出里
echo "→ 检查凭据是否可能被打印"
# 用词边界，别把 token 计数（tokens / Fmt.tokens）误判成凭据
LEAK=$(grep -rnE '(print|debugPrint|NSLog|os_log)\(.*\b(accessToken|refreshToken|credential|token)\b' \
        Sources/ --include='*.swift' \
        | grep -vi 'redacted' || true)
if [ -n "$LEAK" ]; then
  echo "✗ 可能打印凭据："
  echo "$LEAK" | sed 's/^/    /'
  FAIL=1
fi

[ $FAIL -eq 0 ] && echo "✓ 网络白名单检查通过" || exit 1
