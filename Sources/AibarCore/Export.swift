import Foundation

/// CSV / JSON 导出。
///
/// 导出的是用量数据，**绝不包含凭据、对话正文或任何 token 值**。
/// 只有会话元信息与计数。
public enum Export {
    public enum Format: String, CaseIterable, Sendable {
        case csv, json
        public var fileExtension: String { rawValue }
    }

    /// CSV 转义：字段含逗号、引号或换行时加引号并把引号翻倍。
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// ISO8601DateFormatter 不是 Sendable，共享一个实例过不了 Swift 6 的检查。
    /// 导出是低频操作，每次现建一个足够了。
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    public static func csv(_ sessions: [SessionDetail]) -> String {
        var lines = ["开始时间,结束时间,来源,项目,项目路径,分支,模型,总Token,输入,输出,缓存读,缓存写,推理,估算成本USD,轮次,时长秒"]
        for s in sessions {
            lines.append([
                iso(s.started),
                iso(s.ended),
                s.provider.displayName,
                escape(s.project),
                escape(s.projectPath ?? ""),
                escape(s.branch ?? ""),
                escape(s.model),
                "\(s.tokens)", "\(s.input)", "\(s.output)",
                "\(s.cacheRead)", "\(s.cacheWrite)", "\(s.reasoning)",
                // 没有定价就留空，不写 0 —— 空单元格和 0 在表格里是两个意思
                s.cost.map { String(format: "%.6f", $0) } ?? "",
                "\(s.turns)", "\(Int(s.duration))",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func json(_ sessions: [SessionDetail], pricingVersion: String) throws -> Data {
        let payload: [String: Any] = [
            "generatedAt": iso(.now),
            "generator": "aibar \(NetworkGuard.version)",
            "pricingTableVersion": pricingVersion,
            "costNote": "成本为按公开 API 价格的估算值，非实际账单；null 表示该模型缺少定价",
            "sessions": sessions.map { s -> [String: Any] in
                var row: [String: Any] = [
                    "sessionId": s.sessionId,
                    "provider": s.provider.rawValue,
                    "project": s.project,
                    "model": s.model,
                    "started": iso(s.started),
                    "ended": iso(s.ended),
                    "durationSeconds": Int(s.duration),
                    "turns": s.turns,
                    "tokens": [
                        "total": s.tokens, "input": s.input, "output": s.output,
                        "cacheRead": s.cacheRead, "cacheWrite": s.cacheWrite,
                        "reasoning": s.reasoning,
                    ],
                    "estimatedCostUSD": s.cost as Any,
                ]
                if let p = s.projectPath { row["projectPath"] = p }
                if let b = s.branch { row["gitBranch"] = b }
                return row
            },
        ]
        return try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func suggestedFilename(range: DateRange, format: Format) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return "aibar-\(range.label)-\(f.string(from: .now)).\(format.fileExtension)"
    }
}
