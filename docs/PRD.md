# aibar — AI 编程助手用量统计 · 需求文档

> macOS 菜单栏应用，本地聚合 Claude Code / Codex / Grok CLI 的 token 与成本用量。
> Swift 6 + SwiftUI，原生开发，开源发布到 GitHub。

版本：v0.1 (Draft) · 日期：2026-08-26 · 目标平台：macOS 14.0+

---

## 1. 背景与目标

同时使用多个 AI 编程助手时，用量分散在各自的本地目录里，没有统一视角：不知道今天烧了多少 token、哪个项目最费钱、订阅额度还剩多少、什么时候会被限流。

**aibar 的目标**：常驻菜单栏，一眼看到"现在还能用多少"，点开看到"钱花在哪了"。

### 设计原则

| 原则 | 含义 |
|---|---|
| 开箱即用 | 装上就能看到完整数据，包含三家实时额度，无需任何配置 |
| 可验证的克制 | 只与硬编码的各家官方域名通信，绝不上传数据到第三方；白名单由 CI 静态检查强制 |
| 随时可关 | 一个全局「离线模式」开关即可切断全部网络，切断后用量分析功能不受任何影响 |
| 只读不写 | 绝不修改各 CLI 的数据目录，避免污染其会话 |
| 低开销 | 常驻内存 < 80MB，空闲 CPU < 0.5% |
| 可离线校准 | 价格表内置且可用户覆盖，不依赖远端配置 |

### 非目标（v1 明确不做）

- 不做云端同步 / 团队看板
- 不做各家的计费账单对账（口径不一，只做用量与等价成本估算）
- 不做 Windows / Linux 版
- 不代理或拦截 CLI 的网络流量

---

## 2. 数据源调研结论

以下均为在本机实测确认的结构（macOS 26.5.2）。

### 2.1 Claude Code

- **路径**：`~/.claude/projects/<项目路径转义>/<sessionId>.jsonl`
  **必须递归遍历**：子 agent 会话另存在 `<sessionId>/subagents/agent-*.jsonl`，只扫一层会漏掉它们（本机 40 → 50 个文件，漏掉约 3.5M token）。
- **规模实测**：50 个文件 / 469 MB（含 subagents）
- **用量记录**：`type == "assistant"` 的行，`message.usage`

```json
{
  "type": "assistant", "timestamp": "2026-08-26T...", "requestId": "req_011Ce...",
  "sessionId": "9337a58f-...", "cwd": "/Users/x/code/aibar", "gitBranch": "main",
  "version": "2.1.233",
  "message": {
    "model": "claude-opus-5",
    "usage": {
      "input_tokens": 2,
      "cache_creation_input_tokens": 33283,
      "cache_read_input_tokens": 0,
      "output_tokens": 729,
      "output_tokens_details": { "thinking_tokens": 317 },
      "cache_creation": { "ephemeral_1h_input_tokens": 33283, "ephemeral_5m_input_tokens": 0 },
      "service_tier": "standard"
    }
  }
}
```

要点：
- **必须按 `requestId` 去重**：同一次请求会在 JSONL 中重复落盘（实测同一 usage 连续出现 2 次），直接累加会翻倍。
- 缓存写入分 `ephemeral_5m` / `ephemeral_1h` 两档，**计价系数不同**（1h 更贵），要分开累计。
- `cwd` 用于按项目归因，`gitBranch` 用于按分支归因。
- 实测模型：`claude-opus-5`、`claude-sonnet-5`。
- `~/.claude/stats-cache.json` 有官方按天的 messageCount/sessionCount，可作为交叉校验，但**无 token**，不作为主数据源。

### 2.2 Codex

- **路径**：`~/.codex/sessions/YYYY/MM/DD/rollout-<ISO时间>-<uuid>.jsonl`
- **规模实测**：488 个文件 / 1.9 GB（最大数据源，增量解析是硬需求）
- **会话元信息**：首行 `type == "session_meta"`，含 `cwd` / `cli_version` / `originator` / `model_provider`
- **用量记录**：`payload.type == "token_count"`

