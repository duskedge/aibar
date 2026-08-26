# 贡献指南

## 先读这个

aibar 有两条不能破的底线，PR 会照着它们审：

1. **数字必须诚实。** 拿不到就说拿不到，不猜、不反推、不用 0 填空。
   缺定价的模型成本显示 `—` 而不是 `$0`；没有官方额度就写明没有，
   不用「成本 ÷ 套餐价」造一个百分比。
2. **联网必须可验证。** 白名单是编译期常量，CI 强制检查。
   凭据只在内存里过一遍，不落库、不写日志、不进导出。

## 开发环境

正常环境：

```bash
swift build && swift test
```

**如果 `swift build` 报 `Invalid manifest` / `Undefined symbols: PackageDescription.Package.__allocating_init`**，
说明这台机器的 Command Line Tools 装坏了——`usr/lib/swift/pm/ManifestAPI/` 里
`libPackageDescription.dylib` 与 `PackageDescription.swiftinterface` 版本不一致
（本机实测 dylib 是 2026-06，interface 停在 2024-02），任何 tools-version 都会失败。

修复：装完整版 Xcode，或从 [swift.org](https://swift.org/download/) 装官方 toolchain。

临时绕过（直接调 `swiftc`，不经 SwiftPM）：

```bash
./scripts/build.sh         # 构建 core + CLI
./scripts/build-app.sh     # 构建 aibar.app（含离屏截图工具）
./scripts/test.sh          # 跑测试（禁凭据、禁联网）
./scripts/check-network.sh # 域名白名单静态检查
./scripts/make-dmg.sh      # 打 DMG 并生成填好 sha256 的 Cask
./scripts/make-icon.sh     # 重新生成应用图标（图标是代码画的）
```

生成截图（必须用真实路径调用，走符号链接会让 `Bundle.main` 指错目录、
本地化静默失效）：

```bash
APP=.build/manual/aibar.app/Contents/MacOS
$APP/aibar-shot docs/images/panel.png --demo
$APP/aibar-shot docs/images/panel-en.png --demo -AppleLanguages '(en)'
$APP/aibar-shot --diag x   # 自检：确认 .lproj 真的被找到

# 不加 --demo 就是读你自己的库，用来自查，别提交
```

`build-app.sh` 顺带产出 `aibar-shot`，可以把面板离屏渲染成 PNG：

```bash
./.build/manual/aibar-shot docs/images/panel.png   # 同时产出 dashboard.png
```

用它生成截图，比去点真实菜单栏更可控，也不会干扰正在用的桌面 ——
README 里这两张图就是这么出的。

提 PR 前构建、测试、白名单检查三条都要过。

## 架构

```
Sources/AibarCore/
  Models/         UsageEvent · QuotaStatus · RateLimitEvent · Snapshot
  Ingest/         LineReader（按 offset 续读）· DateParsing · FileWatcher（FSEvents）
  Providers/      UsageProvider 协议 + 三家 Adapter
  Store/          Database（裸 SQLite）· UsageStore · Reports
  Pricing/        PricingTable
  Scanner.swift   扫描编排
  UsageEngine.swift  actor，数据库只在这里面
Sources/aibarApp/   SwiftUI MenuBarExtra + 快捷面板 + 仪表盘 + 设置
Sources/aibarCLI/   命令行
Sources/aibarShot/  离屏渲染面板成 PNG（生成截图 / 视觉回归）
```

**并发模型**：`UsageStore` 里握着 SQLite 的 `OpaquePointer`，不是 Sendable。
把它整个关进 `UsageEngine` actor，UI 侧只拿 `Snapshot` 值类型 ——
从根上避免跨线程共享，而不是靠 `@unchecked Sendable` 糊过去。

新增一家 Provider 只需实现 `UsageProvider`：

```swift
protocol UsageProvider: Sendable {
    var provider: Provider { get }
    var rootPaths: [URL] { get }
    func discoverFiles() -> [URL]
    func parse(file: URL, from offset: UInt64, cursor: String?) throws -> ScanResult
}
```

**零第三方依赖。** SQLite 直接用系统 `libsqlite3`。对一个后续会读取用户 OAuth 凭据的
工具来说，没有供应链面本身就是可信度的一部分。

## 新增一家 Provider

只需实现 `UsageProvider`，其余部分不用动：

```swift
protocol UsageProvider: Sendable {
    var provider: Provider { get }
    var rootPaths: [URL] { get }          // FSEvents 监听这些目录
    func discoverFiles() -> [URL]
    func parse(file: URL, from offset: UInt64, cursor: String?) throws -> ScanResult
}
```

**必须附带**：

- 一段**脱敏的真实样本行**（把路径、项目名、token 值换掉，保留结构）
- `Tests/AibarCoreTests/ParsingTests.swift` 里的一个用例
- 在 [`docs/data-sources.md`](docs/data-sources.md) 里补一节，写清楚
  路径、去重键、有没有官方额度、以及**你是怎么验证的**

最后一条尤其重要。判断「某家没有官方额度」之前，先去看**该 CLI 自己的界面**
有没有在显示这个数。如果在显示，数据一定来自某处 —— 而且未必在会话目录里，
Grok 的就在 `~/.grok/logs/unified.jsonl`。

## 解析器的几条规矩

- **流式逐行读**。本机 Codex 单目录就 1.9 GB，绝不能整文件载入内存。
- **先按字节预筛，再解析 JSON。** 实测能让全量扫描快一个数量级。
- **去重交给数据库主键。** 应用层记忆去重迟早在增量场景漏掉
  （Claude 有 41% 的重复行）。
- **解析失败要计数上报，不要静默跳过。** 上游改格式时得让用户看见。

## 界面的几条规矩

- 零用量的一家显示「今日无用量」，不要把行删掉 ——
  否则用户分不清「今天没用」和「这家没接上」。
- 数据来源与新鲜度要写出来：本地日志标「无需联网」，
  接口来源标刷新时间；超过一小时的日志型额度标「N 小时前数据」。
- 没有可比历史就不显示环比，别给一个假的增长率。
- 品牌色只用于分类编码。单序列排行条用中性灰，不要借用品牌色。

## 提交信息

说清楚**为什么**，不只是改了什么。解析上游日志时发现的约束和反直觉之处，
写在提交信息里比写在代码注释里更容易被后来者找到。

## 行为准则

对事不对人。指出问题时给出复现步骤或数据。
