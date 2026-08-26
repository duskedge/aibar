import SwiftUI
import AibarCore

extension Provider {
    /// 三家的品牌色。这是分类编码，不是装饰 —— 面板、图表、会话列表必须一致，
    /// 否则用户得反复回看图例。
    var tint: Color {
        switch self {
        case .claudeCode: Color(red: 0.82, green: 0.44, blue: 0.30)
        case .codex: Color(red: 0.09, green: 0.62, blue: 0.49)
        case .grok: Color(red: 0.38, green: 0.45, blue: 0.94)
        }
    }
}

extension Thresholds.Level {
    var color: Color {
        switch self {
        case .normal: .secondary
        case .warning: Color(red: 0.85, green: 0.60, blue: 0.15)
        case .critical: Color(red: 0.80, green: 0.28, blue: 0.25)
        }
    }
}

extension QuotaStatus.Source {
    var label: String { self == .localLog ? "本地日志" : "官方接口" }
}
