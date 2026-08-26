import SwiftUI
import AibarCore

@main
struct AibarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

/// 菜单栏上的那一小块。
///
/// 图标用 SF Symbol 的模板图，自动跟随浅色 / 深色菜单栏；
/// 只有进入告警阈值才上色，平时保持系统默认外观 —— 常驻图标不该一直抢注意力。
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let title = model.menuBarTitle {
                Text(title).monospacedDigit()
            }
        }
        .foregroundStyle(tint)
        .task { await model.start() }
    }

    private var symbol: String {
        switch model.quotaLevel {
        case .normal: "gauge.with.needle"
        case .warning: "gauge.with.needle.fill"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch model.quotaLevel {
        case .normal: .primary
        case .warning, .critical: model.quotaLevel.color
        }
    }
}