```json
{
  "timestamp": "2026-08-03T03:12:30.042Z", "type": "event_msg",
  "payload": {
    "type": "token_count",
    "info": {
      "total_token_usage": { "input_tokens": 4286305, "cached_input_tokens": 4043264,
        "cache_write_input_tokens": 0, "output_tokens": 14919,
        "reasoning_output_tokens": 3537, "total_tokens": 4301224 },
      "last_token_usage": { "input_tokens": 85369, "cached_input_tokens": 84736,
        "output_tokens": 78, "reasoning_output_tokens": 0, "total_tokens": 85447 },
      "model_context_window": 258400
    },
    "rate_limits": {
      "primary": { "used_percent": 61.0, "window_minutes": 10080, "resets_at": 1786163142 },
      "secondary": null,
      "credits": { "has_credits": false, "unlimited": false, "balance": "0" },
      "plan_type": "plus"
    }
  }
}
```

要点：
- **`total_token_usage` 是会话内累计值，`last_token_usage` 是本轮增量**，且二者并不自洽：实测 `sum(last)` 会超出末条 `total` 最多约 6%（`n=388, final=55,201,861, sum(last)=55,303,167`）。
- **正确做法是取相邻 `total` 的单调差值**，而不是"末条 total"。M1 实测推翻了这条最初的建议：`total` 会在上下文压缩 / 会话 fork 时**中途回退**（实测一个会话从 1,140,294 直接掉到 63,168），此时"末条 total"会把回退前的整段用量全部丢掉。
  全量实测：562 个有用量的会话中 2 个发生过回退（0.4%），旧口径共少算 7,683,058 token（0.3%）。比例不高，但这是**系统性少算**，且重度用户压缩更频繁，占比只会更高。
  差值法还有一个附带好处：天然支持断点续读，只要把上一次的 `total` 存进 cursor。
- `rate_limits.primary.used_percent` + `resets_at` 是**唯一一个能拿到官方真实额度百分比的数据源**，菜单栏的"剩余额度"环形指示器直接用它，无需估算。`window_minutes: 10080` = 7 天窗口。
- `plan_type`（plus/pro/team）决定额度基数，展示时标注。
- 模型字段在 `turn_context` 里，实测 `gpt-5.6-sol`。
- `~/.codex/archived_sessions/` 也需扫描（历史归档）。

### 2.3 Grok CLI

- **路径**：`~/.grok/sessions/<URL转义的cwd>/<sessionId>/updates.jsonl`
- **规模实测**：3 个文件 / 2.6 MB
- **用量记录**：`method == "_x.ai/session/update"` 且 `update.sessionUpdate == "turn_completed"`

```json
{
  "timestamp": 1787637939, "method": "_x.ai/session/update",
  "params": { "sessionId": "01a03785-...", "update": {
    "sessionUpdate": "turn_completed", "stop_reason": "end_turn",
    "usage": {
      "inputTokens": 16351, "outputTokens": 214, "totalTokens": 16565,
      "cachedReadTokens": 10752, "cacheCreationTokens": 0, "reasoningTokens": 154,
      "modelCalls": 1, "apiDurationMs": 7170, "costUsdTicks": 178580000,
      "modelUsage": { "grok-4.6": { "inputTokens": 16351, "outputTokens": 214, "costUsdTicks": 178580000 } },
      "numTurns": 1
    } } }
}
```

要点：
- **Grok 自带 `costUsdTicks`，是三家里唯一直接给成本的**。换算：`USD = costUsdTicks / 1e10`（实测 178580000 ticks ≈ $0.01786，与 grok-4.6 官方价格吻合）。Grok 一律用官方值，不走本地估算。
- `modelUsage` 已按模型拆分，直接用。
- 目录名是 URL 编码的 cwd（`%2FUsers%2F...`），解码后即项目路径。
- `summary.json` 提供会话标题 / `created_at` / `agent_name`，用于会话列表展示。
- `~/.grok/sessions/session_search.sqlite` 是全文检索库，v1 不用。
- 字段命名是 camelCase，与另两家的 snake_case 不同，适配层需归一化。

### 2.4 额度：本地日志够不够？

这是本项目最关键的一个取舍，实测结论如下。

