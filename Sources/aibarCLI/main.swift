import Foundation
import AibarCore

// M1 的验收工具：先让命令行能打出正确数字，再谈菜单栏。

struct Options {
    var command: String
    var flags: [String: String]

    static func parse(_ argv: [String]) -> Options {
        let command = argv.first.map { $0.hasPrefix("--") ? "report" : $0 } ?? "report"
        var flags: [String: String] = [:]
        var i = command == argv.first ? 1 : 0
        while i < argv.count {
            let a = argv[i]
            guard a.hasPrefix("--") else { i += 1; continue }
            let key = String(a.dropFirst(2))
            if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                flags[key] = argv[i + 1]; i += 2
            } else {
                flags[key] = "true"; i += 1
            }
        }
        return Options(command: command, flags: flags)
    }

    subscript(_ key: String) -> String? { flags[key] }
    var dbPath: String { flags["db"] ?? UsageStore.defaultPath }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("错误: " + message + "\n").utf8))
    exit(1)
}

// MARK: - 格式化

func fmtTokens(_ n: Int) -> String {
    let d = Double(n)
    return switch d {
    case 1e9...: String(format: "%.2fB", d / 1e9)
    case 1e6...: String(format: "%.1fM", d / 1e6)
    case 1e3...: String(format: "%.1fK", d / 1e3)
    default: "\(n)"
    }
}

func fmtCost(_ v: Double?) -> String {
    guard let v else { return "—" }
    return v >= 1000 ? String(format: "$%.0f", v)
         : v >= 1 ? String(format: "$%.2f", v)
         : String(format: "$%.4f", v)
}

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    // 中文按两个宽度算，否则表格会歪
    let width = s.reduce(0) { $0 + (($1.unicodeScalars.first?.value ?? 0) > 0x2E80 ? 2 : 1) }
    let gap = String(repeating: " ", count: max(0, w - width))
    return right ? gap + s : s + gap
}

func parseDuration(_ s: String) -> Date? {
    let now = Date()
    if let d = Int(s.dropLast()), let unit = s.last {
        switch unit {
        case "d": return now.addingTimeInterval(-Double(d) * 86400)
        case "h": return now.addingTimeInterval(-Double(d) * 3600)
        case "w": return now.addingTimeInterval(-Double(d) * 7 * 86400)
        default: break
        }
    }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)
}

func buildFilter(_ opts: Options) -> Reports.Filter {
    var filter = Reports.Filter()
    if let last = opts["last"] { filter.since = parseDuration(last) }
    if let since = opts["since"] { filter.since = parseDuration(since) }
    if let p = opts["provider"] {
        let names = p.split(separator: ",").map(String.init)
        filter.providers = names.compactMap { name in
            Provider.allCases.first { $0.rawValue == name || $0.displayName.lowercased() == name.lowercased() }
        }
        if filter.providers?.isEmpty == true { fail("未知的 provider: \(p)") }
    }
    return filter
}

// MARK: - 命令

func runScan(_ opts: Options) throws {
    let store = try UsageStore(path: opts.dbPath)
    if opts["rebuild"] != nil {
        print("正在清空并重建索引…")
        try store.reset()
    }
    let scanner = Scanner(store: store)
    var lastProvider: Provider?
    let summary = try scanner.scan { p in
        if p.provider != lastProvider {
            lastProvider = p.provider
            FileHandle.standardError.write(Data("\n扫描 \(p.provider.displayName) …\n".utf8))
        }
        if p.filesDone % 25 == 0 || p.filesDone == p.filesTotal {
            FileHandle.standardError.write(Data("\r  \(p.filesDone)/\(p.filesTotal) 文件, \(p.eventsInserted) 事件".utf8))
        }
    }
    FileHandle.standardError.write(Data("\n".utf8))

    print("""

    扫描完成 —— \(String(format: "%.1f", summary.duration)) 秒
      新增事件      \(summary.eventsInserted)
      限流事件      \(summary.rateLimitsInserted)
      文件          \(summary.filesScanned) 已读 / \(summary.filesSkipped) 跳过（无变化）
      读取字节      \(String(format: "%.1f MB", Double(summary.bytesRead) / 1e6))
      解析失败行    \(summary.malformedLines)
    """)
    if !summary.errors.isEmpty {
        print("\n  \(summary.errors.count) 个文件出错：")
        for e in summary.errors.prefix(5) { print("    \(e)") }
    }
}

