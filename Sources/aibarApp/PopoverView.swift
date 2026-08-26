import SwiftUI
import AibarCore

struct PopoverView: View {
    /// 关掉滚动，让内容按自身高度铺开。
    /// ImageRenderer 在无界上下文里量不出 ScrollView 的内容高度，离屏渲染必须走这条路。
    var scrollable = true

    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            networkBar

            switch model.phase {
            case .launching, .indexing:
                indexing
            case .failed(let message):
                failure(message)
            case .ready:
                if model.snapshot.isEmpty { empty } else { content }
            }

            Divider()
            footer
        }
        .frame(width: 352)
        .background(.regularMaterial)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.quotaLevel.color == .secondary ? .primary : model.quotaLevel.color)
            Text("aibar").font(.system(size: 12, weight: .semibold))

            Spacer()

            if model.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
            } else if let last = model.lastRefresh {
                Text(Fmt.relative(last))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Button { Task { await model.refresh(force: true) } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(model.isRefreshing)
            .help("立即刷新")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// 连接状态 + 一键离线。
    ///
    /// 默认联网就意味着**关掉它的入口必须比打开更容易找到**，
    /// 所以这一行常驻面板顶部，而不是埋进设置页第三个标签。
    private var networkBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(networkDotColor)
                .frame(width: 6, height: 6)
            Text(networkText)
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer()
            // 用按钮而不是 Toggle：面板只有 352pt 宽，开关控件太占地方，
            // 而且按钮能把动作写清楚（"切到离线" 比一个开关更不容易点错）。
            Button { model.toggleOffline() } label: {
                Text(model.offlineMode ? "恢复联网" : "切到离线")
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary.opacity(0.8)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35)))
        .padding(.horizontal, 14).padding(.top, 8)
    }

    private var networkDotColor: Color {
        if model.offlineMode { return .secondary }
        if !model.snapshot.quotaFailures.isEmpty { return .orange }
        return .green
    }

    private var networkText: String {
        if model.offlineMode { return "离线模式 · 仅本地数据" }
        let live = model.snapshot.liveQuotas.count
        if live > 0 { return "已连接 · \(live) 条实时额度" }
        if let why = model.snapshot.quotaFailures.values.first {
            return why.contains("429") ? "官方接口限流中，稍后自动重试" : "官方接口未连接"
        }
        return "已连接"
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if scrollable {
            // ScrollView 在 MenuBarExtra 里**没有固有高度**，只写 maxHeight
            // 会让它直接塌成 0 —— 面板就只剩头尾两行。
            // 所以先量出内容高度，再据此定框，超过上限才真的滚动。
            ScrollView {
                sections.background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    })
            }
            .frame(height: min(max(contentHeight, 160), Self.maxPanelHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .scrollDisabled(contentHeight <= Self.maxPanelHeight)
        } else {
            sections
        }
    }

    /// 面板最高多少。再高就超出多数笔记本屏幕了。
    static let maxPanelHeight: CGFloat = 620

    private var sections: some View {
        VStack(spacing: 0) {
            todaySection
            Divider().padding(.horizontal, 14)
            providerSection
            Divider().padding(.horizontal, 14)
            quotaSection
            if !model.snapshot.budgets.isEmpty {
                Divider().padding(.horizontal, 14)
                budgetSection
            }
            if !model.snapshot.recentSessions.isEmpty {
                Divider().padding(.horizontal, 14)
                sessionSection
            }
            if model.snapshot.rateLimits.count > 0 {
                Divider().padding(.horizontal, 14)
                rateLimitSection
            }
            if !model.snapshot.unpricedModels.isEmpty {
                Divider().padding(.horizontal, 14)
                unpricedNotice
            }
        }
    }

    private var todaySection: some View {
        let s = model.snapshot
        return VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "今日", trailing: Date().formatted(.dateTime.month().day()))

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(Fmt.cost(s.today.cost))
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Fmt.tokens(s.today.tokens)) tokens")
                        .font(.system(size: 11)).monospacedDigit()
                    Text("\(s.today.sessions) 个会话 · 缓存命中 \(Fmt.percent(s.today.cacheHitRate * 100))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let delta = Fmt.delta(s.today.cost, s.yesterday.cost) {
                Text("\(delta)　对比昨日 \(Fmt.cost(s.yesterday.cost))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }

            DailyChart(points: s.dailySeries).padding(.top, 3)
            Text("近 14 天")
                .font(.system(size: 9)).foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var providerSection: some View {
        let stats = model.snapshot.todayByProvider
        let maxTokens = max(1, stats.map(\.tokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "按 Provider")
            ForEach(stats) { stat in
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(stat.tokens > 0 ? stat.provider.tint : Color.secondary.opacity(0.25))
                            .frame(width: 7, height: 7)
                        Text(stat.provider.displayName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(stat.tokens > 0 ? .primary : .secondary)
                        Spacer()
                        // 零用量的一家不隐藏 —— 空态可见，用户才知道数据是全的
                        if stat.tokens == 0 {
                            Text("今日无用量").font(.system(size: 10)).foregroundStyle(.tertiary)
                        } else {
                            Text(Fmt.tokens(stat.tokens))
                                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                            Text(Fmt.cost(stat.cost))
                                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                    if stat.tokens > 0 {
                        MiniBar(fraction: Double(stat.tokens) / Double(maxTokens), tint: stat.provider.tint)
                            .padding(.leading, 15)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: "订阅额度",
                         trailing: model.snapshot.liveFetchedAt.map { Fmt.relative($0) })
            ForEach(Provider.allCases, id: \.self) { provider in
                let rows = model.snapshot.quotas(for: provider)
                if rows.isEmpty {
                    unavailableRow(provider)
                } else {
                    providerQuota(provider, rows)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    /// 一家可能有多个窗口（Claude 的 5 小时 + 7 天、Codex 的 5 小时 + 7 天）。
    /// 大环画最紧张的那个，其余的用小条列在下面 —— 否则面板会被环填满。
    private func providerQuota(_ provider: Provider, _ rows: [QuotaStatus]) -> some View {
        let tightest = rows.max { $0.usedPercent < $1.usedPercent } ?? rows[0]
        let others = rows.filter { $0.windowMinutes != tightest.windowMinutes }
        let level = model.thresholds.level(for: tightest.usedPercent)
        return HStack(alignment: .top, spacing: 12) {
            QuotaRing(percent: tightest.usedPercent,
                      tint: level == .normal ? provider.tint : level.color)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(provider.displayName).font(.system(size: 11.5, weight: .medium))
                    if let plan = tightest.planType {
                        Text(plan.uppercased())
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(tightest.windowDescription
                     + (tightest.timeUntilReset.map { " · \(Fmt.duration($0))后重置" } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()

                ForEach(others, id: \.windowMinutes) { q in
                    HStack(spacing: 5) {
                        Text(q.windowDescription).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        Text(Fmt.percent(q.usedPercent))
                            .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                sourceTag(tightest)
            }
            Spacer()
        }
    }

    /// 数据来自哪、有多新，必须写出来。
    /// 日志型额度只在跑对话时更新，太旧的不能装作实时。
    private func sourceTag(_ q: QuotaStatus) -> some View {
        HStack(spacing: 3) {
            Image(systemName: q.source == .localLog ? "internaldrive" : "arrow.triangle.2.circlepath")
                .font(.system(size: 8))
            Text(q.isStale()
                 ? "\(q.source.label) · \(Fmt.relative(q.observedAt))数据"
                 : (q.source == .localLog ? "本地日志 · 无需联网" : "官方接口 · 刚刚"))
        }
        .font(.system(size: 9.5))
        .foregroundStyle(q.isStale() ? Color.secondary : Color.green.opacity(0.85))
    }

    private func unavailableRow(_ provider: Provider) -> some View {
        HStack(alignment: .top, spacing: 12) {
            EmptyRing()
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                // 失败时给出原因，不能只留个空环让用户猜
                if let why = model.snapshot.quotaFailures[provider] {
                    // 429 是接口自己在限流，不是配置出错，得说清楚免得用户去乱改设置
                    let isRateLimited = why.contains("429")
                    Text(isRateLimited ? "接口限流中" : "未连接")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text(isRateLimited ? "5 分钟后自动重试，不影响本地用量统计" : why)
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(2)
                } else if model.offlineMode, LiveQuotaService.supportsLiveQuota(provider) {
                    Text("离线模式已开启").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text("关闭离线即可查询实时额度")
                        .font(.system(size: 9.5)).foregroundStyle(.quaternary)
                } else {
                    Text(LiveQuotaService.availability(for: provider))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    /// 预算区。
    ///
    /// 和额度区刻意长得不一样：环是分段虚线、标题写「花费预算」、
    /// 副标题注明「你自设 · 按等价 API 成本」。
    /// 官方额度和自算花费混在一起会让人以为后者也是厂商给的。
    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "花费预算", trailing: "你自设 · 按等价成本")
            ForEach(model.snapshot.budgets) { b in
                HStack(spacing: 12) {
                    BudgetRing(percent: b.usedPercent,
                               tint: model.thresholds.level(for: b.usedPercent) == .normal
                                     ? b.provider.tint : model.thresholds.level(for: b.usedPercent).color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.provider.displayName).font(.system(size: 11.5, weight: .medium))
                        Text("\(Fmt.cost(b.spentUSD)) / \(Fmt.cost(b.limitUSD)) · \(b.window.label)")
                            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        // 缺定价意味着进度被低估，不说出来等于给了个偏低的假象
                        if b.hasUnpricedUsage {
                            Text("含缺定价模型，实际花费更高")
                                .font(.system(size: 9.5)).foregroundStyle(.orange)
                        } else {
                            Text("剩余 \(Fmt.cost(b.remainingUSD))")
                                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: "最近会话")
            ForEach(model.snapshot.recentSessions) { row in
                HStack(spacing: 7) {
                    Circle().fill(row.provider.tint).frame(width: 6, height: 6)
                    Text(row.project).font(.system(size: 11)).lineLimit(1)
                    Text(row.model).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.tokens(row.tokens))
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    Text(Fmt.relative(row.lastActive))
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var rateLimitSection: some View {
        let rl = model.snapshot.rateLimits
        return VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "限流", trailing: "近 7 天")
            HStack(spacing: 7) {
                Circle().fill(Color(red: 0.80, green: 0.28, blue: 0.25)).frame(width: 6, height: 6)
                Text("被限流 \(rl.count) 次").font(.system(size: 11))
                Spacer()
                if let last = rl.last {
                    Text("最近 \(Fmt.relative(last))")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
            if let msg = rl.messages.first {
                Text(msg).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    /// 缺定价必须显式说出来。静默按 0 计会让用户以为自己没花钱。
    private var unpricedNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.snapshot.unpricedModels.count) 个模型缺少定价")
                    .font(.system(size: 10, weight: .medium))
                Text("\(Fmt.tokens(model.snapshot.unpricedTokens)) 未计入成本：\(model.snapshot.unpricedModels.joined(separator: ", "))")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // MARK: - 其他状态

    private var indexingMessage: String {
        if case .indexing(let text) = model.phase { return text }
        return "正在启动…"
    }

    private var indexing: some View {
        VStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(indexingMessage)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("首次索引本机会话日志，只跑一次")
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var empty: some View {
        VStack(spacing: 7) {
            Image(systemName: "tray").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text("还没有用量数据").font(.system(size: 12, weight: .medium))
            Text("跑一次 Claude Code、Codex 或 Grok 之后会自动出现")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 34).padding(.horizontal, 24)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(.orange)
            Text("读取数据失败").font(.system(size: 12, weight: .medium))
            Text(message).font(.system(size: 9.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(4)
            PanelButton(title: "重建索引") { Task { await model.rebuild() } }
                .frame(width: 100)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 26).padding(.horizontal, 20)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 6) {
            PanelButton(title: "主窗口", systemImage: "square.grid.2x2", prominent: true) {
                openWindow(id: WindowID.dashboard)
                // LSUIElement 应用默认不抢焦点，不激活的话窗口会开在后面
                NSApp.activate(ignoringOtherApps: true)
            }
            PanelButton(title: "设置", systemImage: "gearshape") { openSettings() }
            PanelButton(title: "退出", systemImage: "power") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}


/// 量内容高度用。
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
