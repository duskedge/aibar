import Foundation

/// 时间范围。UI 只传这个枚举，具体日期边界由它自己算，
/// 免得"今天"的定义散落在好几处。
public enum DateRange: Sendable, Hashable, CaseIterable {
    case today, week, month, quarter, all

    public static var allCases: [DateRange] { [.today, .week, .month, .quarter, .all] }

    public var label: String {
        switch self {
        case .today: "今日"
        case .week: "7 天"
        case .month: "30 天"
        case .quarter: "90 天"
        case .all: "全部"
        }
    }

    /// 起点。nil 表示不限。
    public var since: Date? {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: .now)
        return switch self {
        case .today: todayStart
        case .week: cal.date(byAdding: .day, value: -6, to: todayStart)
        case .month: cal.date(byAdding: .day, value: -29, to: todayStart)
        case .quarter: cal.date(byAdding: .day, value: -89, to: todayStart)
        case .all: nil
        }
    }

    /// 图表要画多少天。全部时间按实际跨度算，由调用方补。
    public var dayCount: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
    }

    public var filter: Reports.Filter { Reports.Filter(since: since) }
}

/// 仪表盘一次渲染需要的全部数据。和 Snapshot 一样是 Sendable 值类型。
public struct DashboardData: Sendable {
    public var range: DateRange = .week
    public var totals = Reports.Totals()
    public var previousTotals = Reports.Totals()
    /// 上一区间是否可比。
    ///
    /// 数据只覆盖到某天，再往前推一个区间就是空白，
    /// 这时算出来的"▲5728%"没有意义 —— 宁可不显示，也不给一个假的增长率。
    public var hasComparison = false
    public var series: [Snapshot.DayPoint] = []
    public var byProvider: [Reports.Bucket] = []
    public var byModel: [Reports.Bucket] = []
    public var byProject: [Reports.Bucket] = []
    public var byBranch: [Reports.Bucket] = []
    public var unpricedModels: [String] = []
    public var unpricedTokens = 0
    public init() {}
}

/// 会话明细表的一行。
public struct SessionDetail: Sendable, Identifiable, Hashable {
    public let id: String
    public let sessionId: String
    public let provider: Provider
    public let project: String
    public let projectPath: String?
    public let branch: String?
    public let model: String
    public let started: Date
    public let ended: Date
    public let tokens: Int
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let reasoning: Int
    public let cost: Double?
    public let turns: Int

    /// 会话跨度。单轮会话为 0，UI 要按"—"显示而不是"0 秒"。
    public var duration: TimeInterval { ended.timeIntervalSince(started) }

    public var cacheHitRate: Double {
        let denom = input + cacheRead + cacheWrite
        return denom > 0 ? Double(cacheRead) / Double(denom) : 0
    }

    public init(id: String, sessionId: String, provider: Provider, project: String,
                projectPath: String?, branch: String?, model: String,
                started: Date, ended: Date, tokens: Int, input: Int, output: Int,
                cacheRead: Int, cacheWrite: Int, reasoning: Int, cost: Double?, turns: Int) {
        self.id = id; self.sessionId = sessionId; self.provider = provider
        self.project = project; self.projectPath = projectPath; self.branch = branch
        self.model = model; self.started = started; self.ended = ended
        self.tokens = tokens; self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.reasoning = reasoning; self.cost = cost; self.turns = turns
    }
}

/// 会话内的一轮。展开某个会话时画的曲线。
public struct TurnPoint: Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let tokens: Int
    public let cost: Double?
    public let model: String
    public init(id: String, timestamp: Date, tokens: Int, cost: Double?, model: String) {
        self.id = id; self.timestamp = timestamp; self.tokens = tokens
        self.cost = cost; self.model = model
    }
}
