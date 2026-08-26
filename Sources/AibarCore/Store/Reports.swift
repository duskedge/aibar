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
        try store.db.query("""
            SELECT provider, MAX(observed_at), used_percent, window_minutes,
                   resets_at, plan_type, source
            FROM quota_snapshots GROUP BY provider
            """) { r in
            guard let p = r.text(0).flatMap(Provider.init(rawValue:)) else { return }
            out.append(QuotaStatus(
                provider: p, usedPercent: r.double(2), windowMinutes: r.int(3),
                resetsAt: r.int(4) > 0 ? Date(timeIntervalSince1970: Double(r.int(4))) : nil,
                planType: r.text(5),
                observedAt: Date(timeIntervalSince1970: Double(r.int(1))),
                source: QuotaStatus.Source(rawValue: r.text(6) ?? "") ?? .localLog))
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
