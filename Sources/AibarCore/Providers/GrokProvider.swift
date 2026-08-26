import Foundation

/// `~/.grok/sessions/<urlencode(cwd)>/<sessionId>/updates.jsonl`
///
/// 三家里最省事的一家：每轮结束有一条 `turn_completed`，usage 已经按模型拆好，
/// 而且**自带成本** —— `costUsdTicks / 1e10` 就是美元（实测 178580000 ticks ≈ $0.01786，
/// 与 grok-4.6 官方价吻合）。所以 Grok 一律用官方值，不走本地价格表估算。
///
/// 唯一要注意的是项目路径藏在 URL 编码的目录名里，字段名也是 camelCase。
///
/// **额度也在本地**，但不在会话目录里，而在 `~/.grok/logs/unified.jsonl`：
/// ```json
/// {"msg":"billing: fetched credits config","ctx":{
///   "config":{"creditUsagePercent":4.0,
///             "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
///                              "end":"2026-09-02T00:57:35Z"}},
///   "subscriptionTier":"SuperGrok"}}
/// ```
/// 这就是 `grok` 命令里 `Usage limit` 面板显示的那个数字，官方值，无需联网。
public struct GrokProvider: UsageProvider {
    public let provider = Provider.grok
    public let root: URL
    public let logRoot: URL

    public init(root: URL? = nil, logRoot: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.root = root ?? home.appendingPathComponent(".grok/sessions")
        self.logRoot = logRoot ?? home.appendingPathComponent(".grok/logs")
    }

    public var rootPaths: [URL] { [root, logRoot] }

    public func discoverFiles() -> [URL] {
        files(under: root, named: "updates.jsonl") + files(under: logRoot, named: "unified.jsonl")
    }

    private static let marker = Array("turn_completed".utf8)
    private static let billingMarker = Array("billing: fetched credits config".utf8)

    public func parse(file: URL, from offset: UInt64, cursor: String?) throws -> ScanResult {
        if file.lastPathComponent == "unified.jsonl" { return try parseBillingLog(file, from: offset) }
        return try parseSessionLog(file, from: offset)
    }

    /// 从统一日志里取官方周额度。
    ///
    /// 这个文件里还有大量其他日志（提示词片段、工具调用等），
    /// 所以先按字节匹配 `billing: fetched credits config` 过滤，
    /// **只解析这一种记录**，其余行连 JSON 都不解。
    private func parseBillingLog(_ file: URL, from offset: UInt64) throws -> ScanResult {
        var result = ScanResult(newOffset: offset)
        let end = try LineReader.read(file: file, from: offset) { line in
            guard line.contains(bytes: Self.billingMarker) else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let ctx = obj["ctx"] as? [String: Any],
                  let config = ctx["config"] as? [String: Any],
                  let used = jsonDouble(config["creditUsagePercent"]),
                  let ts = obj["ts"] as? String,
                  let observed = DateParsing.iso8601UTC(ts)
            else { result.malformedLines += 1; return }

            let period = config["currentPeriod"] as? [String: Any]
            let resets = (period?["end"] as? String).flatMap(DateParsing.iso8601UTC)
            // 周期类型决定窗口长度；目前只见过 WEEKLY
            let minutes = switch period?["type"] as? String {
            case "USAGE_PERIOD_TYPE_WEEKLY": 10080
            case "USAGE_PERIOD_TYPE_MONTHLY": 43200
            case "USAGE_PERIOD_TYPE_DAILY": 1440
            default: 10080
            }

            let quota = QuotaStatus(
                provider: .grok, usedPercent: used, windowMinutes: minutes,
                resetsAt: resets, planType: ctx["subscriptionTier"] as? String,
                observedAt: observed, source: .localLog)
            if let existing = result.quotas[minutes], existing.observedAt >= observed { return }
            result.quotas[minutes] = quota
        }
        result.newOffset = end
        return result
    }

    private func parseSessionLog(_ file: URL, from offset: UInt64) throws -> ScanResult {
        var result = ScanResult(newOffset: offset)
        let sessionId = file.deletingLastPathComponent().lastPathComponent
        let cwd = file.deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent.removingPercentEncoding

        let end = try LineReader.read(file: file, from: offset) { line in
            guard line.contains(bytes: Self.marker) else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { result.malformedLines += 1; return }

            guard let params = obj["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed",
                  let usage = update["usage"] as? [String: Any]
            else { return }

            let epoch = jsonDouble(obj["timestamp"]) ?? 0
            let date = Date(timeIntervalSince1970: epoch)
            let meta = obj["_meta"] as? [String: Any]
            let eventId = meta?["eventId"] as? String
                ?? "\(sessionId)-\(update["prompt_id"] as? String ?? "\(epoch)")"

            // modelUsage 已按模型拆好，直接展开成多条事件，省掉后面按模型聚合的猜测
            let byModel = usage["modelUsage"] as? [String: [String: Any]]
            let entries: [(String, [String: Any])] = byModel.map { Array($0) }
                ?? [(params["model"] as? String ?? "grok", usage)]

            for (model, u) in entries {
                let ticks = jsonDouble(u["costUsdTicks"])
                let event = UsageEvent(
                    id: entries.count > 1 ? "\(eventId)#\(model)" : eventId,
                    provider: .grok,
                    timestamp: date,
                    sessionId: sessionId,
                    projectPath: cwd,
                    model: model,
                    inputTokens: max(0, jsonInt(u["inputTokens"]) - jsonInt(u["cachedReadTokens"])),
                    outputTokens: jsonInt(u["outputTokens"]),
                    cacheReadTokens: jsonInt(u["cachedReadTokens"]),
                    cacheWrite5mTokens: jsonInt(u["cacheCreationTokens"]),
                    reasoningTokens: jsonInt(u["reasoningTokens"]),
                    officialCostUSD: ticks.map { $0 / 1e10 })
                if event.totalTokens > 0 { result.events.append(event) }
            }
        }
        result.newOffset = end
        return result
    }
}
