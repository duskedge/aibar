import Foundation
import Testing
@testable import AibarCore

/// 用真实日志里提取出的样本行做回归。上游任何一家改格式，这里先红。
@Suite("三家日志解析")
struct ParsingTests {

    // MARK: - 工具

    func write(_ lines: [String], to name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Claude

    /// 实测：5850 行只有 3458 个唯一 requestId，重复组的 usage 完全一致。
    @Test("Claude 按 requestId 去重")
    func claudeDedup() throws {
        let line = """
        {"type":"assistant","requestId":"req_A","timestamp":"2026-08-20T09:57:56.668Z",\
        "sessionId":"s1","cwd":"/Users/x/code/demo","gitBranch":"main",\
        "message":{"model":"claude-opus-5","usage":{"input_tokens":2,"output_tokens":729,\
        "cache_read_input_tokens":0,"cache_creation_input_tokens":33283,\
        "cache_creation":{"ephemeral_1h_input_tokens":33283,"ephemeral_5m_input_tokens":0},\
        "output_tokens_details":{"thinking_tokens":317}}}}
        """
        let file = try write([line, line, line], to: "s1.jsonl")
        let result = try ClaudeCodeProvider().parse(file: file, from: 0, cursor: nil)

        // 解析层原样交出三条；去重由数据库主键兜底
        #expect(result.events.count == 3)
        #expect(Set(result.events.map(\.id)) == ["req_A"])

        let store = try UsageStore(path: ":memory:")
        #expect(try store.insert(events: result.events) == 3)
        var rows = 0
        try store.db.query("SELECT COUNT(*) FROM usage_events") { rows = $0.int(0) }
        #expect(rows == 1, "同一 requestId 在库里只能留一条")

        let e = result.events[0]
        #expect(e.cacheWrite1hTokens == 33283)
        #expect(e.cacheWrite5mTokens == 0)
        #expect(e.reasoningTokens == 317)
        #expect(e.projectName == "demo")
        #expect(e.gitBranch == "main")
    }

    @Test("Claude 跳过 <synthetic> 并收集限流事件")
    func claudeRateLimit() throws {
        let line = """
        {"type":"assistant","requestId":"req_B","timestamp":"2026-07-28T09:57:56.668Z",\
        "sessionId":"s2","error":"rate_limit","apiErrorStatus":429,"uuid":"u-1",\
        "message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0},\
        "content":[{"type":"text","text":"You've hit your session limit · resets 7:50pm"}]}}
        """
        let result = try ClaudeCodeProvider().parse(file: try write([line], to: "s2.jsonl"),
                                                    from: 0, cursor: nil)
        #expect(result.events.isEmpty, "<synthetic> 不算用量")
        #expect(result.rateLimits.count == 1)
        #expect(result.rateLimits[0].message.contains("session limit"))
    }

    // MARK: - Codex

    func codexLine(_ ts: String, total: Int, input: Int, cached: Int, output: Int) -> String {
        """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{\
        "total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":0,\
        "total_tokens":\(total)},"model_context_window":258400}}}
        """
    }

    @Test("Codex 用 total 单调差值切分，而非 sum(last)")
    func codexDelta() throws {
        let file = try write([
            #"{"timestamp":"2026-08-20T09:00:00.000Z","type":"session_meta","payload":{"id":"cs1","cwd":"/Users/x/code/srv"}}"#,
            codexLine("2026-08-20T09:01:00.000Z", total: 1000, input: 900, cached: 800, output: 100),
            codexLine("2026-08-20T09:02:00.000Z", total: 2500, input: 2200, cached: 2000, output: 300),
        ], to: "rollout-cs1.jsonl")

        let result = try CodexProvider().parse(file: file, from: 0, cursor: nil)
        #expect(result.events.count == 2)
        // 第二条只应记增量，不是累计值
        let second = result.events[1]
        #expect(second.cacheReadTokens == 1200)          // 2000 - 800
        #expect(second.outputTokens == 200)              // 300 - 100
        #expect(second.inputTokens == 100)               // (2200-900) - 1200
        #expect(result.events.map(\.totalTokens).reduce(0, +) == 2500)
        #expect(result.events[0].projectName == "srv")
    }

    /// M1 实测发现：上下文压缩会让 total 中途回退。
    /// "末条 total" 口径会把回退前的整段用量全丢掉。
    @Test("Codex total 回退时不丢前段用量")
    func codexReset() throws {
        let file = try write([
            #"{"timestamp":"2026-08-25T09:00:00.000Z","type":"session_meta","payload":{"id":"cs2","cwd":"/Users/x/code/srv"}}"#,
            codexLine("2026-08-25T09:01:00.000Z", total: 1_000_000, input: 990_000, cached: 900_000, output: 10_000),
            // 压缩：total 掉回一个小值
            codexLine("2026-08-25T09:02:00.000Z", total: 60_000, input: 59_000, cached: 50_000, output: 1_000),
            codexLine("2026-08-25T09:03:00.000Z", total: 300_000, input: 295_000, cached: 250_000, output: 5_000),
        ], to: "rollout-cs2.jsonl")

        let result = try CodexProvider().parse(file: file, from: 0, cursor: nil)
        let total = result.events.map(\.totalTokens).reduce(0, +)
        #expect(total == 1_240_000, "应为 1,000,000 + (300,000 - 60,000)，而不是末条的 300,000")
    }

    /// Codex 同时给两个窗口：新版 primary=5 小时 / secondary=7 天，
    /// 旧版只有 primary=7 天。只读 primary 会让同一个数字在两种含义之间
    /// 静默切换 —— 实测见过 7 天 64% 和 5 小时 12% 混在一起。
    @Test("Codex 的 primary 与 secondary 两个窗口都要取")
    func codexQuotaBothWindows() throws {
        let line = """
        {"timestamp":"2026-08-26T09:01:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"total_tokens":15}},\
        "rate_limits":{"primary":{"used_percent":14.0,"window_minutes":300,"resets_at":1787725062},\
        "secondary":{"used_percent":2.0,"window_minutes":10080,"resets_at":1788311862},\
        "plan_type":"plus"}}}
        """
        let result = try CodexProvider().parse(file: try write([line], to: "rollout-q.jsonl"),
                                               from: 0, cursor: nil)
        #expect(result.quotas.count == 2)
        let five = try #require(result.quotas[300])
        let seven = try #require(result.quotas[10080])
        #expect(five.usedPercent == 14.0)
        #expect(seven.usedPercent == 2.0)
        #expect(five.planType == "plus")
        #expect(five.source == QuotaStatus.Source.localLog)
    }

    /// 旧版 Codex 只有 primary，且它是 7 天窗口。
    @Test("旧版单窗口格式仍然能解析")
    func codexQuotaLegacySingleWindow() throws {
        let line = """
        {"timestamp":"2026-07-20T09:01:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"total_tokens":15}},\
        "rate_limits":{"primary":{"used_percent":61.0,"window_minutes":10080,"resets_at":1786163142},\
        "secondary":null,"plan_type":"plus"}}}
        """
        let result = try CodexProvider().parse(file: try write([line], to: "rollout-legacy.jsonl"),
                                               from: 0, cursor: nil)
        #expect(result.quotas.count == 1)
        #expect(result.quotas[10080]?.usedPercent == 61.0)
    }

    // MARK: - Grok

    @Test("Grok 用官方 costUsdTicks，不走价格表")
    func grokCost() throws {
        let line = """
        {"timestamp":1787637939,"method":"_x.ai/session/update","params":{"sessionId":"gs1",\
        "update":{"sessionUpdate":"turn_completed","stop_reason":"end_turn","usage":{\
        "inputTokens":16351,"outputTokens":214,"totalTokens":16565,"cachedReadTokens":10752,\
        "cacheCreationTokens":0,"reasoningTokens":154,"modelCalls":1,"costUsdTicks":178580000,\
        "modelUsage":{"grok-4.6":{"inputTokens":16351,"outputTokens":214,"totalTokens":16565,\
        "cachedReadTokens":10752,"cacheCreationTokens":0,"reasoningTokens":154,"costUsdTicks":178580000}}}}},\
        "_meta":{"eventId":"gs1-92"}}
        """
        // 目录名是 URL 编码的 cwd
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-tests/\(UUID().uuidString)/%2FUsers%2Fx%2Fcode%2Fhub/gs1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("updates.jsonl")
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)

        let result = try GrokProvider().parse(file: file, from: 0, cursor: nil)
        let e = try #require(result.events.first)
        #expect(e.model == "grok-4.6")
        #expect(e.officialCostUSD == 0.017858)
        #expect(e.projectPath == "/Users/x/code/hub")
        #expect(e.cacheReadTokens == 10752)
        #expect(e.inputTokens == 16351 - 10752, "inputTokens 含缓存，要拆出来")
        // 价格表必须让路给官方值
        #expect(PricingTable.builtin.cost(of: e) == 0.017858)
    }