func runReport(_ opts: Options) throws {
    let store = try UsageStore(path: opts.dbPath)
    let reports = Reports(store: store)
    let filter = buildFilter(opts)
    let totals = try reports.totals(filter: filter)

    guard totals.events > 0 else {
        print("没有数据。先跑一次 `aibar scan`。")
        return
    }

    var range = "全部时间"
    if let since = filter.since {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        range = "\(f.string(from: since)) 起"
    }

    print("""

    aibar 用量报告 · \(range)
    \(String(repeating: "─", count: 62))
      总 Token        \(pad(fmtTokens(totals.tokens), 12))  \(totals.events) 次请求 / \(totals.sessions) 个会话
      等价 API 成本   \(pad(fmtCost(totals.cost), 12))  估算 · 价格表 \(reports.pricing.version)
      缓存命中率      \(pad(String(format: "%.1f%%", totals.cacheHitRate * 100), 12))  \(fmtTokens(totals.cacheRead)) / \(fmtTokens(totals.input + totals.cacheRead + totals.cacheWrite))
      输出 Token      \(pad(fmtTokens(totals.output), 12))  占比 \(String(format: "%.2f%%", Double(totals.output) / Double(max(1, totals.tokens)) * 100))
    """)

    let dims: [Reports.Dimension] = opts["by"].map { by in
        by.split(separator: ",").compactMap { Reports.Dimension(rawValue: String($0)) }
    } ?? [.provider, .model, .project]

    for dim in dims {
        let buckets = try reports.breakdown(by: dim, filter: filter)
        guard !buckets.isEmpty else { continue }
        let title = switch dim {
        case .provider: "按 Provider"; case .model: "按模型"
        case .project: "按项目"; case .day: "按天"; case .branch: "按分支"
        }
        print("\n  \(title)")
        print("  \(String(repeating: "─", count: 60))")
        print("  \(pad("", 26))\(pad("Token", 10, right: true))\(pad("成本", 12, right: true))\(pad("会话", 8, right: true))")
        for b in buckets.prefix(Int(opts["limit"] ?? "8") ?? 8) {
            var key = b.key
            if dim == .provider, let p = Provider(rawValue: key) { key = p.displayName }
            print("  \(pad(String(key.prefix(24)), 26))\(pad(fmtTokens(b.tokens), 10, right: true))\(pad(fmtCost(b.cost), 12, right: true))\(pad("\(b.sessions)", 8, right: true))")
        }
    }

    // 额度（M1 只有 Codex 的本地日志来源）
    let quotas = try reports.latestQuota()
    if !quotas.isEmpty {
        print("\n  额度")
        print("  \(String(repeating: "─", count: 60))")
        for q in quotas {
            var line = "  \(pad(q.provider.displayName, 20))\(pad(String(format: "%.1f%%", q.usedPercent), 8, right: true))"
            let window = q.windowMinutes >= 1440
                ? "\(q.windowMinutes / 1440) 天窗口" : "\(q.windowMinutes / 60) 小时窗口"
            line += "  " + window
            if let r = q.resetsAt {
                let remaining = r.timeIntervalSinceNow
                line += remaining > 0
                    ? String(format: " · %.0f 天 %.0f 小时后重置", (remaining / 86400).rounded(.down), remaining.truncatingRemainder(dividingBy: 86400) / 3600)
                    : " · 已重置"
            }
            if let plan = q.planType { line += " · \(plan)" }
            line += "  [\(q.source == .localLog ? "本地日志" : "官方接口")]"
            print(line)
        }
    }

    // 限流洞察
    let rl = try reports.rateLimits(filter: filter)
    if rl.count > 0 {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        print("\n  限流")
        print("  \(String(repeating: "─", count: 60))")
        print("  被限流 \(rl.count) 次" + (rl.last.map { " · 最近 \(f.string(from: $0))" } ?? ""))
        if let m = rl.messages.first { print("  \(m)") }
    }

    // 价格表覆盖检查：缺定价必须显式提示，绝不静默按 0 计
    let unpriced = reports.pricing.unpricedModels(in: try reports.models())
    if !unpriced.isEmpty {
        let vol = try reports.unpricedVolume(filter: filter)
        print("\n  ⚠️  \(unpriced.count) 个模型缺少定价：\(unpriced.joined(separator: ", "))")
        print("     \(fmtTokens(vol.tokens))（\(vol.events) 次请求）未计入上方总成本，成本列显示为 —")
    }
    print("")
}

