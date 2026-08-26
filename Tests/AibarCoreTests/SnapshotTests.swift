import Foundation
import Testing
@testable import AibarCore

@Suite("快照聚合与格式化")
struct SnapshotTests {

    /// 建一个内存库并塞入事件
    func store(_ events: [UsageEvent]) throws -> UsageStore {
        let s = try UsageStore(path: ":memory:")
        _ = try s.insert(events: events)
        return s
    }

    func event(_ provider: Provider, _ model: String, tokens: Int,
               session: String = "s", project: String = "/Users/x/code/demo",
               daysAgo: Int = 0, id: String = UUID().uuidString) -> UsageEvent {
        UsageEvent(id: id, provider: provider,
                   timestamp: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
                   sessionId: session, projectPath: project, model: model,
                   inputTokens: tokens)
    }

    // MARK: - 空态

    /// 当天没跑的 Provider 必须留在列表里显示为零。
    /// 直接把行删掉，用户无法分辨“今天没用”和“这家没接上”。
    @Test("三家都出现，零用量不隐藏")
    func zeroProvidersVisible() throws {
        let s = try store([event(.claudeCode, "claude-opus-5", tokens: 1000)])
        let snap = try Reports(store: s).snapshot()

        #expect(snap.todayByProvider.count == 3)
        #expect(snap.todayByProvider.map(\.provider) == Provider.allCases)
        let codex = try #require(snap.todayByProvider.first { $0.provider == .codex })
        #expect(codex.tokens == 0)
        #expect(codex.sessions == 0)
    }

    @Test("完全没有数据时 isEmpty 为真")
    func emptySnapshot() throws {
        let snap = try Reports(store: try store([])).snapshot()
        #expect(snap.isEmpty)
    }

    // MARK: - 最近会话

    @Test("会话的代表模型取 token 最多的那个")
    func sessionTopModel() throws {
        let s = try store([
            event(.codex, "gpt-5.4", tokens: 100, session: "a", id: "1"),
            event(.codex, "gpt-5.6-sol", tokens: 9000, session: "a", id: "2"),
            event(.codex, "gpt-5.4", tokens: 200, session: "a", id: "3"),
        ])
        let rows = try Reports(store: s).recentSessions()
        #expect(rows.count == 1)
        #expect(rows[0].model == "gpt-5.6-sol", "应取 token 最多的，而不是最后一个")
        #expect(rows[0].tokens == 9300)
        #expect(rows[0].project == "demo")
    }

    @Test("最近会话按最后活动时间倒序")
    func sessionOrdering() throws {
        let s = try store([
            event(.codex, "gpt-5.6", tokens: 100, session: "old", daysAgo: 3, id: "1"),
            event(.grok, "grok-4.6", tokens: 100, session: "new", daysAgo: 0, id: "2"),
            event(.claudeCode, "claude-opus-5", tokens: 100, session: "mid", daysAgo: 1, id: "3"),
        ])
        let rows = try Reports(store: s).recentSessions()
        #expect(rows.map(\.provider) == [.grok, .claudeCode, .codex])
    }

    // MARK: - 按天序列

    /// 中间没用量的日期必须补零，否则图表会把不相邻的两天画在一起。
    @Test("按天序列补齐空缺日期")
    func dailySeriesFillsGaps() throws {
        let s = try store([
            event(.claudeCode, "claude-opus-5", tokens: 500, daysAgo: 0, id: "1"),
            event(.codex, "gpt-5.6", tokens: 300, daysAgo: 3, id: "2"),
        ])
        let series = try Reports(store: s).dailySeries(days: 5)
        #expect(series.count == 5)
        #expect(series.filter { $0.total > 0 }.count == 2)
        #expect(series.last?.byProvider[.claudeCode] == 500)
        // 日期严格递增且连续
        for i in 1..<series.count {
            let gap = series[i].day.timeIntervalSince(series[i - 1].day)
            #expect(abs(gap - 86400) < 3700, "相邻两点应相差一天")
        }
    }

    // MARK: - 额度

    @Test("额度过期能被识别")
    func quotaStaleness() {
        let fresh = QuotaStatus(provider: .codex, usedPercent: 61, windowMinutes: 10080,
                                resetsAt: .now.addingTimeInterval(3600), planType: "plus",
                                observedAt: .now, source: .localLog)
        let old = QuotaStatus(provider: .codex, usedPercent: 61, windowMinutes: 10080,
                              resetsAt: nil, planType: nil,
                              observedAt: .now.addingTimeInterval(-7200), source: .localLog)
        #expect(!fresh.isStale())
        #expect(old.isStale())
        #expect(fresh.windowDescription == "7 天窗口")
    }

    @Test("告警阈值分级")
    func thresholdLevels() {
        let t = Thresholds(warn: 80, critical: 95)
        #expect(t.level(for: 61) == .normal)
        #expect(t.level(for: 80) == .warning)
        #expect(t.level(for: 96) == .critical)
    }

    // MARK: - 格式化

    @Test("成本为 nil 时渲染成破折号而不是 $0")
    func costFormatting() {
        #expect(Fmt.cost(nil) == "—")
        #expect(Fmt.cost(0) == "$0")
        #expect(Fmt.cost(0.017858) == "$0.018")
        #expect(Fmt.cost(52.38) == "$52.38")
        #expect(Fmt.cost(8457.2) == "$8457")
    }

    @Test("token 数量分级")
    func tokenFormatting() {
        #expect(Fmt.tokens(842) == "842")
        #expect(Fmt.tokens(23_100_000) == "23.1M")
        #expect(Fmt.tokens(8_440_000_000) == "8.44B")
    }

