import Foundation

/// 数据侧的唯一入口。
///
/// `UsageStore` 里握着 SQLite 的 `OpaquePointer`，不是 Sendable；
/// 把它整个关进 actor，UI 侧只拿 `Snapshot` 值类型，从根上避免跨线程共享。
public actor UsageEngine {
    private let store: UsageStore
    private let scanner: Scanner
    private let reports: Reports
    private var watcher: FileWatcher?
    private let liveQuota: LiveQuotaService
    private var scanning = false
    private var lastRefresh = Date.distantPast
    private var budgets: [Budget] = []
    /// 两次刷新之间的最小间隔。
    ///
    /// 用户正在跑对话时，CLI 是持续写日志的，FSEvents 会一直触发。
    /// 没有这个下限就会变成“扫完立刻再扫”，实测能把 CPU 顶到 40% 以上。
    public var minRefreshInterval: TimeInterval = 5

    /// - Parameter providers: 传 nil 用三家的默认路径；测试里注入临时目录，
    ///   免得单测去扫用户本机几个 GB 的真实日志。
    public init(dbPath: String = UsageStore.defaultPath,
                pricing: PricingTable = .builtin,
                providers: [any UsageProvider]? = nil) throws {
        store = try UsageStore(path: dbPath)
        scanner = Scanner(store: store, providers: providers)
        reports = Reports(store: store, pricing: pricing)
        liveQuota = LiveQuotaService()
    }

    public func configure(budgets: [Budget]) { self.budgets = budgets }

    public func configureLiveQuota(_ config: LiveQuotaService.Config) async {
        await liveQuota.update(config: config)
    }

    /// 拉一次 L2。离线或被关掉时它自己会短路，这里不必再判断。
    @discardableResult
    public func refreshLiveQuota(force: Bool = false) async -> LiveQuotaService.Result {
        await liveQuota.refresh(force: force)
    }

    public var watchedPaths: [URL] { scanner.providers.flatMap(\.rootPaths) }
    /// 上次真正执行扫描的时刻（被节流跳过的调用不更新它）。
    public var lastRefreshedAt: Date { lastRefresh }

    /// 扫描一次并返回新快照。
    ///
    /// 重入与过于频繁的调用都直接返回当前快照，不排队、不堆积：
    /// 漏掉的变更下一次 FSEvents 事件会带上，用量统计不需要亚秒级实时。
    /// - Parameter force: 忽略最小间隔（手动点刷新时用）
    @discardableResult
    public func refresh(force: Bool = false) async throws -> Snapshot {
        guard !scanning else { return try await snapshot() }
        if !force, Date.now.timeIntervalSince(lastRefresh) < minRefreshInterval {
            return try await snapshot()
        }
        scanning = true
        defer { scanning = false; lastRefresh = .now }
        _ = try scanner.scan()
        await liveQuota.refresh()
        return try await snapshot()
    }

    public func snapshot() async throws -> Snapshot {
        var snap = try reports.snapshot(budgets: budgets)
        let live = await liveQuota.current()
        snap.liveQuotas = live.quotas
        snap.quotaFailures = live.failures
        snap.liveFetchedAt = live.fetchedAt
        return snap
    }

    public func dashboard(range: DateRange) throws -> DashboardData {
        try reports.dashboard(range: range)
    }

    public func sessions(range: DateRange, provider: Provider?, search: String?) throws -> [SessionDetail] {
        try reports.sessions(range: range, provider: provider, search: search)
    }

    public func timeline(sessionId: String, provider: Provider) throws -> [TurnPoint] {
        try reports.timeline(sessionId: sessionId, provider: provider)
    }

    public func scanSummary() throws -> Scanner.Summary { try scanner.scan() }

    /// 监听三家的数据目录。FSEvents 自带 latency 合并，这里不再另做去抖。
    public func startWatching(onChange: @escaping @Sendable () -> Void) {
        guard watcher == nil else { return }
        watcher = FileWatcher(paths: watchedPaths, latency: 2.0, handler: onChange)
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    public func rebuild() async throws -> Snapshot {
        try store.reset()
        return try await refresh()
    }
}
