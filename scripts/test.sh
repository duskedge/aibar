#!/usr/bin/env bash
# 手动跑 swift-testing，绕过坏掉的 SwiftPM（原因见 build.sh 顶部注释）。
# 环境正常时请直接用 `swift test`。
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=$(xcode-select -p)
FW="$CLT/Library/Developer/Frameworks"
# Testing.framework 依赖的 lib_TestingInterop.dylib 不在默认搜索路径里
INTEROP="$CLT/Library/Developer/usr/lib"
OUT=.build/manual
mkdir -p "$OUT"

bash scripts/build.sh >/dev/null

cat > "$OUT/TestMain.swift" <<'SWIFT'
import Testing
@main struct Runner {
    static func main() async { await Testing.__swiftPMEntryPoint() as Never }
}
SWIFT

echo "→ 编译测试"
swiftc -swift-version 6 -target arm64-apple-macosx14.0 \
  -F "$FW" -framework Testing \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$INTEROP" \
  -plugin-path "$CLT/usr/lib/swift/host/plugins/testing" \
  -I "$OUT" -L "$OUT" -lAibarCore -lsqlite3 \
  -Xlinker -rpath -Xlinker "@executable_path" \
  -parse-as-library \
  -o "$OUT/aibar-tests" \
  Tests/AibarCoreTests/*.swift "$OUT/TestMain.swift"

echo "→ 运行"
"$OUT/aibar-tests"
