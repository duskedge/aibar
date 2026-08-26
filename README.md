# aibar

> macOS 菜单栏应用，统一统计 Claude Code / Codex / Grok 的 token 用量与成本。
> Swift 6 + SwiftUI，零第三方依赖，全部数据来自本地日志解析。

[![CI](https://github.com/waveblog/aibar/actions/workflows/ci.yml/badge.svg)](https://github.com/waveblog/aibar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)

**状态：v0.5 / M5 完成** —— 菜单栏、仪表盘、实时额度、导出、中英双语。

## 安装

```bash
brew install --cask waveblog/tap/aibar
```

或从 [Releases](https://github.com/waveblog/aibar/releases) 下载 DMG。

![仪表盘](docs/images/dashboard.png)

![快捷面板](docs/images/panel.png)

---

## 界面

中英双语，跟随系统语言，也可以在设置里强制指定。

| | |
|---|---|
| ![面板](docs/images/panel.png) | ![Panel](docs/images/panel-en.png) |

> 截图用的是**合成数据**（`aibar-shot --demo`）。README 里的图不该带上
> 维护者的真实项目名与花费 —— 那往往是公司内部信息。合成数据还有个好处：
> 任何贡献者都能复现同一张图。

## 现在能做什么

### 菜单栏应用

```bash
./scripts/build-app.sh
open .build/manual/aibar.app
```

常驻菜单栏，默认只显示一个百分比（`⏱ 17%`）—— 菜单栏横向寸土寸金。
需要更多信息可以在设置里打开窗口名与倒计时，变成 `⏱ 7d 3% 6d21h`。点开面板可以看到：
今日成本与 token、近 14 天堆叠趋势、三家分项、额度环、最近会话、限流次数。
文件变更由 FSEvents 监听，自动增量刷新。

菜单栏可以配置：

| 选项 | 说明 |
|---|---|
| 显示内容 | 额度 / 今日成本 / 今日 Token / 仅图标 |
| 显示哪一家 | 最紧张的一家（默认）· Claude Code · Codex · Grok |
| 显示哪个窗口 | 用量最高的 / 最短（5 小时）/ 最长（7 天）|
| 窗口名与倒计时 | `7d` 前缀与 `6d21h` 倒计时，**默认都关**，可单独打开 |

图标在告警线转琥珀、严重线转红，**判断依据是当前显示的那一条** ——
显示 A 却按 B 的水位报警会让人误判。

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

## 实时额度（L2）

本地日志答不出「现在还剩多少」，所以 aibar 会查官方接口。**默认开启**，
代价是信任成本全部前置：

| 措施 | 落地方式 |
|---|---|
| 首启披露 | 独立窗口逐条说明读什么、发到哪；「保持开启」与「切换到离线模式」两个按钮**等权并列**，没有勾选框 |
| 一键离线 | 面板顶部常驻，比设置页更好找。关掉后除两个额度环外功能一个不少 |
| 逐家开关 | 设置 → 网络 |
| 域名白名单 | 编译期常量，`scripts/check-network.sh` 在 CI 强制；出现非白名单 host 构建直接失败 |
| 凭据处理 | 只读 `claudeAiOauth.accessToken` 一个字段，只在内存中使用，不落库、不写日志、不进导出 |
| 网络活动面板 | 设置 → 网络活动，明文列出每个请求的时间、域名、状态码、耗时 |

白名单当前只有一个域名：

```
api.anthropic.com        ← 唯一一个。Codex 与 Grok 都不需要联网
```

额度接口默认 5 分钟拉一次（Claude Code 自己也打同一条 `oauth/usage`，60 秒会叠出 429）。
撞上 429 后按 5 → 10 → 20 → 30 分钟指数退避，面板继续显示上次成功的额度，
并写明「接口限流中」而不是笼统的「失败」—— 免得用户以为是配置错了去乱改设置。
文件监听只扫本地日志，不会跟着对话写盘去打接口。

各家的实际情况（均为实测结论）：

| | 官方额度来源 | 需要联网 |
|---|---|---|
| Claude Code | `api.anthropic.com/api/oauth/usage`（5 小时 / 7 天 / Opus 三个窗口）| 是 |
| Codex | 会话 jsonl 的 `rate_limits`：`primary` 5 小时 + `secondary` 7 天 | 否 |
| Grok | `~/.grok/logs/unified.jsonl` 的 `billing: fetched credits config` | 否 |

Grok 那条值得单独说。它的官方周额度**就在本地**，只是不在会话目录里：

```json
{"msg":"billing: fetched credits config","ctx":{
  "config":{"creditUsagePercent":4.0,
            "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
                             "end":"2026-09-02T00:57:35Z"}},
  "subscriptionTier":"SuperGrok"}}
```

这就是 `grok` 命令里 `Usage limit` 面板显示的那个数，官方值，无需联网。

**开发过程中我在这里下过一个错误结论**：只翻了 `~/.grok/sessions/` 和 Grok CLI 二进制
的端点表，就断言「Grok 没有官方额度」，还据此写进了文档。实际是找错了地方。
教训记在 `docs/data-sources.md` 里：**「找不到」不等于「不存在」，
在把它写成产品结论之前，先去看上游自己的界面显示了什么。**

## 花费预算

和额度是两件事，面板上分开显示：

- **额度**＝厂商给的官方剩余量，aibar 只做搬运，拿不到就说拿不到
- **预算**＝你自己在设置里定的花费上限，按等价 API 成本算进度

预算环用分段虚线画底，和额度环的实心底一眼可分。窗口内含缺定价模型时会标注
「实际花费更高」—— 进度被低估这件事不能瞒着。

## 导出

```bash
aibar export --last 7d --format csv --out usage.csv
aibar export --format json --out usage.json
```

导出内容只有会话元信息与计数，**不含凭据、对话正文或任何 token 值**。
缺定价的会话成本是空单元格 / `null`，不是 0。

## 界面上的几条硬规矩

- **没有可比历史就不显示环比。** 数据只回溯到某天，再往前推一个区间是空白，
  这时算出来的百分比没有意义 —— 宁可不显示，也不给一个假的增长率。
- **品牌色只用于分类编码。** 三家的颜色在图表、面板、会话列表里含义一致；
  单序列排行条用中性灰，不借用品牌色，否则"蓝色"一会儿指 Grok、
  一会儿指"随便某个项目"。
- **单轮会话的时长写"—"而不是"0 秒"。**
- **额度只画真实值。** 拿不到就写明拿不到，绝不用成本或 token 数反推。
- **数据来源和新鲜度要写出来。** 本地日志标「无需联网」，接口来源标 ⟳ 与刷新时间；
  超过一小时的日志型额度标注「N 小时前数据」，不装作实时。

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

## 测试

80 个回归测试，八个套件。**测试进程一律不读凭据、不联网**
（`AIBAR_NO_CREDENTIALS=1` 强制，见下文事故记录）：

- **三家日志解析**（11 个）—— 解析、去重、增量续读、跨块长行、价格表边界，
  以及上面那两个 Codex 的坑。输入是从真实日志提取的样本行，
  上游任何一家改格式，这里先红。
- **快照聚合与格式化**（12 个）—— 零用量 Provider 保留、会话代表模型取 token 最多者、
  按天序列补空缺、额度过期判定、成本 nil 渲染成 `—`、环比基数为零不编数字、刷新节流。
- **仪表盘与会话明细**（9 个）—— 时间范围边界、无可比历史时不给环比、
  会话 token 拆分与跨度、筛选与搜索、逐轮曲线排序、官方成本优先于价格表、
  缺定价单独统计、分支归因。
- **L2 网络层与导出**（15 个）—— 白名单最小化、非白名单被拒且留痕、
  日志不含凭据、凭据脱敏、多窗口响应解析、未知字段容错、离线短路、
  逐家开关、失败记录原因、CSV 转义、缺定价导出为空而非 0。
- **菜单栏显示选择**（7 个）—— 目标与窗口选择、无额度源返回 nil、
  紧凑格式、告警等级跟随所显示的额度。
- **花费预算**（5 个）—— 按成本计算进度、未设上限不产生进度、
  缺定价打标、超支钳制、编解码往返。
- **轮询频率约束**（4 个）—— force 的硬下限、退避指数增长与封顶、
  钥匙串锁定与用户拒绝的区分。
- **本地化**（7 个）—— 缺翻译回落到中文原文而非漏裸 key、
  **占位符数量与类型必须和原文一致**（少一个会读到垃圾内存）、
  译文里不许残留中文、不许有空译文。

测试全部走临时目录和内存库，不碰用户的真实日志。

## 路线

| | | 状态 |
|---|---|---|
| M1 | 解析内核 + CLI | ✅ 完成 |
| M2 | MenuBarExtra + 快捷面板 + FSEvents | ✅ 完成 |
| M3 | 主窗口仪表盘（Swift Charts） | ✅ 完成 |
| M4 | L2 额度接口 · 导出 · 通知 · 设置 | ✅ 完成 |
| M5 | 本地化 · 无障碍 · 开源发布（CI · 签名公证 · Homebrew Cask） | 下一步 |

设计稿与完整需求见 [`docs/PRD.md`](docs/PRD.md)。

## 一次事故与它留下的两道闸

开发 M4 时，单测构造了一个真的 `UsageEngine`，而它内部的 L2 服务默认是开着的，
一路调到读取 Keychain —— **在用户机器上弹出了钥匙串授权框**。

根因与修法：

1. `LiveQuotaService.Config` 默认改为 `offline: true, enabled: []`。
   L2 必须由 app 在展示过披露页之后显式打开，CLI、单测、离屏渲染都不会意外联网。
2. `scripts/test.sh` 设置 `AIBAR_NO_CREDENTIALS=1`，`Credentials` 在该环境下
   任何读取路径都直接抛错。第二道闸，防止根因以别的形式复发。

顺带的代价：测试套件从 20 秒回到 13 毫秒 —— 它本来就不该联网。

## 无障碍

- 图表合并成单个可访问元素并给出文字摘要（「14 天有用量，最高 335M 于 8月20日」），
  而不是让读屏逐个念 14 个无标签矩形
- 额度环 / 预算环带 `accessibilityValue`
- 纯装饰元素（占比轨）标 `accessibilityHidden`，避免重复念同一个数
- 支持动态字体与减弱动效

## 参与

见 [CONTRIBUTING.md](CONTRIBUTING.md)。新增一家 Provider 只需实现一个协议；
数据源的实测记录在 [docs/data-sources.md](docs/data-sources.md)。

## License

MIT
