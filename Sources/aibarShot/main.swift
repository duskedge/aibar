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

    // README 里的截图必须用合成数据。
    // 用维护者的真实库出图会把项目名、花费、套餐等级一起发到公开仓库 ——
    // 那些往往是公司内部信息。合成数据还有个好处：任何贡献者都能复现同一张图。
    let store = flags["demo"] != nil ? try demoStore() : try UsageStore(path: dbPath)
    let reports = Reports(store: store)
    var snapshot = try reports.snapshot()

    if flags["demo"] != nil {
        snapshot.liveQuotas = demoQuotas()
        snapshot.liveFetchedAt = .now
        let model = AppModel.preview(snapshot: snapshot)
        _ = try writePNG(PopoverView(scrollable: false).environmentObject(model)
            .frame(width: 352).background(Color(nsColor: .windowBackgroundColor)), to: out)
        print("✓ \(out)")
        let dash = DashboardModel.preview(
            data: try reports.dashboard(range: .month),
            sessions: try reports.sessions(range: .month, provider: nil, search: nil))
        let dashOut = (out as NSString).deletingLastPathComponent + "/dashboard.png"
        _ = try writePNG(DashboardPreview().environmentObject(dash)
            .frame(width: 900).background(Color(nsColor: .windowBackgroundColor)), to: dashOut)
        print("✓ \(dashOut)")
        return
    }

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


// MARK: - 演示数据

/// 造一份合成用量库。数字是编的，但形状照着真实分布来 ——
/// 缓存命中率高得离谱、输出 token 占比极低、成本集中在少数几天，
/// 这些都是真实使用中最显眼的特征，截图要能反映出来。
@MainActor
func demoStore() throws -> UsageStore {
    let store = try UsageStore(path: ":memory:")
    let cal = Calendar.current
    let today = cal.startOfDay(for: .now)

    struct Plan { let project: String; let branch: String?; let provider: Provider; let model: String }
    let plans: [Plan] = [
        .init(project: "/Users/dev/code/notes-app", branch: "main", provider: .claudeCode, model: "claude-opus-5"),
        .init(project: "/Users/dev/code/api-gateway", branch: "main", provider: .claudeCode, model: "claude-sonnet-5"),
        .init(project: "/Users/dev/code/web-console", branch: "feature/charts", provider: .codex, model: "gpt-5.6-sol"),
        .init(project: "/Users/dev/code/data-pipeline", branch: "dev", provider: .codex, model: "gpt-5.5"),
        .init(project: "/Users/dev/code/cli-tools", branch: nil, provider: .grok, model: "grok-4.6"),
    ]

    var events: [UsageEvent] = []
    var seed: UInt64 = 20260826
    func next(_ upper: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(max(1, upper)))
    }

    for dayOffset in 0..<30 {
        guard let day = cal.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
        let busy = next(10) > 3
        for (i, plan) in plans.enumerated() where busy || i < 2 {
            let turns = 3 + next(12)
            for turn in 0..<turns {
                let ts = day.addingTimeInterval(Double(9 * 3600 + turn * 420 + next(600)))
                // 真实分布：缓存读远大于其他，输出很小
                let cacheRead = 40_000 + next(360_000)
                let write = next(40_000)
                let output = 120 + next(900)
                events.append(UsageEvent(
                    id: "demo-\(dayOffset)-\(i)-\(turn)",
                    provider: plan.provider,
                    timestamp: ts,
                    sessionId: "demo-session-\(dayOffset)-\(i)",
                    projectPath: plan.project,
                    gitBranch: plan.branch,
                    model: plan.model,
                    inputTokens: 200 + next(3_000),
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheWrite5mTokens: write,
                    reasoningTokens: next(300),
                    officialCostUSD: plan.provider == .grok
                        ? Double(cacheRead + output) * 2.2e-7 : nil))
            }
        }
    }
    _ = try store.insert(events: events)

    // 一条限流事件，让面板的限流区也有内容
    try store.insert(rateLimits: [RateLimitEvent(
        id: "demo-rl", provider: .claudeCode,
        timestamp: today.addingTimeInterval(-2 * 86400 + 64_800),
        sessionId: "demo-session-2-0",
        message: "You've hit your session limit · resets 6:50pm")])

    // Codex 的额度来自本地日志，所以进库
    try store.insert(quota: QuotaStatus(
        provider: .codex, usedPercent: 41, windowMinutes: 300,
        resetsAt: .now.addingTimeInterval(2 * 3600 + 900), planType: "plus",
        observedAt: .now.addingTimeInterval(-600), source: .localLog))
    try store.insert(quota: QuotaStatus(
        provider: .codex, usedPercent: 12, windowMinutes: 10080,
        resetsAt: .now.addingTimeInterval(5 * 86400), planType: "plus",
        observedAt: .now.addingTimeInterval(-600), source: .localLog))
    try store.insert(quota: QuotaStatus(
        provider: .grok, usedPercent: 23, windowMinutes: 10080,
        resetsAt: .now.addingTimeInterval(6 * 86400), planType: "SuperGrok",
        observedAt: .now.addingTimeInterval(-300), source: .localLog))
    return store
}

/// Claude 的额度走接口，所以单独给，用来演示两种来源在界面上的区别。
func demoQuotas() -> [QuotaStatus] {
    [QuotaStatus(provider: .claudeCode, usedPercent: 68, windowMinutes: 300,
                 resetsAt: .now.addingTimeInterval(3 * 3600 + 1500), planType: "pro",
                 observedAt: .now, source: .officialAPI, windowLabel: L("5 小时窗口")),
     QuotaStatus(provider: .claudeCode, usedPercent: 21, windowMinutes: 10080,
                 resetsAt: .now.addingTimeInterval(5 * 86400), planType: "pro",
                 observedAt: .now, source: .officialAPI, windowLabel: L("7 天窗口"))]
}
