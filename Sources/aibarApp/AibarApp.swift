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

        Window("aibar", id: WindowID.dashboard) {
            DashboardView().environmentObject(model)
        }
        .defaultSize(width: 1040, height: 660)
        .commands { SidebarCommands() }

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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let title = model.menuBarTitle {
                Text(title).monospacedDigit()
            }
        }
        .foregroundStyle(tint)
        .task {
            await model.start()
            // `open -a aibar --args --dashboard` 直接进仪表盘。
            // 也让主窗口这条链路能被脚本验证，不必去合成点击真实菜单栏。
            //
            // 必须让出一轮 runloop：MenuBarExtra 的 label 在 Window scene 注册完成前
            // 就已经渲染，此时 openWindow 找不到目标 id，会静默失败。
            if CommandLine.arguments.contains("--dashboard") {
                try? await Task.sleep(for: .milliseconds(400))
                openWindow(id: WindowID.dashboard)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
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