| Provider | 本地日志能拿到的额度信息 | 官方接口 |
|---|---|---|
| Claude Code | ❌ 无实时百分比。**但**日志里有限流事件：`error:"rate_limit"` + `apiErrorStatus:429`。可算出"本周被限流 N 次"，算不出"现在还剩多少" | ✅ `GET api.anthropic.com/api/oauth/usage`，返回 `five_hour` / `seven_day` / `seven_day_opus` 各自的 `utilization` + `resets_at`（M4 实测打通）|
| Codex | ✅ 完整，且**同时给两个窗口**：新版 `primary`=5 小时、`secondary`=7 天；旧版只有 `primary`=7 天。**只读 primary 会让同一个数字在两种含义之间静默切换**（实测见过 7 天 64% 与 5 小时 12% 混用），两个都要读 | 不需要 |
| Grok | ❌ 完全没有 | ❌ **也没有**。M4 逆向 Grok CLI 确认：`cli-chat-proxy.grok.com/v1` 只有 chat / models / settings，二进制里的 `rate_limit` 字符串全部来自 AWS SDK 内部限流器。此前 PRD 写的 `api.x.ai` 是认证与对话端点，不是额度端点 |

**凭据位置**（实测）：

| Provider | 位置 |
|---|---|
| Claude Code | Keychain，service = `Claude Code-credentials` |
| Codex | `~/.codex/auth.json` → `tokens` / `OPENAI_API_KEY` / `last_refresh` |
| Grok | `~/.grok/auth.json` → `{"https://auth.x.ai::<uuid>": {"key": "<JWT>"}}` |

**设计决策：分两层，L1 是地基，L2 默认开启补齐额度。**

- **L1 · 本地解析（默认开启，不可关）**
  历史用量、token 明细、等价成本、按项目/模型/分支归因、缓存命中率、Codex 实时额度、Claude 限流事件统计。
  零网络、零凭据读取。**这一层单独就是一个完整可用的产品**——L2 全关时，除了 Claude / Grok 的额度环，其余功能一个不少。

- **L2 · 官方额度接口（默认开启）**
  只补一件事：Claude / Grok 的实时剩余额度与重置倒计时。这是本地日志无论如何答不出的问题，而"我现在还能不能继续用"恰恰是菜单栏应用存在的理由，所以默认开。

  默认开启意味着信任成本全部前置，以下约束因此从"加分项"升级为 **P0 硬性要求**：

  | 约束 | 要求 |
  |---|---|
  | 首启披露 | 首次启动必须弹一次说明页，逐条列出"读取本机哪个位置的凭据、向哪些域名发起何种查询"，并在同一页给出「保持开启 / 切换到离线模式」两个等权按钮。不是勾选式同意书，是一次性告知 + 即时可选 |
  | 全局离线模式 | 菜单栏与设置页各有一个一级入口，一键切断全部网络。开启后 L1 完整可用，UI 明确标注"离线模式 · 额度不可用" |
  | 逐家开关 | 设置页可单独关闭 Claude / Grok 的额度查询 |
  | 域名白名单 | 编译期常量，仅含 `api.anthropic.com`、`api.x.ai`、`auth.x.ai`。CI 加静态检查：源码中出现非白名单 host 的网络调用，构建直接失败 |
  | 凭据处理 | 只在内存中使用，不落库、不写日志、不出现在任何导出文件里；进程退出即销毁 |
  | 失败降级 | 请求失败 / 凭据过期 → 该家额度显示"未连接"并给出原因，绝不弹错、绝不影响 L1 |
  | 请求频率 | 轮询间隔 ≥ 60 秒且可配置；面板打开不额外触发请求；系统休眠 / 无网络时暂停轮询 |
  | 可审计 | 设置页内置「网络活动」面板，明文列出本次运行发出的每一个请求（时间、域名、路径、状态码），用户不装抓包工具也能自查 |

开源项目默认联网，光靠 README 里一句"我们很安全"是不够的，必须给出**用户自己能跑的验证手段**：内置网络活动面板（无需工具）+ README 附一条 `lsof` / Little Snitch 抓包验证步骤（供不信任 UI 的人复核）。这两者缺一不可。

### 2.5 三源差异对照

