import SwiftUI
import AibarCore

/// 仪表盘内容区，脱开 NavigationSplitView 单独渲染。
/// 离屏渲染量不出侧栏与工具栏，截图和视觉回归都走这条路。
struct DashboardPreview: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        DashboardContent(model: model).padding(18)
    }
}

struct DashboardView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = DashboardModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .toolbar { toolbar }
                .navigationTitle(model.tab.title)
        }
        .frame(minWidth: 880, minHeight: 560)
        .raisesAppWindow(WindowID.dashboard)
        .task {
            model.enabledProviders = Provider.allCases.filter { app.isProviderEnabled($0) }
            if let e = app.engine { model.attach(e) }
        }
        .onChange(of: model.range) { _, _ in model.reload() }
        .onChange(of: model.tab) { _, _ in model.reload() }
        .onChange(of: model.providerFilter) { _, _ in model.reload() }
        .onChange(of: model.search) { _, _ in model.reload() }
        .onChange(of: app.providerEnabledClaude) { _, _ in syncEnabledProviders() }
        .onChange(of: app.providerEnabledCodex) { _, _ in syncEnabledProviders() }
        .onChange(of: app.providerEnabledGrok) { _, _ in syncEnabledProviders() }
    }

    private func syncEnabledProviders() {
        let shown = Provider.allCases.filter { app.isProviderEnabled($0) }
        model.enabledProviders = shown
        if let p = model.providerFilter, !shown.contains(p) {
            model.providerFilter = nil
        }
        model.reload()
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        List(selection: $model.tab) {
            Section("分析") {
                ForEach(DashboardModel.Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon).tag(tab)
                }
            }
            Section("来源") {
                ForEach(model.enabledProviders, id: \.self) { p in
                    let bucket = model.data.byProvider.first { $0.key == p.rawValue }
                    HStack {
                        Circle().fill(p.tint).frame(width: 7, height: 7)
                        Text(p.displayName).font(.system(size: 12))
                        Spacer()
                        Text(Fmt.tokens(bucket?.tokens ?? 0))
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 168, ideal: 178, max: 220)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("", selection: $model.range) {
                ForEach(DateRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("", selection: $model.metric) {
                ForEach(DashboardModel.Metric.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 128)
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var detail: some View {
        if let error = model.error {
            ContentUnavailableView("读取数据失败", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            ScrollView {
                DashboardContent(model: model).padding(18)
            }
            .overlay(alignment: .top) {
                if model.loading {
                    ProgressView().controlSize(.small).padding(6)
                }
            }
        }
    }

}

/// 内容区。和 DashboardView 拆开，好让离屏渲染直接用。
struct DashboardContent: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.tab {
            case .overview: overview
            case .sessions: sessionList
            case .projects: ranking(model.data.byProject, title: "项目")
            case .models: ranking(model.data.byModel, title: "模型")
            }
        }
    }

    // MARK: - 仪表盘

    private var overview: some View {
        let d = model.data
        return VStack(alignment: .leading, spacing: 16) {
            statRow(d)

            Card("每日用量", subtitle: d.range.label) {
                if d.series.allSatisfy({ $0.total == 0 }) {
                    emptyHint("这段时间没有用量")
                } else {
                    TrendChart(series: d.series, metric: model.metric).frame(height: 200)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Card("模型分布") {
                    RankBars(buckets: d.byModel, model: model, limit: 6) { b in
                        modelTint(b.key)
                    }
                }
                Card("Top 项目") {
                    RankBars(buckets: d.byProject, model: model, limit: 6) { _ in .rankBar }
                }
            }

            if !d.byBranch.isEmpty, d.byBranch.count > 1 {
                Card("按 Git 分支") {
                    RankBars(buckets: d.byBranch, model: model, limit: 5) { _ in .rankBar }
                }
            }

            if !d.unpricedModels.isEmpty { unpricedNotice(d) }
        }
    }

    private func statRow(_ d: DashboardData) -> some View {
        HStack(spacing: 12) {
            StatTile(label: "总 Token", value: Fmt.tokens(d.totals.tokens),
                     detail: L("%lld 次请求 · %lld 个会话", d.totals.events, d.totals.sessions),
                     delta: d.hasComparison
                        ? Fmt.delta(Double(d.totals.tokens), Double(d.previousTotals.tokens)) : nil)
            StatTile(label: "等价 API 成本", value: Fmt.cost(d.totals.cost),
                     detail: L("估算 · 价格表 %@", PricingTable.builtin.version),
                     delta: d.hasComparison ? Fmt.delta(d.totals.cost, d.previousTotals.cost) : nil)
            StatTile(label: "缓存命中率",
                     value: Fmt.percent(d.totals.cacheHitRate * 100, digits: 1),
                     detail: L("%@ / %@", Fmt.tokens(d.totals.cacheRead),
                                Fmt.tokens(d.totals.input + d.totals.cacheRead + d.totals.cacheWrite)),
                     tint: .green)
            StatTile(label: "输出 Token", value: Fmt.tokens(d.totals.output),
                     detail: L("占比 %@", Fmt.percent(Double(d.totals.output) / Double(max(1, d.totals.tokens)) * 100, digits: 2)))
        }
    }

    private func ranking(_ buckets: [Reports.Bucket], title: String) -> some View {
        Card(LocalizedStringKey(L("按%@排行", title)), subtitle: L("%lld 项", buckets.count)) {
            if buckets.isEmpty {
                emptyHint("这段时间没有用量")
            } else {
                RankBars(buckets: buckets, model: model, limit: 25) { b in
                    title == "模型" ? modelTint(b.key) : .rankBar
                }
            }
        }
    }

    // MARK: - 会话明细

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("搜索项目 / 模型 / 会话 ID", text: $model.search)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                Picker("", selection: $model.providerFilter) {
                    Text("全部来源").tag(Provider?.none)
                    ForEach(model.enabledProviders, id: \.self) { Text($0.displayName).tag(Provider?.some($0)) }
                }
                .frame(width: 140)
                Spacer()
                Text(L("%lld 个会话", model.sessions.count))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if model.sessions.isEmpty {
                emptyHint("没有匹配的会话")
            } else {
                Table(model.sessions, selection: Binding(
                    get: { model.selectedSession.map { Set([$0.id]) } ?? [] },
                    set: { ids in
                        model.select(model.sessions.first { ids.contains($0.id) })
                    })) {
                    TableColumn("开始") { s in
                        Text(s.started.formatted(.dateTime.month().day().hour().minute()))
                            .font(.system(size: 11)).monospacedDigit()
                    }.width(min: 96, ideal: 108)
                    TableColumn("来源") { s in
                        HStack(spacing: 5) {
                            Circle().fill(s.provider.tint).frame(width: 6, height: 6)
                            Text(s.provider.displayName).font(.system(size: 11))
                        }
                    }.width(min: 92, ideal: 104)
                    TableColumn("项目") { s in
                        Text(s.project).font(.system(size: 11)).help(s.projectPath ?? s.project)
                    }.width(min: 110, ideal: 150)
                    TableColumn("模型") { s in
                        Text(s.model).font(.system(size: 11)).foregroundStyle(.secondary)
                    }.width(min: 100, ideal: 130)
                    TableColumn("Token") { s in
                        Text(Fmt.tokens(s.tokens)).font(.system(size: 11)).monospacedDigit()
                    }.width(min: 62, ideal: 70)
                    TableColumn("缓存") { s in
                        Text(Fmt.percent(s.cacheHitRate * 100)).font(.system(size: 11))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }.width(min: 50, ideal: 56)
                    TableColumn("成本") { s in
                        Text(Fmt.cost(s.cost)).font(.system(size: 11)).monospacedDigit()
                    }.width(min: 64, ideal: 74)
                    TableColumn("轮次") { s in
                        Text("\(s.turns)").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }.width(min: 44, ideal: 50)
                    TableColumn("时长") { s in
                        // 单轮会话跨度为 0，写“—”比“0 秒”诚实
                        Text(s.duration < 60 ? "—" : Fmt.duration(s.duration))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }.width(min: 76, ideal: 90)
                }
                .frame(minHeight: 320)

                if let s = model.selectedSession { sessionDetail(s) }
            }
        }
    }

    private func sessionDetail(_ s: SessionDetail) -> some View {
        Card("\(s.project) · \(s.model)", subtitle: s.sessionId) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    breakdown("输入", s.input, .accentColor)
                    breakdown("输出", s.output, .orange)
                    breakdown("缓存读", s.cacheRead, .green)
                    breakdown("缓存写", s.cacheWrite, .purple)
                    if s.reasoning > 0 { breakdown("推理", s.reasoning, .pink) }
                    Spacer()
                    if let branch = s.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                TimelineChart(points: model.timeline)
            }
        }
    }

    private func breakdown(_ label: String, _ value: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(Fmt.tokens(value)).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
    }

    // MARK: - 零件

    private func unpricedNotice(_ d: DashboardData) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("%lld 个模型缺少定价", d.unpricedModels.count))
                    .font(.system(size: 11.5, weight: .medium))
                Text(L("%@ 未计入上方成本，成本列显示为 —：%@", Fmt.tokens(d.unpricedTokens),
                     d.unpricedModels.joined(separator: ", ")))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.08)))
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 90)
    }

    /// 模型条的配色跟随其所属 Provider，和图表图例一致
    private func modelTint(_ name: String) -> Color {
        if name.hasPrefix("claude") { return Provider.claudeCode.tint }
        if name.hasPrefix("grok") { return Provider.grok.tint }
        return Provider.codex.tint
    }
}

// MARK: - 通用零件

struct StatTile: View {
    let label: LocalizedStringKey
    let value: String
    var detail: String?
    var delta: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(tint)
                if let delta {
                    Text(delta).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}

struct Card<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: String?
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.22)))
    }
}
