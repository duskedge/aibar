import SwiftUI
import AppKit
import AibarCore

// 离屏渲染快捷面板成 PNG。
// 用来生成 README 截图、做视觉回归 —— 不需要真的点开菜单栏，
// 也就不会去干扰用户正在用的桌面。

@MainActor
func writePNG(_ view: some View, to path: String, scale: CGFloat = 2) throws -> NSSize {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { throw NSError(domain: "aibar", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "渲染失败: \(path)"]) }
    try png.write(to: URL(fileURLWithPath: path))
    return image.size
}

@MainActor
func render() async throws {
    let args = CommandLine.arguments.dropFirst()

    // 位置参数与 --flag 必须分开收，否则 `shot out.png --lang en` 会把
    // "--lang" 当成数据库路径打开一个空库 —— 踩过一次。
    var positional: [String] = []
    var flags: [String: String] = [:]
    var it = args.makeIterator()
    while let a = it.next() {
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if key == "offline" { flags[key] = "true" } else { flags[key] = it.next() ?? "" }
        } else if a.hasPrefix("-") {
            // 单横线的留给 Foundation 的 NSArgumentDomain，比如
            //   aibar-shot out.png -AppleLanguages "(en)"
            // 语言必须走这条路：运行时再写 UserDefaults 已经晚了，
            // Bundle 在第一次本地化查找时就把语言定死了。
            _ = it.next()
        } else {
            positional.append(a)
        }
    }

    // 自检：确认本地化资源真的能被找到。
    // 通过符号链接调用本工具会让 Bundle.main 指向链接所在目录，
    // .lproj 找不到、本地化静默回落成中文 —— 踩过一次，所以留着这个开关。
    if flags["diag"] != nil {
        let b = Bundle.main
        print("bundlePath:            \(b.bundlePath)")
        print("bundleIdentifier:      \(b.bundleIdentifier ?? "nil")")
        print("localizations:         \(b.localizations)")
        print("preferredLocalizations:\(b.preferredLocalizations)")
        print("AppleLanguages:        \(UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? [])")
        print("查找 今日 →            \(L("今日"))")
        print("查找 %lld 个会话 →     \(L("%lld 个会话", 3))")
        if let path = b.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") {
            print("en.strings 路径:       \(path)")
        } else { print("en.strings 路径:       未找到") }
        return
    }

    let out = positional.first ?? "panel.png"
    let dbPath = positional.count > 1 ? positional[1] : UsageStore.defaultPath

    let store = try UsageStore(path: dbPath)
    let reports = Reports(store: store)
    var snapshot = try reports.snapshot()

    // 除非 --offline，否则拉一次 L2，让截图反映真实状态而不是半截空环
    if flags["offline"] == nil {
        let service = LiveQuotaService(config: .init(offline: false, enabled: [.claudeCode]))
        let live = await service.refresh(force: true)
        snapshot.liveQuotas = live.quotas
        snapshot.quotaFailures = live.failures
        snapshot.liveFetchedAt = live.fetchedAt
    }

    let model = AppModel.preview(snapshot: snapshot)
    let view = PopoverView(scrollable: false)
        .environmentObject(model)
        .frame(width: 352)
        .background(Color(nsColor: .windowBackgroundColor))

    let size = try writePNG(view, to: out)
    print("✓ \(out)  \(Int(size.width))×\(Int(size.height))pt")

    // 仪表盘：不走 NavigationSplitView（离屏渲染量不出侧栏），
    // 直接渲染内容区，用于生成截图与视觉回归
    let dash = DashboardModel.preview(
        data: try reports.dashboard(range: .month),
        sessions: try reports.sessions(range: .month, provider: nil, search: nil))
    let dashOut = (out as NSString).deletingLastPathComponent + "/dashboard.png"
    let dashSize = try writePNG(
        DashboardPreview().environmentObject(dash)
            .frame(width: 900)
            .background(Color(nsColor: .windowBackgroundColor)),
        to: dashOut)
    print("✓ \(dashOut)  \(Int(dashSize.width))×\(Int(dashSize.height))pt")
    print("  快照：今日 \(Fmt.tokens(snapshot.today.tokens)) / \(Fmt.cost(snapshot.today.cost))，"
          + "\(snapshot.quotas.count) 条额度，\(snapshot.recentSessions.count) 个会话")
}

do { try await render() }
catch { FileHandle.standardError.write(Data("错误: \(error)\n".utf8)); exit(1) }
