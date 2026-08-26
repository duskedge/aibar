import Foundation

/// L2：向官方接口查实时剩余额度。
///
/// 目前只有 Claude 有可用的端点。Codex 的额度本地日志里就有，发请求纯属多余；
/// Grok 经查证**没有**官方额度接口（`cli-chat-proxy.grok.com/v1` 只有
/// chat / models / settings），所以宁可显示"未提供"，也不用成本除以套餐上限
/// 反推一个假百分比。
public protocol LiveQuotaClient: Sendable {
    var provider: Provider { get }
    var endpointDescription: String { get }
    func fetch() async throws -> [QuotaStatus]
}

// MARK: - Claude

public struct ClaudeQuotaClient: LiveQuotaClient {
    public let provider = Provider.claudeCode
    public let endpointDescription = "api.anthropic.com/api/oauth/usage"

    public init() {}

    public func fetch() async throws -> [QuotaStatus] {
        let token = try Credentials.claudeCode()
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let data = try await NetworkGuard.send(
            url: url, token: token.value,
            headers: ["anthropic-beta": "oauth-2025-04-20", "Accept": "application/json"])
        return try Self.parse(data, plan: token.plan)
    }

    /// 响应形如：
    /// ```json
    /// { "five_hour":  { "utilization": 12, "resets_at": "2026-08-26T14:00:00Z" },
    ///   "seven_day":  { "utilization": 45, "resets_at": "..." },
    ///   "seven_day_opus": { "utilization": 30, "resets_at": "..." } }
    /// ```
    /// 字段可能增减，所以按已知键逐个尝试，认不出的整块跳过而不是抛错 ——
    /// 上游加一个新窗口不该让整个功能挂掉。
    static func parse(_ data: Data, plan: String?) throws -> [QuotaStatus] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkGuard.NetworkError.badResponse("顶层不是对象")
        }

        // (键, 展示用窗口分钟数)
        let windows: [(String, Int)] = [
            ("five_hour", 300),
            ("seven_day", 10080),
            ("seven_day_opus", 10080),
            ("seven_day_sonnet", 10080),
            ("monthly", 43200),
        ]

        var out: [QuotaStatus] = []
        for (key, minutes) in windows {
            guard let node = root[key] as? [String: Any] else { continue }
            guard let used = (node["utilization"] as? Double)
                    ?? (node["utilization"] as? Int).map(Double.init) else { continue }
            let resets = (node["resets_at"] as? String).flatMap(DateParsing.iso8601UTC)
                ?? (node["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            out.append(QuotaStatus(
                provider: .claudeCode,
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: resets,
                planType: plan,
                observedAt: .now,
                source: .officialAPI,
                windowLabel: Self.label(for: key)))
        }

        guard !out.isEmpty else {
            throw NetworkGuard.NetworkError.badResponse(
                "没有认识的额度字段（收到：\(root.keys.sorted().prefix(8).joined(separator: ", "))）")
        }
        return out
    }

    static func label(for key: String) -> String {
        switch key {
        case "five_hour": "5 小时窗口"
        case "seven_day": "7 天窗口"
        case "seven_day_opus": "7 天 · Opus"
        case "seven_day_sonnet": "7 天 · Sonnet"
        case "monthly": "月度"
        default: key
        }
    }
}

// MARK: - 服务

/// L2 的总闸。离线模式与逐家开关都在这里生效 ——
/// 关掉之后连凭据都不会去读。
public actor LiveQuotaService {
    public struct Config: Sendable {
        /// 全局离线。为 true 时本服务什么都不做。
        public var offline: Bool
        /// 逐家开关。
        public var enabled: Set<Provider>
        /// 轮询间隔下限。
        public var minInterval: TimeInterval

        /// 默认**关闭**。L2 必须由 app 在展示过披露页之后显式打开 ——
        /// 这样单测、CLI、离屏渲染都不会意外联网。
        public init(offline: Bool = true,
                    enabled: Set<Provider> = [],
                    minInterval: TimeInterval = 60) {
            self.offline = offline; self.enabled = enabled; self.minInterval = minInterval
        }
    }

    public struct Result: Sendable {
        public var quotas: [QuotaStatus] = []
        /// provider → 失败原因。UI 要显示"未连接 + 为什么"，不能只留个空环。
        public var failures: [Provider: String] = [:]
        public var fetchedAt: Date?
    }

    private let clients: [any LiveQuotaClient]
    private var config: Config
    private var lastFetch = Date.distantPast
    private var cached = Result()

    public init(config: Config = Config(), clients: [any LiveQuotaClient]? = nil) {
        self.config = config
        self.clients = clients ?? [ClaudeQuotaClient()]
    }

    public func update(config: Config) { self.config = config }
    public func current() -> Result { cached }

    /// 拉取一次。离线、被关闭、或距上次太近都会直接返回缓存。
    @discardableResult
    public func refresh(force: Bool = false) async -> Result {
        guard !config.offline else {
            cached = Result(quotas: [], failures: [:], fetchedAt: cached.fetchedAt)
            return cached
        }
        if !force, Date.now.timeIntervalSince(lastFetch) < config.minInterval { return cached }
        lastFetch = .now

        var result = Result()
        for client in clients where config.enabled.contains(client.provider) {
            do {
                result.quotas += try await client.fetch()
            } catch {
                // 失败绝不影响 L1，只记录原因
                result.failures[client.provider] = "\(error)"
            }
        }
        result.fetchedAt = .now
        cached = result
        return result
    }

    /// 各家 L2 的可用情况，设置页与披露页都要如实展示。
    public nonisolated static func availability(for provider: Provider) -> String {
        switch provider {
        case .claudeCode: "api.anthropic.com/api/oauth/usage"
        case .codex: "不需要 —— 本地日志已含官方额度"
        case .grok: "该 CLI 未提供额度接口"
        }
    }

    public nonisolated static func supportsLiveQuota(_ provider: Provider) -> Bool {
        provider == .claudeCode
    }
}
