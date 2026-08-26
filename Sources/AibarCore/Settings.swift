import Foundation

/// 菜单栏显示什么。默认是额度 —— 它是唯一能回答“我现在还能不能继续用”的指标。
public enum MenuBarDisplay: String, CaseIterable, Sendable {
    case quota, cost, tokens, iconOnly

    public var label: String {
        switch self {
        case .quota: "额度"
        case .cost: "今日成本"
        case .tokens: "今日 Token"
        case .iconOnly: "仅图标"
        }
    }
}

public enum SettingsKey {
    public static let display = "menuBarDisplay"
    public static let warnThreshold = "quotaWarnThreshold"
    public static let critThreshold = "quotaCritThreshold"
    public static let notifyOnQuota = "notifyOnQuota"
}

public struct Thresholds: Sendable {
    public var warn: Double
    public var critical: Double
    public init(warn: Double = 80, critical: Double = 95) {
        self.warn = warn; self.critical = critical
    }

    public enum Level: Sendable { case normal, warning, critical }

    public func level(for percent: Double) -> Level {
        percent >= critical ? .critical : percent >= warn ? .warning : .normal
    }
}
