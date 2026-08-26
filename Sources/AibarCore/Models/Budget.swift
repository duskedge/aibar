import Foundation

/// 用户自设的花费预算。
///
/// 和 `QuotaStatus` 是**两件事**，界面上必须分得清：
/// - 额度（quota）＝ 厂商给的官方剩余量，aibar 只做搬运，拿不到就说拿不到
/// - 预算（budget）＝ 你自己定的花费上限，aibar 用等价 API 成本去算进度
///
/// 有工具把「本地成本 ÷ 套餐价」直接当成额度百分比显示。那个数字算法上没错，
/// 但它回答的是"我花了多少钱"，不是"厂商还让我用多少"——
/// 两者在限流面前差别很大。所以 aibar 把它单列成预算，并明确标注来源。
public struct Budget: Sendable, Hashable, Codable {
    public var provider: Provider
    /// 上限（美元）。0 表示未设置。
    public var limitUSD: Double
    public var window: Window

    public enum Window: String, Sendable, Codable, CaseIterable {
        case week, month

        public var label: String { L(self == .week ? "每 7 天" : "每 30 天") }
        public var days: Int { self == .week ? 7 : 30 }
        public var since: Date? {
            Calendar.current.date(byAdding: .day, value: -days,
                                  to: Calendar.current.startOfDay(for: .now))
        }
    }

    public init(provider: Provider, limitUSD: Double = 0, window: Window = .month) {
        self.provider = provider; self.limitUSD = limitUSD; self.window = window
    }

    public var isConfigured: Bool { limitUSD > 0 }
}

/// 某个预算的当前进度。
public struct BudgetProgress: Sendable, Hashable, Identifiable {
    public let provider: Provider
    public let spentUSD: Double
    public let limitUSD: Double
    public let window: Budget.Window
    /// 该窗口内是否有缺定价的模型 —— 有的话进度是低估的，必须说出来。
    public let hasUnpricedUsage: Bool

    public var id: Provider { provider }
    public var usedPercent: Double { limitUSD > 0 ? min(999, spentUSD / limitUSD * 100) : 0 }
    public var remainingUSD: Double { max(0, limitUSD - spentUSD) }

    public init(provider: Provider, spentUSD: Double, limitUSD: Double,
                window: Budget.Window, hasUnpricedUsage: Bool) {
        self.provider = provider; self.spentUSD = spentUSD; self.limitUSD = limitUSD
        self.window = window; self.hasUnpricedUsage = hasUnpricedUsage
    }
}

/// 预算集合的编解码。存进 UserDefaults 用。
public enum BudgetStore {
    public static func encode(_ budgets: [Budget]) -> String {
        (try? JSONEncoder().encode(budgets)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    public static func decode(_ raw: String) -> [Budget] {
        (try? JSONDecoder().decode([Budget].self, from: Data(raw.utf8))) ?? []
    }

    /// 三家都给一条，未配置的 limit 为 0。
    public static func normalized(_ budgets: [Budget]) -> [Budget] {
        Provider.allCases.map { p in
            budgets.first { $0.provider == p } ?? Budget(provider: p)
        }
    }
}
