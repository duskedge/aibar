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
    /// 用户自设预算的进度。与官方额度分开，界面上不能混为一谈。
    public var budgets: [BudgetProgress] = []

    public func budget(for provider: Provider) -> BudgetProgress? {
        budgets.first { $0.provider == provider }
    }
    public var offlineMode = false

    /// 某一家的全部额度条目，本地与接口合并后按窗口升序。
    public func quotas(for provider: Provider) -> [QuotaStatus] {
        (quotas + liveQuotas)
            .filter { $0.provider == provider }
            .sorted { $0.windowMinutes < $1.windowMinutes }
    }

    public var allQuotas: [QuotaStatus] { quotas + liveQuotas }

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
        return windowMinutes >= 1440 ? "\(windowMinutes / 1440) 天窗口" : "\(windowMinutes / 60) 小时窗口"
    }

    /// 这条额度还有多新。日志型额度只在用户跑对话时才更新，
    /// 太旧的必须让用户看见，不能装作实时。
    public func isStale(now: Date = .now, tolerance: TimeInterval = 3600) -> Bool {
        now.timeIntervalSince(observedAt) > tolerance
    }
}
