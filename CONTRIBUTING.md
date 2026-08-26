# 贡献指南

## 先读这个

aibar 有两条不能破的底线，PR 会照着它们审：

1. **数字必须诚实。** 拿不到就说拿不到，不猜、不反推、不用 0 填空。
   缺定价的模型成本显示 `—` 而不是 `$0`；没有官方额度就写明没有，
   不用「成本 ÷ 套餐价」造一个百分比。
2. **联网必须可验证。** 白名单是编译期常量，CI 强制检查。
   凭据只在内存里过一遍，不落库、不写日志、不进导出。

## 本地开发

```bash
swift build && swift test
```

如果 `swift build` 报 `Invalid manifest` / `Undefined symbols:
PackageDescription.Package.__allocating_init`，说明这台机器的 Command Line
Tools 装坏了（`usr/lib/swift/pm/ManifestAPI/` 里 dylib 与 swiftinterface 版本
不一致）。装完整版 Xcode 或 swift.org 的 toolchain 可以根治。临时绕过：

```bash
./scripts/build.sh          # core + CLI
./scripts/build-app.sh      # aibar.app + 截图工具
./scripts/test.sh           # 测试（禁凭据、禁联网）
./scripts/check-network.sh  # 域名白名单静态检查
```

提 PR 前这四条都要过。

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

最后一条尤其重要。这个项目踩过一次：只翻了会话目录没找到 Grok 的额度，
就断言「Grok 没有官方额度」，其实数据在另一个日志文件里，上游自己的界面
一直在显示它。**「我没找到」不等于「它不存在」。**

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

说清楚**为什么**，不只是改了什么。踩过的坑写进去 ——
这个仓库的 git log 本身就是一份数据源调研记录。

## 行为准则

对事不对人。指出问题时给出复现步骤或数据。
