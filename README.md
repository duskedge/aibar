# aibar

> macOS 菜单栏应用，统一统计 Claude Code / Codex / Grok 的 token 用量与成本。
> Swift 6 + SwiftUI，零第三方依赖，全部数据来自本地日志解析。

**状态：M3 已完成** —— 菜单栏 + 主窗口仪表盘均可用。设置与额度接口层在 M4。

![仪表盘](docs/images/dashboard.png)

![快捷面板](docs/images/panel.png)

---

## 现在能做什么

### 菜单栏应用

```bash
./scripts/build-app.sh
open .build/manual/aibar.app
```

常驻菜单栏，显示三家里最紧张的那条额度（`⏱ 64%`）。点开面板可以看到：
今日成本与 token、近 14 天堆叠趋势、三家分项、额度环、最近会话、限流次数。
文件变更由 FSEvents 监听，自动增量刷新。

菜单栏支持四种显示模式（额度 / 今日成本 / 今日 Token / 仅图标），
额度过阈值时图标变琥珀、再过变红。

### 主窗口仪表盘

面板底部点「主窗口」，或 `open -a aibar --args --dashboard` 直接进入。

- **时间范围**：今日 / 7 天 / 30 天 / 90 天 / 全部，指标可切 Token 或成本
- **每日用量**：Swift Charts 堆叠柱，三家配色与面板一致
- **模型分布 / Top 项目 / 按 Git 分支**：横向排行条
- **会话明细**：可按来源筛选、按项目/模型/会话 ID 搜索；
  选中一行展开该会话的 输入/输出/缓存读/缓存写/推理 拆分与逐轮曲线

### 命令行

```bash
./scripts/build.sh
./.build/manual/aibar scan      # 扫描本地日志（增量）
./.build/manual/aibar report    # 输出用量报告
./.build/manual/aibar doctor    # 检查数据源状态
```

本机实测输出：

```
aibar 用量报告 · 全部时间
──────────────────────────────────────────────────────────────
  总 Token        8.44B         38578 次请求 / 592 个会话
  等价 API 成本   $8457         估算 · 价格表 2026-08-20
  缓存命中率      97.3%         8.20B / 8.43B
  输出 Token      18.5M         占比 0.22%

  按 Provider
  ────────────────────────────────────────────────────────────
                                 Token        成本    会话
  Claude Code                    5.70B       $7872      32
  Codex                          2.74B     $584.69     557
  Grok                          600.2K     $0.6190       3

  额度
  ────────────────────────────────────────────────────────────
  Codex                  64.0%  7 天窗口 · 5 天 8 小时后重置 · plus  [本地日志]

  限流
  ────────────────────────────────────────────────────────────
  被限流 12 次 · 最近 08-23 18:03
```

`report` 支持 `--last 7d` / `--since 2026-08-01` / `--provider claude,codex`
/ `--by provider,model,project,day,branch` / `--limit N`。

## 性能

本机 2.6 GB 会话数据（628 个文件）：

| | 耗时 | 说明 |
|---|---|---|
| 全量扫描 | **10.3 秒** | 流式逐行 + 字节级预筛，解析失败 0 行 |
| 增量扫描 | **0.06 秒** | 627/628 文件按 inode+size 跳过 |
| 数据库 | 12 MB | 38578 条事件 |
| 常驻 CPU（空闲）| **0.03%** | 无日志写入时，30 秒区间实测 |
| 常驻 CPU（活跃）| **0.7%** | 正在跑 AI 编程、日志持续写入时 |
| 常驻内存 | 74 MB | SwiftUI 基线约占 60 MB |

早期版本常驻 CPU 高达 48%。`sample` 定位到 `Reports.recentSessions` 占 43%：
那个"该会话哪个模型 token 最多"的关联子查询挂在外层，592 个会话各跑一次全表聚合。
改成先用 CTE 把范围收窄到最近 N 个会话再聚合，并给 `(session_id, provider)` 加索引，
查询降到 8 ms。同时给刷新加了 5 秒下限 —— 用户跑对话时 CLI 持续写日志，
FSEvents 会一直触发，没有下限就成了"扫完立刻再扫"。

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

## 三家日志的坑

