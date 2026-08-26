import Foundation

/// `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO>-<uuid>.jsonl`（外加 `archived_sessions/`）
///
/// 这是三家里最容易算错的一家。日志每轮同时给 `total_token_usage`（会话累计）
/// 和 `last_token_usage`（本轮增量），但实测两者并不自洽：
///
///     n= 388  final_total=55,201,861  sum(last)=55,303,167  差=-101,306
///
/// `sum(last)` 会超出 final total 最多约 6%，而 total 严格单调递增。
/// 所以以 total 为准，用**相邻 total 的差值**切出每轮增量：既精确，又天然支持
/// 断点续读（只要把上一次的 total 存进 cursor）。
public struct CodexProvider: UsageProvider {
    public let provider = Provider.codex
    public let roots: [URL]

    public init(roots: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [
            home.appendingPathComponent(".codex/sessions"),
            home.appendingPathComponent(".codex/archived_sessions"),
        ]
    }

    public var rootPaths: [URL] { roots }
    public func discoverFiles() -> [URL] { roots.flatMap { files(under: $0, ext: "jsonl") } }

    private static let marker = Array("token_count".utf8)
    private static let metaMarker = Array("session_meta".utf8)

    /// 续读游标：上一次见到的累计值 + 已发出的事件序号。
    struct Cursor: Codable {
        var input = 0, cachedInput = 0, cacheWrite = 0, output = 0, reasoning = 0
        var seq = 0
        var sessionId = ""
        var cwd: String?
        var model: String?
    }

    public func parse(file: URL, from offset: UInt64, cursor: String?) throws -> ScanResult {
        var result = ScanResult(newOffset: offset)
        var state = cursor.flatMap { try? JSONDecoder().decode(Cursor.self, from: Data($0.utf8)) }
            ?? Cursor()

        let end = try LineReader.read(file: file, from: offset) { line in
            // 会话元信息只在首行出现，但断点续读时可能落在 offset 之前，
            // 所以 cwd / sessionId 一旦拿到就存进 cursor 持久化。
            if line.contains(bytes: Self.metaMarker) {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   let payload = obj["payload"] as? [String: Any] {
                    state.sessionId = payload["id"] as? String ?? state.sessionId
                    state.cwd = payload["cwd"] as? String ?? state.cwd
                }
                return
            }
            if let m = Self.sniffModel(line) { state.model = m }

            guard line.contains(bytes: Self.marker) else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { result.malformedLines += 1; return }

            guard let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let ts = obj["timestamp"] as? String,
                  let date = DateParsing.iso8601UTC(ts)
            else { return }

            // 额度：三家里唯一在本地日志就能拿到官方百分比的。
            //
            // 必须 primary 和 secondary 都读。Codex 同时给两个窗口
            // （新版 primary=5 小时 / secondary=7 天），而旧版只有一个
            // primary=7 天。只读 primary 会让同一个数字在两种含义之间
            // 静默切换 —— 实测见过 7 天 64% 和 5 小时 12% 混在一起。
            if let limits = payload["rate_limits"] as? [String: Any] {
                let plan = limits["plan_type"] as? String
                for key in ["primary", "secondary"] {
                    guard let node = limits[key] as? [String: Any],
                          let used = jsonDouble(node["used_percent"]) else { continue }
                    let minutes = jsonInt(node["window_minutes"])
                    guard minutes > 0 else { continue }
                    let q = QuotaStatus(
                        provider: .codex, usedPercent: used, windowMinutes: minutes,
                        resetsAt: jsonDouble(node["resets_at"]).map { Date(timeIntervalSince1970: $0) },
                        planType: plan, observedAt: date, source: .localLog)
                    // 同一窗口只保留本次扫描里最新的一条
                    if let existing = result.quotas[minutes], existing.observedAt >= date { continue }
                    result.quotas[minutes] = q
                }
            }

            guard let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any]
            else { return }

            let input = jsonInt(total["input_tokens"])
            let cached = jsonInt(total["cached_input_tokens"])
            let write = jsonInt(total["cache_write_input_tokens"])
            let output = jsonInt(total["output_tokens"])
            let reasoning = jsonInt(total["reasoning_output_tokens"])

            // 严格单调是前提；万一回退（文件被重写、会话 fork），重置基线而不是产生负数
            guard input >= state.input, output >= state.output else {
                state.input = input; state.cachedInput = cached; state.cacheWrite = write
                state.output = output; state.reasoning = reasoning
                return
            }

            // Codex 的 input_tokens 含 cached，拆出真正的非缓存输入
            let dInputTotal = input - state.input
            let dCached = cached - state.cachedInput
            let dWrite = write - state.cacheWrite
            let dOutput = output - state.output
            let dReasoning = reasoning - state.reasoning
            let dFreshInput = max(0, dInputTotal - dCached)

            state.input = input; state.cachedInput = cached; state.cacheWrite = write
            state.output = output; state.reasoning = reasoning

            guard dInputTotal + dOutput + dWrite > 0 else { return }
            state.seq += 1

            let sessionId = state.sessionId.isEmpty
                ? file.deletingPathExtension().lastPathComponent : state.sessionId
            result.events.append(UsageEvent(
                id: "\(sessionId)#\(state.seq)",
                provider: .codex,
                timestamp: date,
                sessionId: sessionId,
                projectPath: state.cwd,
                model: state.model ?? "unknown",
                inputTokens: dFreshInput,
                outputTokens: dOutput,
                cacheReadTokens: dCached,
                cacheWrite5mTokens: dWrite,
                reasoningTokens: dReasoning))
        }

        result.newOffset = end
        result.cursor = (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) }
        return result
    }

    /// 模型写在 `turn_context` 里，和用量不在同一行，所以边扫边记。
    private static let modelKey = Array(#""model":""#.utf8)
    static func sniffModel(_ line: ArraySlice<UInt8>) -> String? {
        guard line.contains(bytes: modelKey) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        else { return nil }
        if let payload = obj["payload"] as? [String: Any], let m = payload["model"] as? String {
            return m
        }
        return obj["model"] as? String
    }
}
