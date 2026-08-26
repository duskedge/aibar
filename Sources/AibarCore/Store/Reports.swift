import Foundation

/// 聚合查询。成本在 SQL 里算完再回 Swift，避免把上百万行拉进内存。
public struct Reports {
    public let store: UsageStore
    public let pricing: PricingTable

    public init(store: UsageStore, pricing: PricingTable = .builtin) {
        self.store = store
        self.pricing = pricing
    }

    public struct Bucket: Sendable {
        public var key: String
        public var tokens: Int
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int
        public var cost: Double?
        public var sessions: Int
        public var events: Int
    }

    public enum Dimension: String, CaseIterable, Sendable {
        case provider, model, project, day, branch

        var sqlKey: String {
            switch self {
            case .provider: "provider"
            case .model: "model"
            // 只取路径最后一段作为项目名，和面板展示保持一致
            case .project: "COALESCE(NULLIF(replace(project_path, rtrim(project_path, replace(project_path, '/', '')), ''), ''), project_path, '(未知)')"
            case .day: "date(ts, 'unixepoch', 'localtime')"
            case .branch: "COALESCE(git_branch, '(无)')"
            }
        }
    }

    public struct Filter: Sendable {
        public var since: Date?
        public var until: Date?
        public var providers: [Provider]?
        public init(since: Date? = nil, until: Date? = nil, providers: [Provider]? = nil) {
            self.since = since; self.until = until; self.providers = providers
        }

        var whereClause: (String, [Database.Value]) {
            var parts: [String] = []
            var binds: [Database.Value] = []
            if let since { parts.append("ts >= ?"); binds.append(.int(Int(since.timeIntervalSince1970))) }
            if let until { parts.append("ts < ?"); binds.append(.int(Int(until.timeIntervalSince1970))) }
            if let providers, !providers.isEmpty {
                parts.append("provider IN (\(providers.map { _ in "?" }.joined(separator: ",")))")
                binds.append(contentsOf: providers.map { .text($0.rawValue) })
            }
            return (parts.isEmpty ? "1=1" : parts.joined(separator: " AND "), binds)
        }
    }

    public func breakdown(by dim: Dimension, filter: Filter = Filter()) throws -> [Bucket] {
        let (whereSQL, binds) = filter.whereClause
        let cost = pricing.sqlCostExpression()
        var out: [Bucket] = []
        try store.db.query("""
            SELECT \(dim.sqlKey) AS k,
                   SUM(input_tokens + output_tokens + cache_read_tokens
                       + cache_write_5m_tokens + cache_write_1h_tokens),
                   SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens),
                   SUM(cache_write_5m_tokens + cache_write_1h_tokens),
                   SUM(\(cost)),
                   COUNT(DISTINCT session_id), COUNT(*)
            FROM usage_events
            WHERE \(whereSQL)
            GROUP BY k
            ORDER BY 2 DESC
            """, binds) { r in
            out.append(Bucket(key: r.text(0) ?? "(未知)", tokens: r.int(1),
                              input: r.int(2), output: r.int(3),
                              cacheRead: r.int(4), cacheWrite: r.int(5),
                              cost: r.doubleOrNil(6), sessions: r.int(7), events: r.int(8)))
        }
        return out
    }

    public struct Totals: Sendable {
        public var tokens = 0, input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        public var cost: Double = 0
        public var sessions = 0, events = 0
        public init() {}
        init(tokens: Int, input: Int, output: Int, cacheRead: Int, cacheWrite: Int,
             cost: Double, sessions: Int, events: Int) {
            self.tokens = tokens; self.input = input; self.output = output
            self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
            self.cost = cost; self.sessions = sessions; self.events = events
        }
        public var cacheHitRate: Double {
            let denom = input + cacheRead + cacheWrite
            return denom > 0 ? Double(cacheRead) / Double(denom) : 0
        }
    }

