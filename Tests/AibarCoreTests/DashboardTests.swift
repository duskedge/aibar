import Foundation
import Testing
@testable import AibarCore

@Suite("仪表盘与会话明细")
struct DashboardTests {

    func store(_ events: [UsageEvent]) throws -> UsageStore {
        let s = try UsageStore(path: ":memory:")
        _ = try s.insert(events: events)
        return s
    }

    func event(_ provider: Provider, _ model: String,
               input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0,
               session: String = "s", project: String = "/Users/x/code/demo",
               branch: String? = nil, minutesAgo: Int = 0, id: String = UUID().uuidString,
               officialCost: Double? = nil) -> UsageEvent {
        UsageEvent(id: id, provider: provider,
                   timestamp: Date().addingTimeInterval(-Double(minutesAgo) * 60),
                   sessionId: session, projectPath: project, gitBranch: branch, model: model,
                   inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
                   cacheWrite5mTokens: cacheWrite, officialCostUSD: officialCost)
    }

    // MARK: - 范围

    @Test("DateRange 的边界自洽")
    func rangeBounds() {
        #expect(DateRange.all.since == nil)
        #expect(DateRange.today.dayCount == 1)
        #expect(DateRange.week.dayCount == 7)
        let cal = Calendar.current
        let since = try? #require(DateRange.week.since)
        if let since {
            let days = cal.dateComponents([.day], from: since, to: .now).day ?? 0
            #expect(days == 6, "7 天窗口从今天往前推 6 天")
        }
    }

    /// 数据不覆盖对比区间时，宁可不显示环比，也不给一个假的增长率。
    @Test("历史不足时不给环比")
    func noComparisonWithoutHistory() throws {
        let s = try store([event(.claudeCode, "claude-opus-5", input: 1000, minutesAgo: 10)])
        let d = try Reports(store: s).dashboard(range: .month)
        #expect(d.hasComparison == false)
        #expect(d.totals.tokens == 1000)
    }

    @Test("历史足够时给出环比")
    func comparisonWithHistory() throws {
        let cal = Calendar.current
        let old = cal.date(byAdding: .day, value: -40, to: .now)!
        let s = try store([
            UsageEvent(id: "old", provider: .codex, timestamp: old, sessionId: "a",
                       model: "gpt-5.6", inputTokens: 100),
            event(.codex, "gpt-5.6", input: 900, id: "new"),
        ])
        let d = try Reports(store: s).dashboard(range: .week)
        #expect(d.hasComparison, "库里有 40 天前的数据，7 天窗口的上一区间是有覆盖的")
    }

    // MARK: - 会话明细

    @Test("会话明细的拆分与跨度")
    func sessionBreakdown() throws {
        let s = try store([
            event(.claudeCode, "claude-opus-5", input: 100, output: 50, cacheRead: 800,
                  cacheWrite: 50, session: "a", branch: "main", minutesAgo: 30, id: "1"),
            event(.claudeCode, "claude-opus-5", input: 200, output: 20, cacheRead: 1200,
                  session: "a", branch: "main", minutesAgo: 5, id: "2"),
        ])
        let rows = try Reports(store: s).sessions(range: .week)
        let row = try #require(rows.first)

        #expect(row.turns == 2)
        #expect(row.input == 300)
        #expect(row.output == 70)
        #expect(row.cacheRead == 2000)
        #expect(row.cacheWrite == 50)
        #expect(row.tokens == 2420)
        #expect(row.branch == "main")
        // 跨度 25 分钟
        #expect(abs(row.duration - 1500) < 60)
        // 缓存命中 = 2000 / (300 + 2000 + 50)
        #expect(abs(row.cacheHitRate - 2000.0 / 2350.0) < 0.001)
    }

    @Test("会话明细支持按 Provider 与关键词筛选")
    func sessionFiltering() throws {
        let s = try store([
            event(.claudeCode, "claude-opus-5", input: 100, session: "a",
                  project: "/Users/x/code/alpha", id: "1"),
            event(.codex, "gpt-5.6-sol", input: 100, session: "b",
                  project: "/Users/x/code/beta", id: "2"),
        ])
        let r = Reports(store: s)
        #expect(try r.sessions(range: .week, provider: .codex).count == 1)
        #expect(try r.sessions(range: .week, provider: nil, search: "alpha").count == 1)
        #expect(try r.sessions(range: .week, provider: nil, search: "gpt-5.6").count == 1)
        #expect(try r.sessions(range: .week, provider: nil, search: "不存在").isEmpty)
    }

    @Test("逐轮曲线按时间升序")
    func timelineOrdering() throws {
        let s = try store([
            event(.grok, "grok-4.6", input: 300, session: "g", minutesAgo: 1, id: "3"),
            event(.grok, "grok-4.6", input: 100, session: "g", minutesAgo: 9, id: "1"),
            event(.grok, "grok-4.6", input: 200, session: "g", minutesAgo: 5, id: "2"),
        ])
        let points = try Reports(store: s).timeline(sessionId: "g", provider: .grok)
        #expect(points.map(\.tokens) == [100, 200, 300])
        for i in 1..<points.count {
            #expect(points[i].timestamp > points[i - 1].timestamp)
        }
    }