    @Test("时长文案")
    func durationFormatting() {
        #expect(Fmt.duration(86400 * 5 + 3600 * 7) == "5 天 7 小时")
        #expect(Fmt.duration(3600 * 2 + 60 * 30) == "2 小时 30 分")
        #expect(Fmt.duration(90) == "1 分钟")
        #expect(Fmt.duration(-100) == "1 分钟", "已过期不应出现负数")
    }

    /// 基数为 0 时没有百分比可言，必须返回 nil 而不是 ∞ 或 100%。
    @Test("环比在基数为零时不编数字")
    func deltaFormatting() {
        #expect(Fmt.delta(100, 0) == nil)
        #expect(Fmt.delta(52.38, 14.23) == "▲ 268%")
        #expect(Fmt.delta(10, 20) == "▼ 50%")
        #expect(Fmt.delta(100, 100.2) == "持平")
    }

    // MARK: - 引擎节流

    /// 用户跑对话时 CLI 持续写日志，FSEvents 会一直触发。
    /// 没有下限就会变成“扫完立刻再扫”，实测能把 CPU 顶到 40% 以上。
    @Test("刷新有最小间隔，force 可以绕过")
    func refreshThrottling() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 指向空的临时目录，不去碰用户本机的真实日志
        let logs = dir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let engine = try UsageEngine(
            dbPath: dir.appendingPathComponent("t.db").path,
            providers: [ClaudeCodeProvider(root: logs)])

        _ = try await engine.refresh()
        let before = await engine.lastRefreshedAt

        _ = try await engine.refresh()
        #expect(await engine.lastRefreshedAt == before, "节流窗口内不应重新扫描")

        _ = try await engine.refresh(force: true)
        #expect(await engine.lastRefreshedAt != before, "force 应绕过节流")
    }
}

@Suite("菜单栏显示选择")
struct MenuBarTests {

    func quota(_ p: Provider, _ percent: Double, minutes: Int,
               source: QuotaStatus.Source = .localLog) -> QuotaStatus {
        QuotaStatus(provider: p, usedPercent: percent, windowMinutes: minutes,
                    resetsAt: .now.addingTimeInterval(3600), planType: nil,
                    observedAt: .now, source: source)
    }

    func snapshot() -> Snapshot {
        var s = Snapshot()
        s.quotas = [quota(.codex, 17, minutes: 300), quota(.codex, 3, minutes: 10080)]
        s.liveQuotas = [quota(.claudeCode, 86, minutes: 300, source: .officialAPI),
                        quota(.claudeCode, 9, minutes: 10080, source: .officialAPI)]
        return s
    }

    @Test("默认显示最紧张的一条")
    func tightestAcrossProviders() {
        let q = snapshot().quota(target: .tightest, window: .tightest)
        #expect(q?.provider == .claudeCode)
        #expect(q?.usedPercent == 86)
    }

    /// 用户盯着某一家干活时，固定显示那家。
    @Test("可以固定显示某一家")
    func pinnedProvider() {
        let q = snapshot().quota(target: .provider(.codex), window: .tightest)
        #expect(q?.provider == .codex)
        #expect(q?.usedPercent == 17)
    }

    @Test("可以指定长短窗口")
    func windowSelection() {
        let s = snapshot()
        #expect(s.quota(target: .provider(.claudeCode), window: .shortest)?.windowMinutes == 300)
        #expect(s.quota(target: .provider(.claudeCode), window: .longest)?.windowMinutes == 10080)
        #expect(s.quota(target: .provider(.claudeCode), window: .longest)?.usedPercent == 9)
    }

    /// 选了一家没有额度来源的，不能瞎编，返回 nil 让 UI 退回显示 token。
    @Test("没有额度来源的一家返回 nil")
    func providerWithoutQuota() {
        #expect(snapshot().quota(target: .provider(.grok), window: .tightest) == nil)
    }

    @Test("MenuBarTarget 能往返编码")
    func targetRoundTrip() {
        for t in MenuBarTarget.allCases {
            #expect(MenuBarTarget(rawValue: t.rawValue) == t)
        }
        #expect(MenuBarTarget(rawValue: "不存在") == nil)
    }

    @Test("菜单栏紧凑格式")
    func compactFormatting() {
        #expect(Fmt.compactWindow(300) == "5h")
        #expect(Fmt.compactWindow(10080) == "7d")
        #expect(Fmt.compactWindow(43200) == "30d")
        #expect(Fmt.compactDuration(86400 * 6 + 3600 * 21) == "6d21h")
        #expect(Fmt.compactDuration(3600 * 3 + 60 * 12) == "3h12m")
        #expect(Fmt.compactDuration(45 * 60) == "45m")
        #expect(Fmt.compactDuration(-5) == "1m", "已过期不显示负数")
    }

    /// 图标报警必须跟着**当前显示的那条**走。
    /// 显示 A 却按 B 的水位变红，用户会以为 A 出了问题。
    @Test("告警等级跟随所显示的额度")
    func alertFollowsDisplayedQuota() {
        let s = snapshot()
        let t = Thresholds(warn: 80, critical: 95)
        let claude = s.quota(target: .provider(.claudeCode), window: .tightest)!
        let codex = s.quota(target: .provider(.codex), window: .tightest)!
        #expect(t.level(for: claude.usedPercent) == .warning)
        #expect(t.level(for: codex.usedPercent) == .normal)
    }
}