    /// 缺少定价的事件数与 token 数 —— 总成本旁必须能说明“这部分没算进去”。
    public func unpricedVolume(filter: Filter = Filter()) throws -> (events: Int, tokens: Int) {
        let (whereSQL, binds) = filter.whereClause
        var out = (events: 0, tokens: 0)
        try store.db.query("""
            SELECT COUNT(*), COALESCE(SUM(input_tokens + output_tokens + cache_read_tokens
                   + cache_write_5m_tokens + cache_write_1h_tokens), 0)
            FROM usage_events
            WHERE \(whereSQL) AND (\(pricing.sqlCostExpression())) IS NULL
            """, binds) { r in out = (r.int(0), r.int(1)) }
        return out
    }

    public func totals(filter: Filter = Filter()) throws -> Totals {
        let (whereSQL, binds) = filter.whereClause
        var t = Totals()
        try store.db.query("""
            SELECT SUM(input_tokens + output_tokens + cache_read_tokens
                       + cache_write_5m_tokens + cache_write_1h_tokens),
                   SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens),
                   SUM(cache_write_5m_tokens + cache_write_1h_tokens),
                   SUM(\(pricing.sqlCostExpression())),
                   COUNT(DISTINCT session_id), COUNT(*)
            FROM usage_events WHERE \(whereSQL)
            """, binds) { r in
            t = Totals(tokens: r.int(0), input: r.int(1), output: r.int(2),
                       cacheRead: r.int(3), cacheWrite: r.int(4), cost: r.doubleOrNil(5) ?? 0,
                       sessions: r.int(6), events: r.int(7))
        }
        return t
    }

    /// 库里最早一条事件的时间。用来判断某个对比区间是否真的有数据覆盖。
    public func earliestEvent() throws -> Date? {
        var out: Date?
        try store.db.query("SELECT MIN(ts) FROM usage_events") { r in
            if r.int(0) > 0 { out = Date(timeIntervalSince1970: Double(r.int(0))) }
        }
        return out
    }

    /// 库里出现过的所有模型，用来检查价格表覆盖情况。
    public func models() throws -> [String] {
        var out: [String] = []
        try store.db.query("SELECT DISTINCT model FROM usage_events") { r in
            if let m = r.text(0) { out.append(m) }
        }
        return out
    }

    public func latestQuota() throws -> [QuotaStatus] {
        var out: [QuotaStatus] = []
        // 每个 (provider, 窗口) 各取最新一条 —— 5 小时和 7 天是两件事，不能合并
        try store.db.query("""
            SELECT provider, window_minutes, MAX(observed_at), used_percent,
                   resets_at, plan_type, source, window_label
            FROM quota_snapshots_v2
            GROUP BY provider, window_minutes
            ORDER BY provider, window_minutes
            """) { r in
            guard let p = r.text(0).flatMap(Provider.init(rawValue:)) else { return }
            out.append(QuotaStatus(
                provider: p, usedPercent: r.double(3), windowMinutes: r.int(1),
                resetsAt: r.int(4) > 0 ? Date(timeIntervalSince1970: Double(r.int(4))) : nil,
                planType: r.text(5),
                observedAt: Date(timeIntervalSince1970: Double(r.int(2))),
                source: QuotaStatus.Source(rawValue: r.text(6) ?? "") ?? .localLog,
                windowLabel: r.text(7)))
        }
        return out
    }

