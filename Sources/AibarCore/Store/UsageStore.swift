import Foundation

/// 用量库。去重完全交给数据库主键 —— Claude 有 41% 的重复行，
/// 靠应用层记忆去重迟早会在增量场景下漏掉，`INSERT OR IGNORE` 才是真兜底。
public final class UsageStore {
    public let db: Database

    public init(path: String) throws {
        db = try Database(path: path)
        try migrate()
    }

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/aibar/aibar.db").path
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS usage_events (
            id TEXT NOT NULL,
            provider TEXT NOT NULL,
            ts INTEGER NOT NULL,
            session_id TEXT NOT NULL,
            project_path TEXT,
            git_branch TEXT,
            model TEXT NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_5m_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_1h_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            official_cost_usd REAL,
            PRIMARY KEY (provider, id)
        );
        CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_events(ts);
        CREATE INDEX IF NOT EXISTS idx_usage_provider_ts ON usage_events(provider, ts);
        CREATE INDEX IF NOT EXISTS idx_usage_model ON usage_events(model);
        -- 会话维度查询（最近会话、按会话聚合）必须走索引，否则每个会话都是一次全表扫
        CREATE INDEX IF NOT EXISTS idx_usage_session ON usage_events(session_id, provider);

        CREATE TABLE IF NOT EXISTS rate_limit_events (
            id TEXT NOT NULL, provider TEXT NOT NULL, ts INTEGER NOT NULL,
            session_id TEXT NOT NULL, message TEXT NOT NULL,
            PRIMARY KEY (provider, id)
        );

        CREATE TABLE IF NOT EXISTS quota_snapshots (
            provider TEXT NOT NULL, observed_at INTEGER NOT NULL,
            used_percent REAL NOT NULL, window_minutes INTEGER NOT NULL,
            resets_at INTEGER, plan_type TEXT, source TEXT NOT NULL,
            PRIMARY KEY (provider, observed_at)
        );

        -- 续读状态：inode + size 用来识别文件被轮转或截断
        CREATE TABLE IF NOT EXISTS scan_state (
            path TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            inode INTEGER NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            offset INTEGER NOT NULL,
            cursor TEXT
        );
        """)
    }

    // MARK: - 写入

    public struct FileState: Sendable {
        public var offset: UInt64
        public var cursor: String?
        public var inode: UInt64
        public var size: UInt64
    }

    public func fileState(path: String) throws -> FileState? {
        var out: FileState?
        try db.query("SELECT offset, cursor, inode, size FROM scan_state WHERE path = ?",
                     [.text(path)]) { r in
            out = FileState(offset: UInt64(r.int(0)), cursor: r.text(1),
                            inode: UInt64(r.int(2)), size: UInt64(r.int(3)))
        }
        return out
    }

    public func saveFileState(path: String, provider: Provider, inode: UInt64,
                              size: UInt64, mtime: Double, offset: UInt64, cursor: String?) throws {
        let stmt = try db.prepare("""
            INSERT INTO scan_state (path, provider, inode, size, mtime, offset, cursor)
            VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                inode=excluded.inode, size=excluded.size, mtime=excluded.mtime,
                offset=excluded.offset, cursor=excluded.cursor
            """)
        defer { stmt.finalize() }
        try stmt.run([.text(path), .text(provider.rawValue), .int(Int(inode)),
                      .int(Int(size)), .double(mtime), .int(Int(offset)),
                      cursor.map { .text($0) } ?? .null])
    }

    public func insert(events: [UsageEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }
        let stmt = try db.prepare("""
            INSERT OR IGNORE INTO usage_events
            (id, provider, ts, session_id, project_path, git_branch, model,
             input_tokens, output_tokens, cache_read_tokens,
             cache_write_5m_tokens, cache_write_1h_tokens, reasoning_tokens, official_cost_usd)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        defer { stmt.finalize() }
        var inserted = 0
        for e in events {
            try stmt.run([
                .text(e.id), .text(e.provider.rawValue), .int(Int(e.timestamp.timeIntervalSince1970)),
                .text(e.sessionId), e.projectPath.map { .text($0) } ?? .null,
                e.gitBranch.map { .text($0) } ?? .null, .text(e.model),
                .int(e.inputTokens), .int(e.outputTokens), .int(e.cacheReadTokens),
                .int(e.cacheWrite5mTokens), .int(e.cacheWrite1hTokens), .int(e.reasoningTokens),
                e.officialCostUSD.map { .double($0) } ?? .null,
            ])
            inserted += 1
        }
        return inserted
    }

    public func insert(rateLimits: [RateLimitEvent]) throws {
        guard !rateLimits.isEmpty else { return }
        let stmt = try db.prepare("""
            INSERT OR IGNORE INTO rate_limit_events (id, provider, ts, session_id, message)
            VALUES (?,?,?,?,?)
            """)
        defer { stmt.finalize() }
        for e in rateLimits {
            try stmt.run([.text(e.id), .text(e.provider.rawValue),
                          .int(Int(e.timestamp.timeIntervalSince1970)),
                          .text(e.sessionId), .text(e.message)])
        }
    }

    public func insert(quota: QuotaStatus) throws {
        let stmt = try db.prepare("""
            INSERT OR REPLACE INTO quota_snapshots
            (provider, observed_at, used_percent, window_minutes, resets_at, plan_type, source)
            VALUES (?,?,?,?,?,?,?)
            """)
        defer { stmt.finalize() }
        try stmt.run([.text(quota.provider.rawValue),
                      .int(Int(quota.observedAt.timeIntervalSince1970)),
                      .double(quota.usedPercent), .int(quota.windowMinutes),
                      quota.resetsAt.map { .int(Int($0.timeIntervalSince1970)) } ?? .null,
                      quota.planType.map { .text($0) } ?? .null,
                      .text(quota.source.rawValue)])
    }

    public func reset() throws {
        try db.exec("DELETE FROM usage_events; DELETE FROM scan_state; DELETE FROM rate_limit_events; DELETE FROM quota_snapshots;")
    }
}
