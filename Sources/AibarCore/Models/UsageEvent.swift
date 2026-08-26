import Foundation

/// 三家日志归一化之后的统一用量事件。
///
/// `id` 是 provider 内部的去重键，写库时作为主键，重复插入直接忽略：
///   - Claude：`requestId`（实测 41% 的行是重复落盘，且重复组 usage 完全一致）
///   - Codex：`sessionId#序号`（用 total 单调差值切出的每轮增量）
///   - Grok：`eventId`
public struct UsageEvent: Sendable, Hashable {
    public let id: String
    public let provider: Provider
    public let timestamp: Date
    public let sessionId: String
    public let projectPath: String?
    public let gitBranch: String?
    public let model: String

    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWrite5mTokens: Int
    public let cacheWrite1hTokens: Int
    public let reasoningTokens: Int

    /// 仅 Grok 提供（costUsdTicks / 1e10）。非 nil 时一律优先于本地价格表估算。
    public let officialCostUSD: Double?

    public init(
        id: String, provider: Provider, timestamp: Date, sessionId: String,
        projectPath: String? = nil, gitBranch: String? = nil, model: String,
        inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
        cacheWrite5mTokens: Int = 0, cacheWrite1hTokens: Int = 0, reasoningTokens: Int = 0,
        officialCostUSD: Double? = nil
    ) {
        self.id = id; self.provider = provider; self.timestamp = timestamp
        self.sessionId = sessionId; self.projectPath = projectPath; self.gitBranch = gitBranch
        self.model = model
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens; self.cacheWrite1hTokens = cacheWrite1hTokens
        self.reasoningTokens = reasoningTokens
        self.officialCostUSD = officialCostUSD
    }

    /// 总 token。注意 `reasoningTokens` 是 `outputTokens` 的子集，不重复计入。
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    public var projectName: String? {
        guard let p = projectPath, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p).lastPathComponent
    }
}

/// Claude 日志里的 429 限流事件。答不出“现在还剩多少”，但能答“本周撞了几次墙”。
public struct RateLimitEvent: Sendable, Hashable {
    public let id: String
    public let provider: Provider
    public let timestamp: Date
    public let sessionId: String
    public let message: String

    public init(id: String, provider: Provider, timestamp: Date, sessionId: String, message: String) {
        self.id = id; self.provider = provider; self.timestamp = timestamp
        self.sessionId = sessionId; self.message = message
    }
}

/// 额度状态。M1 只从 Codex 本地日志取；L2 接口层在 M4 接入。
public struct QuotaStatus: Sendable, Hashable {
    public let provider: Provider
    public let usedPercent: Double
    public let windowMinutes: Int
    public let resetsAt: Date?
    public let planType: String?
    public let observedAt: Date
    public let source: Source

    public enum Source: String, Sendable { case localLog, officialAPI }

    public init(provider: Provider, usedPercent: Double, windowMinutes: Int,
                resetsAt: Date?, planType: String?, observedAt: Date, source: Source) {
        self.provider = provider; self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes; self.resetsAt = resetsAt
        self.planType = planType; self.observedAt = observedAt; self.source = source
    }
}
