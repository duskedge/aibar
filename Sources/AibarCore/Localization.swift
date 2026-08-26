import Foundation

/// 本地化。
///
/// 开发语言是中文，中文原文**就是 key** —— 所以缺翻译时自然回落到中文，
/// 不会出现 `settings.network.title` 这种裸 key 漏到界面上。
/// 翻译放在 app bundle 的 `en.lproj/Localizable.strings`。
///
/// SwiftUI 的 `Text("今日")` 会自己走同一套查找，所以静态文案不用包 `L(...)`；
/// 只有**带插值**的和**非 View 层**（Core 里的枚举 label、错误描述）才需要。
@inlinable
public func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, value: key, comment: "")
}

/// 带参数的版本。key 里用 `%@` / `%lld` 占位。
///
///     L("被限流 %lld 次", count)
public func L(_ key: String, _ arguments: any CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, value: key, comment: "")
    return String(format: format, locale: .current, arguments: arguments)
}

public enum Localization {
    /// 支持的界面语言。跟随系统之外，允许在设置里强制指定 ——
    /// 系统语言是英文但想看中文界面的人不少。
    public enum Language: String, CaseIterable, Sendable {
        case system, zhHans = "zh-Hans", en

        public var label: String {
            switch self {
            case .system: L("跟随系统")
            case .zhHans: "简体中文"
            case .en: "English"
            }
        }

        /// 写进 `AppleLanguages` 的值。`system` 返回 nil 表示清除覆盖。
        public var appleLanguages: [String]? {
            switch self {
            case .system: nil
            case .zhHans: ["zh-Hans"]
            case .en: ["en"]
            }
        }
    }

    /// 当前生效的界面语言（只读，用于设置页展示）。
    public static var effectiveLanguage: String {
        Bundle.main.preferredLocalizations.first ?? "zh-Hans"
    }
}