    /// Grok 的官方周额度不在会话目录，而在 ~/.grok/logs/unified.jsonl。
    /// 早期版本只翻了会话目录就断言"Grok 没有额度接口"——结论下早了，
    /// grok 命令自己的 Usage limit 面板显示的就是这个数。
    @Test("Grok 从统一日志取出官方周额度")
    func grokWeeklyQuota() throws {
        let lines = [
            #"{"ts":"2026-08-26T03:19:09.810Z","src":"shell","lvl":"info","msg":"some other log"}"#,
            """
            {"ts":"2026-08-26T03:21:50.820Z","src":"shell","lvl":"info",\
            "msg":"billing: fetched credits config","ctx":{"config":{\
            "creditUsagePercent":4.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
            "start":"2026-08-26T00:57:35.165633+00:00","end":"2026-09-02T00:57:35.165633+00:00"},\
            "onDemandCap":{"val":0},"prepaidBalance":{"val":0}},"subscriptionTier":"SuperGrok"}}
            """,
        ]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-tests/\(UUID().uuidString)/logs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("unified.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let result = try GrokProvider().parse(file: file, from: 0, cursor: nil)
        let q = try #require(result.quotas[10080])
        #expect(q.usedPercent == 4.0)
        #expect(q.planType == "SuperGrok")
        #expect(q.source == QuotaStatus.Source.localLog)
        #expect(q.provider == Provider.grok)
        // 2026-09-02T00:57:35Z
        #expect(abs((q.resetsAt?.timeIntervalSince1970 ?? 0) - 1_788_310_655) < 2)
        #expect(result.events.isEmpty, "计费日志里没有用量事件")
        #expect(result.malformedLines == 0, "无关日志行应被字节预筛跳过，不算解析失败")
    }

    /// 月度 / 日度周期也要认，虽然目前只见过 WEEKLY。
    @Test("Grok 周期类型映射到窗口长度")
    func grokPeriodTypes() throws {
        func quota(_ type: String) throws -> QuotaStatus? {
            let line = """
            {"ts":"2026-08-26T03:00:00.000Z","msg":"billing: fetched credits config","ctx":{\
            "config":{"creditUsagePercent":10,"currentPeriod":{"type":"\(type)",\
            "end":"2026-09-02T00:00:00Z"}},"subscriptionTier":"X"}}
            """
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("aibar-tests/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("unified.jsonl")
            try (line + "\n").write(to: f, atomically: true, encoding: .utf8)
            return try GrokProvider().parse(file: f, from: 0, cursor: nil).quotas.values.first
        }
        #expect(try quota("USAGE_PERIOD_TYPE_WEEKLY")?.windowMinutes == 10080)
        #expect(try quota("USAGE_PERIOD_TYPE_MONTHLY")?.windowMinutes == 43200)
        #expect(try quota("USAGE_PERIOD_TYPE_DAILY")?.windowMinutes == 1440)
    }

    // MARK: - 增量续读

    @Test("追加写入后只解析新增部分")
    func incremental() throws {
        let mk = { (rid: String, ts: String) in """
            {"type":"assistant","requestId":"\(rid)","timestamp":"\(ts)","sessionId":"s3",\
            "message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":20,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        }
        let file = try write([mk("r1", "2026-08-20T09:00:00.000Z")], to: "s3.jsonl")
        let p = ClaudeCodeProvider()
        let first = try p.parse(file: file, from: 0, cursor: nil)
        #expect(first.events.count == 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((mk("r2", "2026-08-20T09:05:00.000Z") + "\n").utf8))
        try handle.close()

        let second = try p.parse(file: file, from: first.newOffset, cursor: nil)
        #expect(second.events.count == 1)
        #expect(second.events[0].id == "r2")
    }

    @Test("跨块的长行不会被截断")
    func longLineAcrossChunks() throws {
        // 造一行远超块大小的 JSON
        let filler = String(repeating: "x", count: 300_000)
        let line = """
        {"type":"assistant","requestId":"big","timestamp":"2026-08-20T09:00:00.000Z","sessionId":"s4",\
        "note":"\(filler)","message":{"model":"claude-opus-5","usage":{"input_tokens":1,\
        "output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}
        """
        let file = try write([line], to: "s4.jsonl")
        var seen = 0
        let end = try LineReader.read(file: file, from: 0, chunkSize: 4096) { l in
            if l.contains(bytes: Array(#""usage""#.utf8)) { seen += 1 }
        }
        #expect(seen == 1)
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
        #expect(end == UInt64(size ?? 0))
    }

    // MARK: - 价格表

    @Test("价格表前缀匹配取最长命中")
    func pricingPrefix() throws {
        let t = PricingTable.builtin
        #expect(t.price(for: "gpt-5.6-sol")?.input == 1.25)
        #expect(t.price(for: "claude-opus-5")?.output == 75)
        #expect(t.price(for: "totally-unknown-model") == nil, "未知模型必须返回 nil，不能当 0")
    }

    @Test("缺定价的模型成本为 nil，不是 0")
    func pricingMissing() throws {
        let e = UsageEvent(id: "x", provider: .codex, timestamp: .now, sessionId: "s",
                           model: "codex-auto-review", inputTokens: 1000, outputTokens: 100)
        #expect(PricingTable.builtin.cost(of: e) == nil)
        #expect(PricingTable.builtin.unpricedModels(in: ["codex-auto-review", "claude-opus-5"])
                == ["codex-auto-review"])
    }

    // MARK: - 日期

    @Test("ISO8601 解析与 Foundation 一致")
    func dateParsing() throws {
        let samples = ["2026-08-20T09:57:56.668Z", "2026-01-01T00:00:00Z", "2024-02-29T23:59:59.999Z"]
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for s in samples {
            let mine = try #require(DateParsing.iso8601UTC(s))
            let theirs = try #require(f.date(from: s) ?? ISO8601DateFormatter().date(from: s))
            #expect(abs(mine.timeIntervalSince1970 - theirs.timeIntervalSince1970) < 0.002, "\(s)")
        }
    }
}
