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
func render() throws {
    let args = CommandLine.arguments
    let out = args.count > 1 ? args[1] : "panel.png"
    let dbPath = args.count > 2 ? args[2] : UsageStore.defaultPath

    let store = try UsageStore(path: dbPath)
    let reports = Reports(store: store)
    let snapshot = try reports.snapshot()

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

do { try MainActor.assumeIsolated { try render() } }
catch { FileHandle.standardError.write(Data("错误: \(error)\n".utf8)); exit(1) }