    // MARK: - 成本口径

    /// Grok 自带官方成本，绝不能被本地价格表覆盖。
    @Test("官方成本优先于价格表")
    func officialCostWins() throws {
        let s = try store([
            event(.grok, "grok-4.6", input: 16351, output: 214,
                  session: "g", id: "1", officialCost: 0.017858),
        ])
        let t = try Reports(store: s).totals()
        #expect(abs(t.cost - 0.017858) < 1e-9)
    }

    /// 缺定价的部分必须能单独报出来，好在 UI 上说清"这些没算进去"。
    @Test("缺定价的量能单独统计")
    func unpricedVolume() throws {
        let s = try store([
            event(.claudeCode, "claude-opus-5", input: 1_000_000, id: "1"),
            event(.codex, "codex-auto-review", input: 500_000, id: "2"),
        ])
        let r = Reports(store: s)
        let vol = try r.unpricedVolume()
        #expect(vol.events == 1)
        #expect(vol.tokens == 500_000)
        // 总成本只算得出定价的那部分：1M input × $15/Mtok
        #expect(abs(try r.totals().cost - 15.0) < 0.001)
    }

    @Test("按分支归因")
    func branchBreakdown() throws {
        let s = try store([
            event(.claudeCode, "claude-opus-5", input: 300, session: "a", branch: "main", id: "1"),
            event(.claudeCode, "claude-opus-5", input: 100, session: "b", branch: "dev", id: "2"),
            event(.codex, "gpt-5.6", input: 200, session: "c", branch: nil, id: "3"),
        ])
        let buckets = try Reports(store: s).breakdown(by: .branch)
        #expect(buckets.first?.key == "main")
        #expect(buckets.first?.tokens == 300)
        #expect(buckets.contains { $0.key == "(无)" }, "没有分支的也要归到一类，不能丢")
    }
}

@Suite("花费预算")
struct BudgetTests {

    func store(_ events: [UsageEvent]) throws -> UsageStore {
        let s = try UsageStore(path: ":memory:")
        _ = try s.insert(events: events)
        return s
    }

    /// 预算按等价 API 成本算，和官方额度是两套口径。
    @Test("预算进度按成本计算")
    func budgetProgress() throws {
        // 1M input × $15/Mtok = $15
        let s = try store([
            UsageEvent(id: "1", provider: .claudeCode, timestamp: .now, sessionId: "a",
                       model: "claude-opus-5", inputTokens: 1_000_000),
        ])
        let progress = try Reports(store: s).budgetProgress(
            [Budget(provider: .claudeCode, limitUSD: 100, window: .month)])
        #expect(progress.count == 1)
        #expect(abs(progress[0].spentUSD - 15) < 0.01)
        #expect(abs(progress[0].usedPercent - 15) < 0.01)
        #expect(abs(progress[0].remainingUSD - 85) < 0.01)
        #expect(!progress[0].hasUnpricedUsage)
    }

    @Test("未设置上限的不产生进度")
    func unconfiguredBudgetIgnored() throws {
        let s = try store([])
        #expect(try Reports(store: s).budgetProgress(
            [Budget(provider: .grok, limitUSD: 0)]).isEmpty)
    }

    /// 缺定价意味着进度被低估，必须能被标出来。
    @Test("含缺定价模型时打标")
    func unpricedIsFlagged() throws {
        let s = try store([
            UsageEvent(id: "1", provider: .codex, timestamp: .now, sessionId: "a",
                       model: "gpt-5.6", inputTokens: 1_000_000),
            UsageEvent(id: "2", provider: .codex, timestamp: .now, sessionId: "a",
                       model: "codex-auto-review", inputTokens: 500_000),
        ])
        let progress = try Reports(store: s).budgetProgress(
            [Budget(provider: .codex, limitUSD: 50)])
        #expect(progress[0].hasUnpricedUsage)
    }

    @Test("超支不会算出离谱的百分比")
    func overspendIsClamped() {
        let p = BudgetProgress(provider: .grok, spentUSD: 1_000_000, limitUSD: 1,
                               window: .week, hasUnpricedUsage: false)
        #expect(p.usedPercent == 999)
        #expect(p.remainingUSD == 0)
    }

    @Test("预算编解码往返")
    func budgetRoundTrip() {
        let input = [Budget(provider: .grok, limitUSD: 30, window: .week)]
        let decoded = BudgetStore.decode(BudgetStore.encode(input))
        #expect(decoded == input)
        // 归一化后三家都有一条
        #expect(BudgetStore.normalized(decoded).count == 3)
        #expect(BudgetStore.decode("坏掉的 JSON").isEmpty)
    }
}
