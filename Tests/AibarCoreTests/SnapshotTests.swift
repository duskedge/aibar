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

    @Test("关掉的 provider 不进快照合计与列表")
    func disabledProviderHidden() throws {
        let s = try store([
            event(.claudeCode, "claude-opus-5", tokens: 1000, id: "c"),
            event(.codex, "gpt-5.6", tokens: 2000, id: "x"),
            event(.grok, "grok-4.6", tokens: 3000, id: "g"),
        ])
        let snap = try Reports(store: s).snapshot(providers: [.claudeCode])
        #expect(snap.enabledProviders == [.claudeCode])
        #expect(snap.todayByProvider.map(\.provider) == [.claudeCode])
        #expect(snap.today.tokens == 1000)
        #expect(snap.recentSessions.allSatisfy { $0.provider == .claudeCode })
        #expect(snap.dailySeries.allSatisfy { ($0.byProvider[.codex] ?? 0) == 0 })
        #expect(snap.dailySeries.allSatisfy { ($0.byProvider[.grok] ?? 0) == 0 })
    }

    @Test("关掉全部时快照为空，库里的数也不展示")
    func allProvidersDisabled() throws {
        let s = try store([event(.claudeCode, "claude-opus-5", tokens: 1000)])
        let snap = try Reports(store: s).snapshot(providers: [])
        #expect(snap.isEmpty)
        #expect(snap.todayByProvider.isEmpty)
        #expect(snap.today.tokens == 0)
        #expect(snap.enabledProviders.isEmpty)
    }

    @Test("扫描跳过未启用的 provider")
    func scanSkipsDisabled() throws {
        let s = try UsageStore(path: ":memory:")
        let summary = try Scanner(store: s).scan(enabled: [])
        #expect(summary.filesScanned == 0)
        #expect(summary.eventsInserted == 0)
        #expect(summary.filesSkipped == 0)
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

    /// Codex 额度只在跑对话时写入。5 小时窗口过了之后日志不会补一条 0%，
    /// 必须把百分比归零，并显示「已重置」而不是「1 分钟后重置」。
    @Test("窗口已过的额度归零，不把过期剩时说成 1 分钟")
    func expiredQuotaResetsToZero() {
        let now = Date()
        let five = QuotaStatus(provider: .codex, usedPercent: 12, windowMinutes: 300,
                               resetsAt: now.addingTimeInterval(-13 * 3600), planType: "plus",
                               observedAt: now.addingTimeInterval(-15 * 3600), source: .localLog)
        let week = QuotaStatus(provider: .codex, usedPercent: 5, windowMinutes: 10080,
                               resetsAt: now.addingTimeInterval(6 * 86400), planType: "plus",
                               observedAt: now.addingTimeInterval(-15 * 3600), source: .localLog)
        #expect(five.hasExpired(now: now))
        #expect(!week.hasExpired(now: now))
        #expect(five.effectiveUsedPercent(now: now) == 0)
        #expect(week.effectiveUsedPercent(now: now) == 5)
        #expect(five.resetCaption(now: now) == "已重置")
        #expect(five.resolved(now: now).usedPercent == 0)
        #expect(week.resolved(now: now).usedPercent == 5)

        var s = Snapshot()
        s.quotas = [five, week]
        let rows = s.quotas(for: .codex)
        #expect(rows.first { $0.windowMinutes == 300 }?.usedPercent == 0)
        #expect(rows.first { $0.windowMinutes == 10080 }?.usedPercent == 5)
        #expect(s.tightestQuota?.windowMinutes == 10080)
        #expect(s.tightestQuota?.usedPercent == 5)
    }

    @Test("latestQuota 取每个窗口最新一条，过期窗口归零")
    func latestQuotaPicksNewestThenResolves() throws {
        let s = try UsageStore(path: ":memory:")
        let old = QuotaStatus(provider: .codex, usedPercent: 40, windowMinutes: 300,
                              resetsAt: .now.addingTimeInterval(-7200), planType: "plus",
                              observedAt: .now.addingTimeInterval(-8000), source: .localLog)
        let newest = QuotaStatus(provider: .codex, usedPercent: 12, windowMinutes: 300,
                                 resetsAt: .now.addingTimeInterval(-100), planType: "plus",
                                 observedAt: .now.addingTimeInterval(-200), source: .localLog)
        try s.insert(quota: old)
        try s.insert(quota: newest)
        let rows = try Reports(store: s).latestQuota()
        let five = try #require(rows.first { $0.windowMinutes == 300 })
        #expect(five.usedPercent == 0, "12% 的窗口已经过期，应归零")
        // 库里只存整秒，不能拿带小数的 Date 直接比
        #expect(Int(five.observedAt.timeIntervalSince1970)
                == Int(newest.observedAt.timeIntervalSince1970))
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

    /// 最短 / 最长是相对的。有月度窗口时最长就不再是 7 天，
    /// 所以必须能直接钉住 5 小时或 7 天。
    @Test("可以固定显示 5 小时或 7 天窗口")
    func pinnedFiveHourAndSevenDay() {
        var s = snapshot()
        s.liveQuotas.append(QuotaStatus(
            provider: .claudeCode, usedPercent: 5, windowMinutes: 43200,
            resetsAt: nil, planType: "pro", observedAt: .now, source: .officialAPI))

        #expect(s.quota(target: .provider(.claudeCode), window: .fiveHour)?.windowMinutes == 300)
        #expect(s.quota(target: .provider(.claudeCode), window: .fiveHour)?.usedPercent == 86)
        #expect(s.quota(target: .provider(.claudeCode), window: .sevenDay)?.windowMinutes == 10080)
        #expect(s.quota(target: .provider(.claudeCode), window: .sevenDay)?.usedPercent == 9)
        #expect(s.quota(target: .provider(.claudeCode), window: .longest)?.windowMinutes == 43200)
        #expect(s.quota(target: .provider(.claudeCode), window: .shortest)?.windowMinutes == 300)

        let five = s.quota(target: .tightest, window: .fiveHour)
        #expect(five?.provider == .claudeCode)
        #expect(five?.windowMinutes == 300)

        let week = s.quota(target: .tightest, window: .sevenDay)
        #expect(week?.provider == .claudeCode)
        #expect(week?.usedPercent == 9)

        #expect(s.quota(target: .provider(.grok), window: .fiveHour) == nil)
    }

    @Test("MenuBarWindow 能往返编码")
    func windowRoundTrip() {
        for w in MenuBarWindow.allCases {
            #expect(MenuBarWindow(rawValue: w.rawValue) == w)
        }
        #expect(MenuBarWindow(rawValue: "不存在") == nil)
    }

    /// 选了一家没有额度来源的，不能瞎编，返回 nil 让 UI 退回显示 token。
    @Test("没有额度来源的一家返回 nil")
    func providerWithoutQuota() {
        #expect(snapshot().quota(target: .provider(.grok), window: .tightest) == nil)
    }

    @Test("同一窗口的本地缓存与接口结果合并，取更新的那条")
    func mergePrefersNewer() {
        var s = Snapshot()
        let older = Date().addingTimeInterval(-3600)
        s.quotas = [QuotaStatus(provider: .claudeCode, usedPercent: 50, windowMinutes: 300,
                                resetsAt: nil, planType: "pro", observedAt: older, source: .officialAPI)]
        s.liveQuotas = [QuotaStatus(provider: .claudeCode, usedPercent: 80, windowMinutes: 300,
                                    resetsAt: nil, planType: "pro", observedAt: .now, source: .officialAPI)]
        let rows = s.quotas(for: .claudeCode)
        #expect(rows.count == 1)
        #expect(rows[0].usedPercent == 80)
    }

    @Test("接口限流时仍能用本地留下的上次额度画环")
    func localFallbackWhenRateLimited() {
        var s = Snapshot()
        s.quotas = [QuotaStatus(provider: .claudeCode, usedPercent: 61, windowMinutes: 300,
                                resetsAt: .now.addingTimeInterval(3600), planType: "pro",
                                observedAt: Date().addingTimeInterval(-120), source: .officialAPI)]
        s.quotaFailures = [.claudeCode: "服务返回 429"]
        s.quotaBackoffUntil = Date().addingTimeInterval(180)
        #expect(s.quotas(for: .claudeCode).count == 1)
        #expect(s.quotas(for: .claudeCode)[0].usedPercent == 61)
        #expect(s.isQuotaBackingOff)
        #expect(s.timeUntilQuotaRetry ?? 0 > 100)
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