| 维度 | Claude Code | Codex | Grok |
|---|---|---|---|
| 用量粒度 | 每次 API 请求 | 每轮（含会话累计） | 每轮 |
| 去重键 | `requestId`（必需） | 文件 offset | `eventId` |
| 缓存字段 | 5m/1h 分档 | `cached_input` / `cache_write` | `cachedRead` / `cacheCreation` |
| 推理 token | `thinking_tokens` | `reasoning_output_tokens` | `reasoningTokens` |
| 官方成本 | 无 | 无 | ✅ `costUsdTicks` |
| 官方额度（本地日志） | ❌ 仅有 429 限流事件 | ✅ `used_percent` + `resets_at` | ❌ 无 |
| 官方额度（接口，L2，默认开） | `api.anthropic.com/api/oauth/usage` | 本地已够，不发请求 | `api.x.ai` + `auth.x.ai` |
| 项目归因 | `cwd` 字段 | `session_meta.cwd` | 目录名解码 |
| 数据量 | 449 MB | 1.9 GB | 2.6 MB |

**统一数据模型**（归一化后）：

```swift
struct UsageEvent {
    let id: String            // 去重键：provider + requestId/eventId/offset
    let provider: Provider    // .claudeCode / .codex / .grok
    let timestamp: Date
    let sessionId: String
    let projectPath: String?
    let gitBranch: String?
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWrite5mTokens: Int
    let cacheWrite1hTokens: Int
    let reasoningTokens: Int
    let officialCostUSD: Double?   // 仅 Grok 有；nil 则本地估算
}
```

---

## 3. 功能需求

### F1 菜单栏常驻（P0）

- `MenuBarExtra` 图标 + 可配置文字，支持四种显示模式：
  - `额度`：`◐ 61%`（默认；取三家中最紧张的一家，长按可切换固定显示某一家）
  - `成本`：`$2.41`（今日估算总成本）
  - `Token`：`1.2M`（今日总 token）
  - `仅图标`：极简
- 额度进入警戒（>80%）图标变琥珀色，>95% 变红色并可选发送通知。
- 支持多显示器 / 刘海屏空间不足时自动降级为纯图标。
- 菜单点开后顶部常驻「离线模式」开关，一键切断全部网络。
- 图标为模板图（template image），自动适配浅色/深色菜单栏。

### F2 快捷面板（P0）

点击菜单栏图标弹出，约 380×520，包含：

1. **今日总览**：总成本、总 token、会话数，附昨日环比
2. **三家 Provider 卡片**：各自 token / 成本 / 会话数 + 24h 迷你趋势条
3. **额度环**：Codex 官方 `used_percent`，环下标注"7天窗口 · 3天2小时后重置"
4. **最近会话**：最近 5 条，显示项目名 / 模型 / token / 相对时间
5. 底部：`打开主窗口` · `立即刷新` · `设置` · `退出`

### F3 主窗口 · 仪表盘（P0）

- **时间范围切换**：今日 / 7天 / 30天 / 自定义
- **趋势图**：按天堆叠柱状（三家配色区分），可切 token / 成本
- **模型分布**：横向条形，展示各模型 token 占比与成本
- **Top 项目**：按 cwd 聚合排序，显示成本 / token / 会话数
- **缓存效率**：cache read 占总 input 的比例（这是省钱的关键指标，实测 Codex 缓存命中率 94%，值得单独展示）

### F4 会话明细（P1）

- 可筛选（provider / 项目 / 模型 / 时间）的会话表格
- 列：开始时间、Provider、项目、模型、总 token、输入/输出/缓存拆分、估算成本、时长
- 点击展开该会话的逐轮 token 曲线

### F5 成本估算引擎（P0）

- 内置价格表 `pricing.json`（按 provider + model + token 类型），随版本更新
- 用户可在设置里覆盖单价（应对企业折扣 / 新模型未收录）
- Grok 直接用 `costUsdTicks`，不估算；Claude / Codex 按价格表算
- 价格表缺失模型时，成本显示 `—` 并在设置页提示"3 个模型缺少定价"，绝不静默按 0 计算

### F6 数据采集引擎（P0）

- **首次全量扫描**：后台进行，带进度条，2.4 GB 数据目标 < 60 秒（流式逐行解析，不整文件载入）
- **增量扫描**：记录每个文件的 `(inode, size, mtime, lastOffset)`，只读新增字节
- **实时监听**：`DispatchSource` / `FSEvents` 监听三个根目录，文件变化后 debounce 2s 触发增量解析
- **持久化**：SQLite（`~/Library/Application Support/aibar/aibar.db`），表 `usage_events` + `scan_state` + 按天预聚合表 `daily_rollup`
- 文件被轮转/截断（size < lastOffset）时自动全量重读该文件

