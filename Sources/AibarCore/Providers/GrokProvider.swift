import Foundation

/// `~/.grok/sessions/<urlencode(cwd)>/<sessionId>/updates.jsonl`
///
/// 三家里最省事的一家：每轮结束有一条 `turn_completed`，usage 已经按模型拆好，
/// 而且**自带成本** —— `costUsdTicks / 1e10` 就是美元（实测 178580000 ticks ≈ $0.01786，
/// 与 grok-4.6 官方价吻合）。所以 Grok 一律用官方值，不走本地价格表估算。
///
/// 唯一要注意的是项目路径藏在 URL 编码的目录名里，字段名也是 camelCase。
public struct GrokProvider: UsageProvider {
    public let provider = Provider.grok
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/sessions")
    }

    public var rootPaths: [URL] { [root] }
    public func discoverFiles() -> [URL] { files(under: root, named: "updates.jsonl") }

    private static let marker = Array("turn_completed".utf8)

    public func parse(file: URL, from offset: UInt64, cursor: String?) throws -> ScanResult {
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