func runDoctor(_ opts: Options) throws {
    print("\naibar doctor\n\(String(repeating: "─", count: 62))")
    let fm = FileManager.default
    for provider in [ClaudeCodeProvider() as any UsageProvider, CodexProvider(), GrokProvider()] {
        let files = provider.discoverFiles()
        let bytes = files.reduce(UInt64(0)) { sum, url in
            sum + (((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0)
        }
        let mark = files.isEmpty ? "○" : "●"
        print("  \(mark) \(pad(provider.provider.displayName, 16))\(pad("\(files.count) 文件", 12, right: true))\(pad(String(format: "%.1f MB", Double(bytes) / 1e6), 12, right: true))")
        for root in provider.rootPaths {
            let exists = fm.fileExists(atPath: root.path)
            print("      \(exists ? "✓" : "✗") \(root.path)")
        }
    }
    print("\n  数据库  \(opts.dbPath)")
    if fm.fileExists(atPath: opts.dbPath),
       let size = (try? fm.attributesOfItem(atPath: opts.dbPath))?[.size] as? NSNumber {
        print("          \(String(format: "%.1f MB", size.doubleValue / 1e6))")
    } else {
        print("          尚未创建 —— 跑一次 `aibar scan`")
    }
    print("")
}

func runExport(_ opts: Options) throws {
    let store = try UsageStore(path: opts.dbPath)
    let reports = Reports(store: store)
    var range = DateRange.all
    if let r = opts["last"] {
        range = switch r {
        case "1d", "today": .today
        case "7d": .week
        case "30d": .month
        case "90d": .quarter
        default: .all
        }
    }
    let sessions = try reports.sessions(range: range, provider: nil, search: nil, limit: 10_000)
    let format = Export.Format(rawValue: opts["format"] ?? "csv") ?? .csv
    let out = opts["out"] ?? Export.suggestedFilename(range: range, format: format)

    let data = switch format {
    case .csv: Data(Export.csv(sessions).utf8)
    case .json: try Export.json(sessions, pricingVersion: reports.pricing.version)
    }
    try data.write(to: URL(fileURLWithPath: out))
    print("✓ \(out)  \(sessions.count) 个会话  \(String(format: "%.1f KB", Double(data.count) / 1024))")
    print("  不含凭据与对话正文，仅会话元信息与计数。")
}

/// L2 额度查询。同时充当端点自检：上游改了响应结构，这里第一时间能看出来。
func runQuota(_ opts: Options) async throws {
    print("\naibar quota\n\(String(repeating: "─", count: 62))")
    print("  白名单域名  \(NetworkGuard.allowedHosts.sorted().joined(separator: ", "))")
    print("")

    for provider in Provider.allCases {
        let supported = LiveQuotaService.supportsLiveQuota(provider)
        let mark = supported ? "●" : "○"
        print("  \(mark) \(pad(provider.displayName, 16))\(LiveQuotaService.availability(for: provider))")
        print("      凭据  \(Credentials.location(for: provider))"
              + (Credentials.exists(for: provider) ? "  [已登录]" : "  [未找到]"))
    }

    guard opts["fetch"] != nil else {
        print("\n  只列出配置。加 --fetch 才会真的发请求。\n")
        return
    }

    print("\n  正在查询…")
    let service = LiveQuotaService(config: .init(offline: false, enabled: [.claudeCode]))
    let result = await service.refresh(force: true)

    if result.quotas.isEmpty && result.failures.isEmpty {
        print("  没有启用任何 L2 客户端。")
    }
    for q in result.quotas {
        var line = "  \(pad(q.provider.displayName, 14))\(pad(q.windowDescription, 16))"
        line += pad(String(format: "%.1f%%", q.usedPercent), 8, right: true)
        if let r = q.resetsAt { line += "  \(Fmt.duration(r.timeIntervalSinceNow))后重置" }
        if let p = q.planType { line += "  · \(p)" }
        print(line)
    }
    for (provider, why) in result.failures {
        print("  \(pad(provider.displayName, 14))未连接：\(why)")
    }

    print("\n  网络活动")
    for entry in await NetworkGuard.RequestLog.shared.all() {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        print("    \(f.string(from: entry.at))  \(entry.host)\(entry.path)"
              + "  \(entry.status.map(String.init) ?? "—")"
              + "  \(Int(entry.duration * 1000))ms"
              + (entry.note.map { "  \($0)" } ?? ""))
    }
    print("")
}

func usage() {
    print("""

    aibar —— Claude Code / Codex / Grok 本地用量统计

    用法:
      aibar scan [--rebuild]              扫描本地日志并落库（增量）
      aibar report [选项]                 输出用量报告
      aibar doctor                        检查数据源与数据库状态
      aibar quota [--fetch]               查看 L2 额度接口配置；--fetch 才真的发请求
      aibar export [选项]                 导出会话明细
                                          --format csv|json  --out <路径>  --last 7d

    report 选项:
      --last 7d | 24h | 2w                最近一段时间
      --since 2026-08-01                  指定起始日期
      --provider claude,codex,grok        限定 Provider
      --by provider,model,project,day,branch
      --limit 8                           每个维度显示条数

    通用:
      --db <路径>                         指定数据库（默认 ~/Library/Application Support/aibar）

    """)
}

let opts = Options.parse(Array(CommandLine.arguments.dropFirst()))
do {
    switch opts.command {
    case "scan": try runScan(opts)
    case "report": try runReport(opts)
    case "doctor": try runDoctor(opts)
    // 顶层代码本身就是异步上下文，直接 await。
    // 早期版本用 DispatchSemaphore + Task 桥接，结果 Task 继承了 MainActor，
    // 而主线程正卡在 sem.wait() 上 —— 稳定死锁。
    case "quota": try await runQuota(opts)
    case "export": try runExport(opts)
    case "-h", "--help", "help": usage()
    default: fail("未知命令 '\(opts.command)'。跑 `aibar --help` 看用法。")
    }
} catch {
    fail("\(error)")
}
