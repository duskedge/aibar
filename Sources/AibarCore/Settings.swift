import Foundation

/// 菜单栏显示什么。默认是额度 —— 它是唯一能回答“我现在还能不能继续用”的指标。
public enum MenuBarDisplay: String, CaseIterable, Sendable {
    case quota, cost, tokens, iconOnly

    public var label: String {
        switch self {
        case .quota: L("额度")
        case .cost: L("今日成本")
        case .tokens: L("今日 Token")
        case .iconOnly: L("仅图标")
        }
    }
}

public enum SettingsKey {
    public static let display = "menuBarDisplay"
    public static let warnThreshold = "quotaWarnThreshold"
    public static let critThreshold = "quotaCritThreshold"
    public static let notifyOnQuota = "notifyOnQuota"
    /// 全局离线：为 true 时 L2 一个请求都不会发，连凭据都不读。
    public static let offlineMode = "offlineMode"
    /// 逐家 L2 开关。
    public static let liveQuotaClaude = "liveQuota.claude"
    /// 逐家数据源开关。关掉后停止扫描、停止接口查询，面板也不再显示这家。
    public static let providerEnabledClaude = "provider.enabled.claude"
    public static let providerEnabledCodex = "provider.enabled.codex"
    public static let providerEnabledGrok = "provider.enabled.grok"
    /// 首启披露页是否已展示过。
    public static let disclosureShown = "disclosureShown"
    public static let menuBarTarget = "menuBarTarget"
    public static let menuBarWindow = "menuBarWindow"
    public static let menuBarShowWindowName = "menuBarShowWindowName"
    public static let menuBarShowReset = "menuBarShowReset"
    public static let budgets = "budgets"
    public static let language = "interfaceLanguage"
    /// 启动后自动查 GitHub Release。关闭后仍可在关于页手动检查。
    public static let autoCheckUpdates = "autoCheckUpdates"
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

/// 菜单栏显示哪一家的额度。
///
/// 默认「最紧张的一家」—— 常驻图标应该主动告诉你哪里快撑不住了，
/// 而不是要你自己挨个点开看。但盯着某一家干活时，固定显示那家更省心。
public enum MenuBarTarget: RawRepresentable, CaseIterable, Sendable, Hashable {
    case tightest
    case provider(Provider)

    public init?(rawValue: String) {
        if rawValue == "tightest" { self = .tightest; return }
        guard let p = Provider(rawValue: rawValue) else { return nil }
        self = .provider(p)
    }

    public var rawValue: String {
        switch self {
        case .tightest: "tightest"
        case .provider(let p): p.rawValue
        }
    }

    public static var allCases: [MenuBarTarget] {
        [.tightest] + Provider.allCases.map(MenuBarTarget.provider)
    }

    public var label: String {
        switch self {
        case .tightest: L("最紧张的一家")
        case .provider(let p): p.displayName
        }
    }
}

/// 一家有多个窗口时（Claude 5 小时 + 7 天、Codex 5 小时 + 7 天），菜单栏显示哪个。
public enum MenuBarWindow: String, CaseIterable, Sendable {
    case tightest, shortest, longest

    public var label: String {
        switch self {
        case .tightest: L("用得最多的窗口")
        case .shortest: L("最短窗口")
        case .longest: L("最长窗口")
        }
    }
}
