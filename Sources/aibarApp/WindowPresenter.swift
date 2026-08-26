import SwiftUI
import AppKit

/// LSUIElement 菜单栏应用的窗口提升。
///
/// `openWindow` + `NSApp.activate` 不够：设置经常开在已经打开的主窗口后面，
/// 或者开在别的应用后面，看起来就像按钮点了没反应。
/// 打开时先切成普通应用、再把目标窗口 `orderFrontRegardless`。
@MainActor
enum WindowPresenter {
    static func identifier(for id: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("aibar.window.\(id)")
    }

    static func open(_ id: String, using openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = window(for: id) {
            raise(existing)
            return
        }
        openWindow(id: id)
        scheduleRaise(id: id, remaining: 25)
    }

    static func window(for id: String) -> NSWindow? {
        let key = identifier(for: id)
        return NSApp.windows.first { $0.identifier == key }
    }

    static func raise(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    static func scheduleRaise(id: String, remaining: Int) {
        guard remaining > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            if let window = window(for: id) {
                raise(window)
            } else {
                scheduleRaise(id: id, remaining: remaining - 1)
            }
        }
    }

    /// 设置 / 主窗口都关了，回到纯菜单栏，不进 Dock。
    static func restoreAccessoryIfIdle() {
        let open = NSApp.windows.contains {
            $0.isVisible && ($0.identifier?.rawValue.hasPrefix("aibar.window.") ?? false)
        }
        if !open {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

extension View {
    func raisesAppWindow(_ id: String) -> some View {
        background(WindowRaiserView(id: id))
    }
}

private struct WindowRaiserView: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> WindowRaiserNSView {
        let view = WindowRaiserNSView()
        view.windowId = id
        return view
    }
    func updateNSView(_ nsView: WindowRaiserNSView, context: Context) {
        nsView.windowId = id
    }
}

final class WindowRaiserNSView: NSView {
    var windowId = ""
    private var closeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.identifier = WindowPresenter.identifier(for: windowId)
        WindowPresenter.raise(window)
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in WindowPresenter.restoreAccessoryIfIdle() }
        }
    }
}
