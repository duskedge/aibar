import SwiftUI
import AibarCore

enum WindowID {
    static let dashboard = "dashboard"
}

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

extension Color {
    /// 单序列排行条用的中性色。
    /// 三家的品牌色是分类编码，不该被排行榜借走 —— 否则"蓝色"在图表里
    /// 指 Grok，在排行里又指"随便某个项目"，读者得反复切换语境。
    static let rankBar = Color.secondary.opacity(0.55)
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