    /// 最近活跃的会话。
    ///
    /// 关键在于先用一个 CTE 把范围收窄到最近 N 个会话，再做"该会话哪个模型 token 最多"
    /// 这种昂贵聚合。早期版本把关联子查询直接挂在外层，592 个会话各跑一次全表聚合，
    /// 实测占掉 43% 的 CPU。
    public func recentSessions(limit: Int = 8, filter: Filter = Filter()) throws -> [Snapshot.SessionRow] {
        let (whereSQL, binds) = filter.whereClause
        let cost = pricing.sqlCostExpression()
        let tokenSum = """
            input_tokens + output_tokens + cache_read_tokens
            + cache_write_5m_tokens + cache_write_1h_tokens
            """
        var out: [Snapshot.SessionRow] = []
        try store.db.query("""
            WITH recent AS (
                SELECT session_id, provider, MAX(ts) AS last_ts
                FROM usage_events
                WHERE \(whereSQL)
                GROUP BY session_id, provider
                ORDER BY last_ts DESC
                LIMIT \(limit)
            )
            SELECT r.session_id, r.provider, r.last_ts,
                   COALESCE(MAX(e.project_path), ''),
                   SUM(\(tokenSum)),
                   SUM(\(cost)),
                   (SELECT model FROM usage_events m
                     WHERE m.session_id = r.session_id AND m.provider = r.provider
                     GROUP BY model ORDER BY SUM(\(tokenSum)) DESC LIMIT 1)
            FROM recent r
            JOIN usage_events e
              ON e.session_id = r.session_id AND e.provider = r.provider
            GROUP BY r.session_id, r.provider
            ORDER BY r.last_ts DESC
            """, binds) { r in
            guard let p = r.text(1).flatMap(Provider.init(rawValue:)) else { return }
            let path = r.text(3) ?? ""
            out.append(Snapshot.SessionRow(
                id: "\(p.rawValue)-\(r.text(0) ?? "")",
                provider: p,
                project: path.isEmpty ? "(未知)" : URL(fileURLWithPath: path).lastPathComponent,
                model: r.text(6) ?? "—",
                tokens: r.int(4), cost: r.doubleOrNil(5),
                lastActive: Date(timeIntervalSince1970: Double(r.int(2)))))
        }
        return out
    }

    /// 按天的堆叠序列。空缺的日期补零，图表才不会把两天挤在一起。
    public func dailySeries(days: Int = 14) throws -> [Snapshot.DayPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        guard let from = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        return try dailySeries(from: from, days: days)
    }