### F7 设置（P0）

- 菜单栏显示模式、刷新间隔
- 各 Provider 开关与自定义数据路径（应对非默认 `$CLAUDE_CONFIG_DIR` 等）
- 网络：全局离线模式、逐家额度查询开关、轮询间隔、网络活动面板
- 价格表编辑
- 额度告警阈值与通知开关
- 开机自启（`SMAppService`）
- 数据管理：重建索引、导出 CSV/JSON、清除本地库

### F8 导出（P1）

- CSV / JSON 导出当前筛选结果
- 面板截图分享（社区传播用）

### F9 额度接口层 L2（P0，默认开启）

- Adapter 协议扩展 `func liveQuota() async throws -> QuotaStatus?`，与 L1 完全解耦；L1 不感知 L2 是否存在
- **首启披露页**：一次性告知读取哪些凭据、请求哪些域名，同页给出「保持开启 / 切换到离线模式」等权按钮
- **全局离线模式**：菜单栏与设置页一级入口，一键切断全部网络；开启后菜单栏图标加一个离线角标
- **逐家开关**：设置页可单独关闭 Claude / Grok
- **域名白名单**：编译期常量 + CI 静态检查（非白名单 host 出现即构建失败）
- **网络活动面板**（设置页内）：明文列出本次运行的每一个请求——时间、域名、路径、状态码、耗时。这是默认联网方案的信任基石，不是可选功能
- 菜单栏与面板对 L1 / L2 来源做视觉区分：L1 数据标注"本地"，L2 数据带 ⟳ 与"N 秒前"时间戳
- 凭据只在内存中使用，不落库、不写日志、不进导出文件

### F10 限流洞察（P1）

- 从 Claude 日志抽取 `error == "rate_limit"` 事件，统计本周限流次数、时段分布、平均恢复时长
- 回答"我一般几点会被限流"——这是纯本地就能做、且竞品没做的事

---

## 4. 非功能需求

| 项 | 指标 |
|---|---|
| 内存 | 常驻 < 100 MB（M2 实测 74 MB，SwiftUI 基线约占 60 MB）；全量扫描峰值 < 300 MB |
| CPU | 空闲 < 0.5%（M2 实测 0.03%）；日志持续写入时 < 1%（实测 0.7%）；增量解析单次 < 200ms |
| 首次扫描 | 2.4 GB / < 60s（M2 实测 2.6 GB / 10.3s）|
| 面板打开 | < 100ms（读预聚合表，不实时算） |
| 隐私 | L2 默认开启，但仅访问硬编码官方域名白名单，且提供一键离线模式与内置网络活动面板。任何情况下不读取会话正文，只取 usage 字段；凭据不落盘 |
| 网络 | 轮询间隔 ≥ 60s；休眠 / 断网自动暂停；单次请求超时 10s，失败退避重试最多 3 次 |
| 沙盒 | 不开 App Sandbox（需读 `~/.claude` 等任意路径），发布走 Developer ID 签名 + 公证 |
| 无障碍 | 支持 VoiceOver、动态字体、减弱动效 |
| 本地化 | 中文 / English |

---

## 5. 技术方案

```
aibar/
├── Package.swift                 # SwiftPM，产出 .app bundle
├── Sources/
│   ├── aibarApp/                 # App 入口、MenuBarExtra、窗口
│   ├── aibarUI/                  # SwiftUI 视图 + Swift Charts 图表
│   ├── aibarCore/
│   │   ├── Providers/            # ClaudeCodeAdapter / CodexAdapter / GrokAdapter
│   │   │   └── UsageProvider.swift   # 统一协议
│   │   ├── Ingest/               # 流式 JSONL 解析、增量 offset、FSEvents 监听
│   │   ├── Store/                # SQLite（GRDB.swift）
│   │   ├── Pricing/              # 价格表与成本计算
│   │   └── Models/               # UsageEvent / DailyRollup / QuotaStatus
│   └── aibarCLI/                 # 可选：`aibar report --last 7d` 终端输出
└── Tests/                        # 用真实脱敏样本做解析回归测试
```

