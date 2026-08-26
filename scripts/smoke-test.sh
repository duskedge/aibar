#!/usr/bin/env bash
# 启动冒烟测试：真的把 app 跑起来，确认它没有立刻崩。
#
# 存在的原因：v0.5.0 发出去的包一启动就 SIGTRAP，而 CI 全绿 ——
# 因为 CI 只构建、从不运行。崩溃点在 UNUserNotificationCenter 的完成回调
# （类型被标了 @MainActor，回调却在系统自己的队列上执行），单元测试碰不到，
# 只有真启动才能发现。
#
# 注意：变量一律写 ${VAR}。中文标点是多字节的，`$VAR，` 会让 bash
# 把后面的字节也当成变量名，配合 set -u 直接报 unbound variable。
set -euo pipefail

APP="${1:-.build/manual/aibar.app}"
BIN="${APP}/Contents/MacOS/aibar"
LIVE="${2:-8}"

if [ ! -x "${BIN}" ]; then
  echo "✗ 找不到可执行文件: ${BIN}"
  exit 1
fi
echo "→ 启动 ${BIN}, 观察 ${LIVE}s"

# 独立 HOME：不读开发者的真实用量，也不污染其偏好设置
SANDBOX="$(mktemp -d)"
cleanup() {
  if [ -n "${SANDBOX:-}" ] && [ -d "${SANDBOX}" ]; then rm -rf "${SANDBOX}"; fi
}
trap cleanup EXIT

LOG="${SANDBOX}/out.log"
env HOME="${SANDBOX}" AIBAR_NO_CREDENTIALS=1 "${BIN}" >"${LOG}" 2>&1 &
PID=$!
sleep "${LIVE}"

if kill -0 "${PID}" 2>/dev/null; then
  kill "${PID}" 2>/dev/null || true
  wait "${PID}" 2>/dev/null || true
  echo "✓ 存活 ${LIVE}s, 未崩溃"
  exit 0
fi

set +e
wait "${PID}"
CODE=$?
set -e
echo "✗ ${LIVE}s 内就退出了, 退出码 ${CODE}"
case "${CODE}" in
  133) echo "   133 = SIGTRAP, Swift 运行时断言（并发隔离检查 / 强制解包 / 越界）" ;;
  134) echo "   134 = SIGABRT" ;;
  139) echo "   139 = SIGSEGV" ;;
esac
echo "--- 输出 ---"
cat "${LOG}" || true
exit 1
