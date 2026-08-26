import Foundation

/// 每百万 token 的美元单价。
public struct ModelPrice: Sendable, Codable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double

    public init(input: Double, output: Double,
                cacheWrite5m: Double, cacheWrite1h: Double, cacheRead: Double) {
        self.input = input; self.output = output
        self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    /// 没有分档缓存概念的模型（如 OpenAI 系）：写入按 input 价，读取给折扣价。
    public init(input: Double, output: Double, cacheRead: Double) {
        self.init(input: input, output: output,
                  cacheWrite5m: input, cacheWrite1h: input, cacheRead: cacheRead)
    }
}

/// 价格表。缺定价时返回 nil 而不是 0 —— 静默按 0 计算是最坏的一种错，
/// 它会让用户以为自己没花钱。
public struct PricingTable: Sendable {
    public let version: String
    private let prices: [String: ModelPrice]

    public init(version: String, prices: [String: ModelPrice]) {
        self.version = version
        self.prices = prices
    }

    public static let builtin = PricingTable(version: "2026-08-20", prices: [
        // Anthropic
        "claude-opus-5":    ModelPrice(input: 15, output: 75, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.50),
        "claude-sonnet-5":  ModelPrice(input: 3,  output: 15, cacheWrite5m: 3.75,  cacheWrite1h: 6,  cacheRead: 0.30),
        "claude-haiku-4-5": ModelPrice(input: 1,  output: 5,  cacheWrite5m: 1.25,  cacheWrite1h: 2,  cacheRead: 0.10),
        // OpenAI
        "gpt-5.6":          ModelPrice(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5":            ModelPrice(input: 1.25, output: 10, cacheRead: 0.125),
        // xAI 走官方 costUsdTicks，这里留空即可
    ])

    /// 前缀匹配，取最长命中 —— `gpt-5.6-sol` 会落到 `gpt-5.6` 而不是 `gpt-5`。
    public func price(for model: String) -> ModelPrice? {
        if let exact = prices[model] { return exact }
        var best: (String, ModelPrice)?
        for (key, value) in prices where model.hasPrefix(key) {
            if best == nil || key.count > best!.0.count { best = (key, value) }
        }
        return best?.1
    }

    /// 返回 nil 表示“这个模型没有定价”，调用方必须显式呈现，不能当 0。
    public func cost(of e: UsageEvent) -> Double? {
        if let official = e.officialCostUSD { return official }
        guard let p = price(for: e.model) else { return nil }
        return (Double(e.inputTokens) * p.input
              + Double(e.outputTokens) * p.output
              + Double(e.cacheWrite5mTokens) * p.cacheWrite5m
              + Double(e.cacheWrite1hTokens) * p.cacheWrite1h
              + Double(e.cacheReadTokens) * p.cacheRead) / 1_000_000
    }

    /// SQL 里算成本用的 CASE 表达式，避免把上百万行拉回 Swift 侧。
    /// Grok 那部分直接用 official_cost_usd。
    public func sqlCostExpression() -> String {
        var branches: [String] = ["WHEN official_cost_usd IS NOT NULL THEN official_cost_usd"]
        for (model, p) in prices.sorted(by: { $0.key.count > $1.key.count }) {
            branches.append("""
            WHEN model LIKE '\(model)%' THEN (
                input_tokens * \(p.input) + output_tokens * \(p.output)
              + cache_write_5m_tokens * \(p.cacheWrite5m) + cache_write_1h_tokens * \(p.cacheWrite1h)
              + cache_read_tokens * \(p.cacheRead)) / 1000000.0
            """)
        }
        return "CASE \(branches.joined(separator: "\n")) ELSE NULL END"
    }

    /// 库里出现过、但价格表没收录的模型。UI 要据此提示，而不是静默按 0。
    public func unpricedModels(in models: [String]) -> [String] {
        models.filter { price(for: $0) == nil && !$0.hasPrefix("grok") }
    }
}
