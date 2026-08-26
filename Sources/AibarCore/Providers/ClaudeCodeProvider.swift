import Foundation

/// `~/.claude/projects/<项目路径转义>/<sessionId>.jsonl`
///
/// 两个必须处理的坑：
/// 1. 同一次请求会重复落盘。实测 5850 行只有 3458 个唯一 requestId（41% 重复），
///    且重复组的 usage 完全一致 —— 所以按 requestId 去重、任取一条即可。
/// 2. `model == "<synthetic>"` 的行是 CLI 自己造的消息（限流提示等），usage 全零，
///    要跳过；但其中带 `error: "rate_limit"` 的值得单独收集成限流事件。
public struct ClaudeCodeProvider: UsageProvider {
    public let provider = Provider.claudeCode
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    public var rootPaths: [URL] { [root] }
    public func discoverFiles() -> [URL] { files(under: root, ext: "jsonl") }

    private static let marker = Array(#""usage""#.utf8)

    public func parse(file: URL, from offset: UInt64, cursor: String?) throws -> ScanResult {
        var result = ScanResult(newOffset: offset)
        let end = try LineReader.read(file: file, from: offset) { line in
            guard line.contains(bytes: Self.marker) else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { result.malformedLines += 1; return }

            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let date = DateParsing.iso8601UTC(ts)
            else { return }

            let sessionId = obj["sessionId"] as? String ?? obj["session_id"] as? String ?? ""

            // 限流事件：算不出剩余额度，但能算出撞墙频次
            if obj["error"] as? String == "rate_limit" {
                let text = ((message["content"] as? [[String: Any]])?
                    .compactMap { $0["text"] as? String }.first) ?? "rate limited"
                result.rateLimits.append(RateLimitEvent(
                    id: obj["uuid"] as? String ?? "\(sessionId)-\(ts)",
                    provider: .claudeCode, timestamp: date, sessionId: sessionId, message: text))
                return
            }

            guard let usage = message["usage"] as? [String: Any],
                  let requestId = obj["requestId"] as? String,
                  let model = message["model"] as? String, model != "<synthetic>"
            else { return }

            let creation = usage["cache_creation"] as? [String: Any]
            let write1h = jsonInt(creation?["ephemeral_1h_input_tokens"])
            let write5m = jsonInt(creation?["ephemeral_5m_input_tokens"])
            // 老版本没有 cache_creation 细分，退回到汇总字段并全部算作 5m（更便宜的那档，
            // 宁可低估也不虚报）
            let writeTotal = jsonInt(usage["cache_creation_input_tokens"])
            let hasBreakdown = creation != nil && (write1h + write5m) > 0

            let event = UsageEvent(
                id: requestId,
                provider: .claudeCode,
                timestamp: date,
                sessionId: sessionId,
                projectPath: obj["cwd"] as? String,
                gitBranch: obj["gitBranch"] as? String,
                model: model,
                inputTokens: jsonInt(usage["input_tokens"]),
                outputTokens: jsonInt(usage["output_tokens"]),
                cacheReadTokens: jsonInt(usage["cache_read_input_tokens"]),
                cacheWrite5mTokens: hasBreakdown ? write5m : writeTotal,
                cacheWrite1hTokens: hasBreakdown ? write1h : 0,
                reasoningTokens: jsonInt((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"])
            )
            if event.totalTokens > 0 { result.events.append(event) }
        }
        result.newOffset = end
        return result
    }
}