完整实测记录见 [`docs/PRD.md`](docs/PRD.md) 第 2 节。摘要：

| | 坑 | 处理 |
|---|---|---|
| Claude | 同一请求重复落盘（实测 41% 是重复行） | 按 `requestId` 去重，由数据库主键强制 |
| Claude | 子 agent 会话在 `<sessionId>/subagents/` 下 | 必须递归遍历，只扫一层会漏 |
| Codex | `sum(last_token_usage)` 比末条 `total` 多出最多 6% | 改用相邻 `total` 的单调差值 |
| Codex | `total` 会在上下文压缩时中途回退 | 回退即重置基线并继续累计，否则整段丢失 |
| Grok | 字段是 camelCase，项目路径是 URL 编码的目录名 | 适配层归一化 |
| Grok | 自带 `costUsdTicks` | `/1e10` 即美元，优先于本地价格表 |

**成本一律标注"估算"。** Claude / Codex 不回传金额，按内置价格表算；缺定价的模型
成本显示 `—` 并单独提示未计入总额，**绝不静默按 0 计**。Grok 用官方值。

## 界面上的几条硬规矩

- **没有可比历史就不显示环比。** 数据只回溯到某天，再往前推一个区间是空白，
  这时算出来的百分比没有意义 —— 宁可不显示，也不给一个假的增长率。
- **品牌色只用于分类编码。** 三家的颜色在图表、面板、会话列表里含义一致；
  单序列排行条用中性灰，不借用品牌色，否则"蓝色"一会儿指 Grok、
  一会儿指"随便某个项目"。
- **单轮会话的时长写"—"而不是"0 秒"。**

- **零用量不隐藏。** 当天没跑的 Provider 显示"今日无用量"，而不是把行删掉 ——
  否则用户分不清"今天没用"和"这家没接上"。
- **额度只画真实值。** 目前只有 Codex 在本地日志里回传官方百分比；
  Claude 和 Grok 画虚线空环并写明"本地日志不含额度信息"，
  绝不用 token 数反推一个假百分比。
- **数据新鲜度要说出来。** 日志型额度只在跑对话时更新，超过一小时就标注
  "16 小时前数据"，不装作实时。
- **缺定价必须显式提示。** 面板底部单列一条"N 个模型缺少定价，X token 未计入成本"。

## 构建

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
./scripts/build.sh      # 构建 core + CLI
./scripts/build-app.sh  # 构建 aibar.app
./scripts/test.sh       # 跑测试
```

`build-app.sh` 顺带产出 `aibar-shot`，可以把面板离屏渲染成 PNG：

```bash
./.build/manual/aibar-shot docs/images/panel.png   # 同时产出 dashboard.png
```

用它生成截图，比去点真实菜单栏更可控，也不会干扰正在用的桌面 ——
README 里这两张图就是这么出的。

## 测试

32 个回归测试，三个套件：

- **三家日志解析**（11 个）—— 解析、去重、增量续读、跨块长行、价格表边界，
  以及上面那两个 Codex 的坑。输入是从真实日志提取的样本行，
  上游任何一家改格式，这里先红。
- **快照聚合与格式化**（12 个）—— 零用量 Provider 保留、会话代表模型取 token 最多者、
  按天序列补空缺、额度过期判定、成本 nil 渲染成 `—`、环比基数为零不编数字、刷新节流。
- **仪表盘与会话明细**（9 个）—— 时间范围边界、无可比历史时不给环比、
  会话 token 拆分与跨度、筛选与搜索、逐轮曲线排序、官方成本优先于价格表、
  缺定价单独统计、分支归因。

测试全部走临时目录和内存库，不碰用户的真实日志。

## 路线

| | | 状态 |
|---|---|---|
| M1 | 解析内核 + CLI | ✅ 完成 |
| M2 | MenuBarExtra + 快捷面板 + FSEvents | ✅ 完成 |
| M3 | 主窗口仪表盘（Swift Charts） | ✅ 完成 |
| M4 | L2 额度接口 · 导出 · 通知 · 本地化 | 下一步 |
| M5 | 开源发布（CI · 签名公证 · Homebrew Cask） | |

设计稿与完整需求见 [`docs/PRD.md`](docs/PRD.md)。

## License

MIT
