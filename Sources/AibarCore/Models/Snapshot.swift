import Foundation

/// 面板一次渲染需要的全部数据。
///
/// 刻意做成一个 Sendable 值类型：解析和查询都在 actor 里跑完，
/// 只把这个结构体交给 MainActor，UI 侧不碰数据库、不做聚合。
public struct Snapshot: Sendable {
    public var generatedAt: Date = .now
    public var today = Reports.Totals()
    public var yesterday = Reports.Totals()
    public var todayByProvider: [ProviderStat] = []
    /// 本地日志得来的额度（目前只有 Codex）。
    public var quotas: [QuotaStatus] = []
    /// L2 官方接口得来的额度。
    public var liveQuotas: [QuotaStatus] = []
    /// L2 失败原因。UI 要显示"未连接 + 为什么"，不能只留个空环。
    public var quotaFailures: [Provider: String] = [:]
    public var liveFetchedAt: Date?
    /// 额度接口 429 静默期结束时刻。
    public var quotaBackoffUntil: Date?
    /// 用户自设预算的进度。与官方额度分开，界面上不能混为一谈。
    public var budgets: [BudgetProgress] = []

    public func budget(for provider: Provider) -> BudgetProgress? {
        budgets.first { $0.provider == provider }
    }
    public var offlineMode = false

    /// 某一家的全部额度条目，本地与接口合并后按窗口升序。
    ///
    /// 同一窗口只留一条，取 observedAt 更新的那条。
    ///
    /// 接口结果的 observedAt 是抓取时刻，天然比日志里的时间戳新，所以不必
    /// 额外给来源排优先级。这样 429 时 SQLite 里上次成功的结果还能撑着环，
    /// 不会和内存缓存叠出两圈。
    public func quotas(for provider: Provider) -> [QuotaStatus] {
        Self.merged(quotas + liveQuotas)
            .filter { $0.provider == provider }
            .sorted { $0.windowMinutes < $1.windowMinutes }
    }

    public var allQuotas: [QuotaStatus] { Self.merged(quotas + liveQuotas) }

    public var isQuotaBackingOff: Bool {
        quotaBackoffUntil.map { Date.now < $0 } ?? false
    }

    public var timeUntilQuotaRetry: TimeInterval? {
        guard let until = quotaBackoffUntil else { return nil }
        let t = until.timeIntervalSinceNow
        return t > 0 ? t : nil
    }

    static func merged(_ rows: [QuotaStatus], now: Date = .now) -> [QuotaStatus] {
        var byKey: [String: QuotaStatus] = [:]
        for q in rows {
            let key = "\(q.provider.rawValue)-\(q.windowMinutes)"
            if let existing = byKey[key] {
                // 同一窗口留更新的那条。来源相同或官方接口覆盖本地，都看 observedAt。
                if q.observedAt >= existing.observedAt { byKey[key] = q }
            } else {
                byKey[key] = q
            }
        }
        // 先挑最新观测，再按重置时刻归零。反过来会把一条过期的 12%
        // 和一条未过期的 5% 比错，也可能用过期行盖住更新的行。
        return Array(byKey.values.map { $0.resolved(now: now) })
    }

    /// 最紧张的一条 —— 菜单栏默认用它。
    public var tightestQuota: QuotaStatus? {
        allQuotas.max { $0.usedPercent < $1.usedPercent }
    }

    /// 按用户在设置里选的目标与窗口挑一条。
    public func quota(target: MenuBarTarget, window: MenuBarWindow) -> QuotaStatus? {
        let pool: [QuotaStatus] = switch target {
        case .tightest: allQuotas
        case .provider(let p): allQuotas.filter { $0.provider == p }
        }
        guard !pool.isEmpty else { return nil }
        return switch window {
        case .tightest: pool.max { $0.usedPercent < $1.usedPercent }
        case .shortest: pool.min { $0.windowMinutes < $1.windowMinutes }
        case .longest: pool.max { $0.windowMinutes < $1.windowMinutes }
        }
    }
    public var recentSessions: [SessionRow] = []
    public var rateLimits = Reports.RateLimitSummary(count: 0, last: nil, messages: [])
    public var dailySeries: [DayPoint] = []
    public var unpricedModels: [String] = []
    public var unpricedTokens: Int = 0
    public var isEmpty: Bool { today.events == 0 && dailySeries.allSatisfy { $0.total == 0 } }

    public init() {}

    public struct ProviderStat: Sendable, Identifiable {
        public let provider: Provider
        public let tokens: Int
        public let cost: Double?
        public let sessions: Int
        public var id: Provider { provider }
        public init(provider: Provider, tokens: Int, cost: Double?, sessions: Int) {
            self.provider = provider; self.tokens = tokens
            self.cost = cost; self.sessions = sessions
        }
    }

    public struct SessionRow: Sendable, Identifiable {
        public let id: String
        public let provider: Provider
        public let project: String
        public let model: String
        public let tokens: Int
        public let cost: Double?
        public let lastActive: Date
        public init(id: String, provider: Provider, project: String, model: String,
                    tokens: Int, cost: Double?, lastActive: Date) {
            self.id = id; self.provider = provider; self.project = project
            self.model = model; self.tokens = tokens; self.cost = cost; self.lastActive = lastActive
        }
    }

    public struct DayPoint: Sendable, Identifiable {
        public let day: Date
        public let byProvider: [Provider: Int]
        public var id: Date { day }
        public var total: Int { byProvider.values.reduce(0, +) }
        public init(day: Date, byProvider: [Provider: Int]) {
            self.day = day; self.byProvider = byProvider
        }
    }
}

extension QuotaStatus {
    /// 剩余时间。为 nil 表示日志里没给重置时刻。
    public var timeUntilReset: TimeInterval? {
        resetsAt.map { $0.timeIntervalSinceNow }
    }

    public var windowDescription: String {
        if let windowLabel { return windowLabel }
        return windowMinutes >= 1440
            ? L("%lld 天窗口", windowMinutes / 1440)
            : L("%lld 小时窗口", windowMinutes / 60)
    }

    /// 这条额度还有多新。日志型额度只在用户跑对话时才更新，
    /// 太旧的必须让用户看见，不能装作实时。
    public func isStale(now: Date = .now, tolerance: TimeInterval = 3600) -> Bool {
        now.timeIntervalSince(observedAt) > tolerance
    }

    /// 官方重置时刻已经过去。本地日志不会在空闲时补一条 0%，
    /// 必须在这里把过期窗口归零，否则会一直显示重置前的百分比。
    public func hasExpired(now: Date = .now) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// 展示 / 比较用的已用百分比：窗口已过后视为 0。
    public func effectiveUsedPercent(now: Date = .now) -> Double {
        hasExpired(now: now) ? 0 : usedPercent
    }

    /// 重置文案。已过期写「已重置」，绝不能把负数剩时格式化成「1 分钟后」。
    public func resetCaption(now: Date = .now) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining > 0 { return L("%@后重置", Fmt.duration(remaining)) }
        return L("已重置")
    }

    /// 窗口已过则把 usedPercent 归零。resetsAt 原样保留，方便 UI 判断「已重置」。
    public func resolved(now: Date = .now) -> QuotaStatus {
        guard hasExpired(now: now), usedPercent != 0 else { return self }
        return QuotaStatus(
            provider: provider, usedPercent: 0, windowMinutes: windowMinutes,
            resetsAt: resetsAt, planType: planType, observedAt: observedAt,
            source: source, windowLabel: windowLabel)
    }
}