技术选型：

| 选择 | 理由 |
|---|---|
| Swift 6 + SwiftUI | 原生要求；`MenuBarExtra` 是 SwiftUI 原生菜单栏 API |
| Swift Charts | 系统自带，无三方依赖，图表风格与系统一致 |
| GRDB.swift | SQLite 封装，成熟稳定，支持 WAL 与值观察 |
| SwiftPM | 无需 Xcode 工程文件，`swift build` 即可，利于开源贡献者 |
| Swift Concurrency | 解析用 `TaskGroup` 并行三家，`actor` 保护 scan state |

**Provider 适配协议**（新增第四家只需实现这一个协议）：

```swift
protocol UsageProvider: Sendable {
    static var id: Provider { get }
    var rootPaths: [URL] { get }                       // 监听目录
    func discoverFiles() async throws -> [URL]
    func parse(_ file: URL, from offset: UInt64) async throws -> (events: [UsageEvent], newOffset: UInt64)
    func quota() async -> QuotaStatus?                 // 仅 Codex 返回非 nil
}
```

---

## 6. 里程碑

| 阶段 | 内容 | 产出 |
|---|---|---|
| ~~M1 · 内核~~ | ~~三个 Adapter + 流式解析 + SQLite + 单测~~ | ✅ 已完成 |
| ~~M2 · 菜单栏~~ | ~~MenuBarExtra + 快捷面板 + FSEvents 增量~~ | ✅ 已完成 |
| ~~M3 · 仪表盘~~ | ~~主窗口、Swift Charts、会话明细~~ | ✅ 已完成 |
| ~~M4 · 打磨~~ | ~~设置、通知、导出、L2 接口层~~ | ✅ 已完成（本地化与无障碍移至 M5）|
| M5 · 开源 | README、截图、CI、公证、Homebrew Cask | v1.0 发布 |

## 7. 开源准备

- License：MIT
- 仓库：`README.md`（含截图 + GIF）、`CONTRIBUTING.md`（重点写"如何新增一个 Provider"）、`docs/data-sources.md`（本文第 2 节，对贡献者最有价值）
- CI：GitHub Actions 跑 `swift build` + `swift test`，tag 触发 release 构建
- 分发：GitHub Release 上传签名公证过的 `.dmg`，并提交 Homebrew Cask
- Issue 模板：新增 Provider 请求 / 解析异常上报（要求附脱敏样本行）

## 8. 风险

| 风险 | 影响 | 应对 |
|---|---|---|
| 上游 CLI 改数据格式 | 解析失效 | 适配层版本嗅探；解析失败降级跳过并计数上报到 UI，不崩溃 |
| Codex 数据量持续增长 | 扫描变慢 | 增量 offset + 按天预聚合；提供"只索引最近 N 天"选项 |
| 价格表过期 | 成本失真 | UI 标注"估算"字样与价格表版本日期；缺定价显式提示 |
| 未签名分发被 Gatekeeper 拦 | 用户装不上 | Developer ID 签名 + 公证；README 写明首次打开方式 |
| 面板查询随数据增长变慢 | 常驻 CPU 飙升 | M2 已踩过：关联子查询导致 43% CPU。规矩是所有面板查询都必须先收窄范围再聚合，且刷新有最小间隔 |
| 环比在历史不足时给出荒谬数字 | 用户被误导 | M3 已处理：数据未覆盖对比区间就不显示环比，而不是显示"▲5728%" |
| **L2 默认开启读取凭据引发信任危机** | 开源项目被质疑甚至被喷"偷 token"，是本项目最大的声誉风险 | 首启一次性披露 + 一键离线模式 + 逐家开关 + 编译期域名白名单 + CI 静态检查 + 内置网络活动面板 + README 抓包验证步骤。六道措施缺一不可；Release 说明里主动写明"默认联网做什么、怎么关" |
| 官方额度接口无文档、随时可能变 | L2 失效 | L2 失败不影响 L1；UI 显示"未连接"而非报错弹窗 |
| Claude 重复行去重遗漏 | 数字翻倍 | `requestId` 唯一索引由数据库强制，重复插入直接忽略 |
