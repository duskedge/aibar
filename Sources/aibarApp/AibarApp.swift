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

        // 披露页必须是独立窗口。
        // 早期版本把它做成挂在 MenuBarExtra 上的 sheet —— 菜单栏弹窗不支持 sheet，
        // 结果 sheet 弹不出来，还把面板内容整个挡没了。
        Window("aibar 说明", id: WindowID.disclosure) {
            DisclosureView().environmentObject(model)
        }
        .defaultSize(width: 480, height: 620)
        .windowResizability(.contentSize)

        Window("aibar", id: WindowID.dashboard) {
            DashboardView().environmentObject(model)
        }
        .defaultSize(width: 1040, height: 660)
        .commands { SidebarCommands() }

        // 设置必须做成独立窗口。Settings 场景 + openSettings() 在 LSUIElement
        // 菜单栏应用里经常是空操作：窗口要么不出现，要么开在所有窗口后面。
        Window("设置", id: WindowID.settings) {
            SettingsView().environmentObject(model)
        }
        .defaultSize(width: 520, height: 460)
        .defaultPosition(.center)
        .windowResizability(.contentSize)
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
        .onChange(of: model.wantsDisclosure) { _, wants in
            guard wants else { return }
            model.wantsDisclosure = false
            WindowPresenter.open(WindowID.disclosure, using: openWindow)
        }
        .task {
            await Notifications.requestAuthorizationIfNeeded()
            await model.start()
            // `open -a aibar --args --dashboard` 直接进仪表盘。
            // 也让主窗口这条链路能被脚本验证，不必去合成点击真实菜单栏。
            //
            // 必须让出一轮 runloop：MenuBarExtra 的 label 在 Window scene 注册完成前
            // 就已经渲染，此时 openWindow 找不到目标 id，会静默失败。
            try? await Task.sleep(for: .milliseconds(400))
            if CommandLine.arguments.contains("--dashboard") {
                WindowPresenter.open(WindowID.dashboard, using: openWindow)
            }
            // 首启披露：还没看过就主动弹出来，而不是等用户点开面板才说
            if !model.disclosureShown {
                WindowPresenter.open(WindowID.disclosure, using: openWindow)
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
