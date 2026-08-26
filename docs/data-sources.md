# 三家日志的数据源

给贡献者看的实测记录。所有结论都在 macOS 26.5.2 上验证过，
每一条都注明了**怎么验证的**，方便你在上游改格式后自己复核。

## 速查

| | 用量记录 | 官方额度 | 需要联网 |
|---|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` → `type=="assistant"` 的 `message.usage` | `api.anthropic.com/api/oauth/usage` | 是 |
| Codex | `~/.codex/{sessions,archived_sessions}/**/*.jsonl` → `payload.type=="token_count"` | 同一批文件的 `payload.rate_limits` | 否 |
| Grok | `~/.grok/sessions/**/updates.jsonl` → `sessionUpdate=="turn_completed"` | `~/.grok/logs/unified.jsonl` → `msg=="billing: fetched credits config"` | 否 |

## 四个必须处理的坑

### 1. Claude 的重复行

同一次请求会重复落盘。实测 5850 行只有 3458 个唯一 `requestId`（41% 是重复），
且重复组的 `usage` 完全一致。

```bash
# 复核
find ~/.claude/projects -name '*.jsonl' | xargs cat \
  | jq -r 'select(.type=="assistant" and .message.usage) | .requestId' \
  | sort | uniq -d | wc -l
```

按 `requestId` 去重，交给数据库主键强制。另外**必须递归遍历**：
子 agent 会话在 `<sessionId>/subagents/agent-*.jsonl`，只扫一层会漏掉。

### 2. Codex 的 total 会中途回退

日志同时给 `total_token_usage`（会话累计）与 `last_token_usage`（本轮增量），
但两者不自洽——`sum(last)` 会超出末条 `total` 最多约 6%。

更要命的是 `total` 会在**上下文压缩**时归零重来：

```
… 1,080,018 → 1,140,294 → 63,168 → 133,731 → … → 1,306,133
                            ↑ 计数器重置
```

取「末条 total」会把回退前的 114 万 token 整段丢掉。正确做法是取**相邻 total 的
单调差值**，回退时重置基线继续累计。全量实测：562 个会话中 2 个发生过回退（0.4%），
旧口径共少算 768 万 token（0.3%）。

### 3. Codex 的额度有两个窗口

新版同时给 `primary`（5 小时）与 `secondary`（7 天）；旧版只有 `primary`，
而且那时的 `primary` 是 7 天。

**只读 `primary` 会让同一个数字在两种含义之间静默切换**——
实测见过菜单栏先显示 7 天 64%，后来变成 5 小时 12%，用户完全无从察觉。
两个都要读，存储主键必须包含 `window_minutes`。

### 4. Grok 的额度不在会话目录

```bash
grep 'billing: fetched credits config' ~/.grok/logs/unified.jsonl | tail -1 | jq .
```

```json
{"ts":"2026-08-26T03:21:50.820Z","msg":"billing: fetched credits config",
 "ctx":{"config":{"creditUsagePercent":4.0,
                  "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
                                   "start":"2026-08-26T00:57:35Z",
                                   "end":"2026-09-02T00:57:35Z"}},
        "subscriptionTier":"SuperGrok"}}
```

和 `grok` 命令里 `Usage limit` 面板显示的完全一致。

> **注意查找范围。** 额度不在 `~/.grok/sessions/` 下，也不在 Grok CLI 二进制的
> 端点表里 —— 只翻这两处会误判成「没有官方额度」。
>
> 判断某个数据「不存在」之前，先确认该 CLI 自己的界面有没有在显示它。
> 界面能显示，就说明数据一定来自某处。

## 成本口径

- **Grok 自带官方成本**：`costUsdTicks / 1e10` = 美元
  （实测 178580000 ticks ≈ $0.01786，与 grok-4.6 官方价吻合）。一律优先于本地价格表。
- **Claude / Codex 不回传金额**，按内置价格表估算。缺定价的模型成本显示 `—`
  并单独提示未计入总额，**绝不静默按 0 计**——那会让用户以为自己没花钱。
- Claude 的缓存写入分 5 分钟 / 1 小时两档，单价不同，必须拆开算。
- Codex 的 `input_tokens` **含** `cached_input_tokens`，要减出真正的非缓存输入。

## 新增一家 Provider

实现 `UsageProvider` 协议即可，其余部分不用动：

```swift
protocol UsageProvider: Sendable {
    var provider: Provider { get }
    var rootPaths: [URL] { get }          // FSEvents 监听这些目录
    func discoverFiles() -> [URL]
    func parse(file: URL, from offset: UInt64, cursor: String?) throws -> ScanResult
}
```

`ScanResult` 里带 `events` / `rateLimits` / `quotas`（按 window_minutes 索引）/
`newOffset` / `cursor`（provider 私有的续读游标，Codex 用它记住上一次的 total）。

提 PR 时请附上**脱敏的样本行**，并在 `Tests/AibarCoreTests/ParsingTests.swift`
里加一个用例——上游改格式时，那里会第一个变红。