    /// 全部时间用这个：起点取库里最早一条，天数由跨度决定，上限防止图表点数爆炸。
    public func dailySeriesAll(maxDays: Int = 180) throws -> [Snapshot.DayPoint] {
        var earliest: Date?
        try store.db.query("SELECT MIN(ts) FROM usage_events") { r in
            if r.int(0) > 0 { earliest = Date(timeIntervalSince1970: Double(r.int(0))) }
        }
        guard let earliest else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: earliest)
        let span = (cal.dateComponents([.day], from: start, to: .now).day ?? 0) + 1
        let days = min(maxDays, max(1, span))
        guard let from = cal.date(byAdding: .day, value: -(days - 1),
                                  to: cal.startOfDay(for: .now)) else { return [] }
        return try dailySeries(from: from, days: days)
    }

    private func dailySeries(from: Date, days: Int) throws -> [Snapshot.DayPoint] {
        let cal = Calendar.current

        var table: [Date: [Provider: Int]] = [:]
        try store.db.query("""
            SELECT date(ts, 'unixepoch', 'localtime'), provider,
                   SUM(input_tokens + output_tokens + cache_read_tokens
                       + cache_write_5m_tokens + cache_write_1h_tokens)
            FROM usage_events WHERE ts >= ?
            GROUP BY 1, 2
            """, [.int(Int(from.timeIntervalSince1970))]) { r in
            guard let dayString = r.text(0),
                  let p = r.text(1).flatMap(Provider.init(rawValue:)),
                  let day = Self.dayFormatter.date(from: dayString) else { return }
            table[day, default: [:]][p] = r.int(2)
        }

        return (0..<days).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: from) else { return nil }
            return Snapshot.DayPoint(day: d, byProvider: table[cal.startOfDay(for: d)] ?? [:])
        }
    }

    // MARK: - 仪表盘

    /// 组装仪表盘一次渲染所需的全部数据。
    /// 和 snapshot() 一样，一次查完交出去，UI 侧不再碰数据库。
    public func dashboard(range: DateRange) throws -> DashboardData {
        var d = DashboardData()
        d.range = range
        d.totals = try totals(filter: range.filter)

        // 环比：取等长的上一个区间。
        // 只有当库里的数据真的覆盖到那个区间时才算 —— 否则拿有数据的一段去比空白，
        // 会得出"▲5728%"这种没有信息量的数字。
        if let since = range.since, let days = range.dayCount,
           let prevStart = Calendar.current.date(byAdding: .day, value: -days, to: since),
           let earliest = try earliestEvent(), earliest <= prevStart {
            d.previousTotals = try totals(filter: Filter(since: prevStart, until: since))
            d.hasComparison = true
        }

        d.series = try range == .all
            ? dailySeriesAll()
            : dailySeries(days: max(1, range.dayCount ?? 7))

        d.byProvider = try breakdown(by: .provider, filter: range.filter)
        d.byModel = try breakdown(by: .model, filter: range.filter)
        d.byProject = try breakdown(by: .project, filter: range.filter)
        d.byBranch = try breakdown(by: .branch, filter: range.filter)

        d.unpricedModels = pricing.unpricedModels(in: try models())
        if !d.unpricedModels.isEmpty {
            d.unpricedTokens = try unpricedVolume(filter: range.filter).tokens
        }
        return d
    }

    // MARK: - 会话明细

    /// 会话明细表。
    ///
    /// 和 recentSessions 一样的教训：昂贵聚合前先把范围收窄。
    /// 这里 LIMIT 在 CTE 里，代表模型的子查询只对最终这几行跑。
    public func sessions(range: DateRange = .week, provider: Provider? = nil,
                         search: String? = nil, limit: Int = 200) throws -> [SessionDetail] {
        var filter = range.filter
        if let provider { filter.providers = [provider] }
        let (whereSQL, binds) = filter.whereClause

        var extra = ""
        var allBinds = binds
        if let search, !search.isEmpty {
            extra = " AND (project_path LIKE ? OR model LIKE ? OR session_id LIKE ?)"
            let like = "%\(search)%"
            allBinds += [.text(like), .text(like), .text(like)]
        }

        let tokenSum = """
            input_tokens + output_tokens + cache_read_tokens
            + cache_write_5m_tokens + cache_write_1h_tokens
            """
        var out: [SessionDetail] = []
        try store.db.query("""
            WITH picked AS (
                SELECT session_id, provider, MAX(ts) AS last_ts
                FROM usage_events
                WHERE \(whereSQL)\(extra)
                GROUP BY session_id, provider
                ORDER BY last_ts DESC
                LIMIT \(limit)
            )
            SELECT p.session_id, p.provider, MIN(e.ts), MAX(e.ts),
                   COALESCE(MAX(e.project_path), ''), MAX(e.git_branch),
                   SUM(\(tokenSum)),
                   SUM(e.input_tokens), SUM(e.output_tokens), SUM(e.cache_read_tokens),
                   SUM(e.cache_write_5m_tokens + e.cache_write_1h_tokens),
                   SUM(e.reasoning_tokens),
                   SUM(\(pricing.sqlCostExpression())),
                   COUNT(*),
                   (SELECT model FROM usage_events m
                     WHERE m.session_id = p.session_id AND m.provider = p.provider
                     GROUP BY model ORDER BY SUM(\(tokenSum)) DESC LIMIT 1)
            FROM picked p
            JOIN usage_events e ON e.session_id = p.session_id AND e.provider = p.provider
            GROUP BY p.session_id, p.provider
            ORDER BY p.last_ts DESC
            """, allBinds) { r in
            guard let prov = r.text(1).flatMap(Provider.init(rawValue:)) else { return }
            let path = r.text(4) ?? ""
            out.append(SessionDetail(
                id: "\(prov.rawValue)-\(r.text(0) ?? "")",
                sessionId: r.text(0) ?? "",
                provider: prov,
                project: path.isEmpty ? "(未知)" : URL(fileURLWithPath: path).lastPathComponent,
                projectPath: path.isEmpty ? nil : path,
                branch: r.text(5),
                model: r.text(14) ?? "—",
                started: Date(timeIntervalSince1970: Double(r.int(2))),
                ended: Date(timeIntervalSince1970: Double(r.int(3))),
                tokens: r.int(6), input: r.int(7), output: r.int(8),
                cacheRead: r.int(9), cacheWrite: r.int(10), reasoning: r.int(11),
                cost: r.doubleOrNil(12), turns: r.int(13)))
        }
        return out
    }

    /// 单个会话的逐轮曲线。
    public func timeline(sessionId: String, provider: Provider) throws -> [TurnPoint] {
        var out: [TurnPoint] = []
        try store.db.query("""
            SELECT id, ts, input_tokens + output_tokens + cache_read_tokens
                   + cache_write_5m_tokens + cache_write_1h_tokens,
                   \(pricing.sqlCostExpression()), model
            FROM usage_events
            WHERE session_id = ? AND provider = ?
            ORDER BY ts
            """, [.text(sessionId), .text(provider.rawValue)]) { r in
            out.append(TurnPoint(id: r.text(0) ?? UUID().uuidString,
                                 timestamp: Date(timeIntervalSince1970: Double(r.int(1))),
                                 tokens: r.int(2), cost: r.doubleOrNil(3),
                                 model: r.text(4) ?? "—"))
        }
        return out
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    /// 一次性组装面板所需的全部数据。面板打开时不做任何解析，只读这里。
    public func snapshot() throws -> Snapshot {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: .now)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart

        var s = Snapshot()
        s.today = try totals(filter: Filter(since: todayStart))
        s.yesterday = try totals(filter: Filter(since: yesterdayStart, until: todayStart))

        // 三家都要出现，当天没用量的显示为零而不是消失 —— 空态可见，用户才知道数据是全的
        let buckets = try breakdown(by: .provider, filter: Filter(since: todayStart))
        let indexed = Dictionary(uniqueKeysWithValues: buckets.compactMap { b in
            Provider(rawValue: b.key).map { ($0, b) }
        })
        s.todayByProvider = Provider.allCases.map { p in
            let b = indexed[p]
            return Snapshot.ProviderStat(provider: p, tokens: b?.tokens ?? 0,
                                         cost: b?.cost, sessions: b?.sessions ?? 0)
        }

        s.quotas = try latestQuota()
        s.recentSessions = try recentSessions(limit: 5)
        s.rateLimits = try rateLimits(filter: Filter(since: cal.date(byAdding: .day, value: -7, to: .now)))
        s.dailySeries = try dailySeries(days: 14)
        s.unpricedModels = pricing.unpricedModels(in: try models())
        if !s.unpricedModels.isEmpty {
            s.unpricedTokens = try unpricedVolume().tokens
        }
        return s
    }

    public struct RateLimitSummary: Sendable {
        public var count: Int
        public var last: Date?
        public var messages: [String]
        public init(count: Int, last: Date?, messages: [String]) {
            self.count = count; self.last = last; self.messages = messages
        }
    }

    public func rateLimits(filter: Filter = Filter()) throws -> RateLimitSummary {
        let (whereSQL, binds) = filter.whereClause
        var s = RateLimitSummary(count: 0, last: nil, messages: [])
        try store.db.query("""
            SELECT COUNT(*), MAX(ts) FROM rate_limit_events WHERE \(whereSQL)
            """, binds) { r in
            s.count = r.int(0)
            if r.int(1) > 0 { s.last = Date(timeIntervalSince1970: Double(r.int(1))) }
        }
        try store.db.query("""
            SELECT message FROM rate_limit_events WHERE \(whereSQL) ORDER BY ts DESC LIMIT 3
            """, binds) { r in
            if let m = r.text(0) { s.messages.append(m) }
        }
        return s
    }
}
