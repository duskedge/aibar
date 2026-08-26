import SwiftUI
import AibarCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            general.tabItem { Label("通用", systemImage: "gearshape") }
            budgets.tabItem { Label("预算", systemImage: "dollarsign.circle") }
            network.tabItem { Label("网络", systemImage: "network") }
            activity.tabItem { Label("网络活动", systemImage: "list.bullet.rectangle") }
            dataSources.tabItem { Label("数据源", systemImage: "internaldrive") }
            about.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
        .raisesAppWindow(WindowID.settings)
    }

    private var general: some View {
        Form {
            Section("菜单栏") {
                Picker("显示内容", selection: $model.display) {
                    ForEach(MenuBarDisplay.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(displayHint)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.display == .quota {
                    Picker("显示哪一家", selection: Binding(
                        get: { model.menuBarTarget },
                        set: { model.menuBarTarget = $0 })) {
                        ForEach(MenuBarTarget.allCases, id: \.self) { target in
                            HStack {
                                if case .provider(let p) = target {
                                    Circle().fill(p.tint).frame(width: 6, height: 6)
                                }
                                Text(target.label)
                            }.tag(target)
                        }
                    }
                    Text(targetHint)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker("显示哪个窗口", selection: Binding(
                        get: { model.menuBarWindow },
                        set: { model.menuBarWindow = $0 })) {
                        ForEach(MenuBarWindow.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text("一家可能同时有多个额度窗口（如 Claude 的 5 小时与 7 天）。")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("显示窗口名（7d）", isOn: $model.menuBarShowWindowName)
                    Toggle("显示重置倒计时（6d21h）", isOn: $model.menuBarShowReset)
                    Text("菜单栏空间有限，两项默认都关闭，只显示一个百分比。")
                        .font(.caption).foregroundStyle(.secondary)

                    LabeledContent("预览") {
                        HStack(spacing: 4) {
                            Image(systemName: "gauge.with.needle").font(.system(size: 11))
                            Text(model.menuBarTitle ?? "").monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                    }
                }
            }

            Section("额度告警") {
                HStack {
                    Text("警告").font(.caption).frame(width: 32, alignment: .leading)
                    Slider(value: $model.warnThreshold, in: 50...95, step: 5)
                    Text(Fmt.percent(model.warnThreshold)).font(.caption)
                        .monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                HStack {
                    Text("严重").font(.caption).frame(width: 32, alignment: .leading)
                    Slider(value: $model.critThreshold, in: 60...99, step: 1)
                    Text(Fmt.percent(model.critThreshold)).font(.caption)
                        .monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                Text("图标在警告线转琥珀、严重线转红。判断依据是**菜单栏当前显示的那条**额度 —— 显示 A 却按 B 的水位报警会让人误判。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var targetHint: String {
        switch model.menuBarTarget {
        case .tightest:
            "自动显示三家里用量最高的一条 —— 常驻图标该主动告诉你哪里快撑不住了。"
        case .provider(let p):
            LiveQuotaService.supportsLiveQuota(p) || p == .codex
                ? "固定显示 \(p.displayName) 的额度。"
                : "\(p.displayName) 没有额度来源，菜单栏会退回显示今日 Token。"
        }
    }

    private var displayHint: String {
        switch model.display {
        case .quota: "显示三家里最紧张的一家。目前只有 Codex 在本地日志中回传官方额度；Claude 与 Grok 需要官方接口查询（计划于 M4）。"
        case .cost: "今日等价 API 成本。订阅制下这笔钱并未真实支出，它量化的是订阅的价值。"
        case .tokens: "今日三家 token 合计。"
        case .iconOnly: "只显示图标，适合刘海屏空间紧张时。"
        }
    }

    // MARK: - 预算

    private var budgets: some View {
        Form {
            Section {
                Text("额度是厂商给的官方剩余量，aibar 只做搬运。预算是**你自己**定的花费上限，按等价 API 成本计算 —— 两者是两件事，面板上也分开显示。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Provider.allCases, id: \.self) { p in
                Section {
                    let current = model.budgets.first { $0.provider == p } ?? Budget(provider: p)
                    HStack {
                        Circle().fill(p.tint).frame(width: 7, height: 7)
                        Text(p.displayName).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("$").foregroundStyle(.secondary)
                        TextField("0 = 不启用", value: Binding(
                            get: { current.limitUSD },
                            set: { model.updateBudget(Budget(provider: p, limitUSD: $0,
                                                             window: current.window)) }),
                            format: .number)
                            .frame(width: 80).multilineTextAlignment(.trailing)
                        Picker("", selection: Binding(
                            get: { current.window },
                            set: { model.updateBudget(Budget(provider: p, limitUSD: current.limitUSD,
                                                             window: $0)) })) {
                            ForEach(Budget.Window.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .frame(width: 110).labelsHidden()
                    }
                    if let progress = model.snapshot.budget(for: p) {
                        HStack {
                            Text("当前 \(Fmt.cost(progress.spentUSD)) / \(Fmt.cost(progress.limitUSD))")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Fmt.percent(progress.usedPercent))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(model.thresholds.level(for: progress.usedPercent).color)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 网络

    private var network: some View {
        Form {
            Section {
                Toggle("离线模式", isOn: Binding(
                    get: { model.offlineMode },
                    set: { _ in model.toggleOffline() }))
                Text("开启后 aibar 一个网络请求都不发，连凭据都不会读取。用量分析、成本、按项目归因全部照常 —— Claude 的实时额度停在上次成功的结果，不再更新。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("Claude 的剩余额度每 5 分钟查一次。撞上 429 会自动拉长间隔，并继续显示上次成功的结果。Codex / Grok 的额度在本地日志里，不走网络。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Provider.allCases, id: \.self) { p in
                    HStack(alignment: .top) {
                        Circle().fill(p.tint).frame(width: 7, height: 7).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.displayName).font(.system(size: 12, weight: .medium))
                            Text(LiveQuotaService.availability(for: p))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if p == .claudeCode {
                            Toggle("", isOn: $model.liveQuotaClaude)
                                .labelsHidden()
                                .onChange(of: model.liveQuotaClaude) { _, _ in
                                    Task { await model.applyNetworkSettings() }
                                }
                                .disabled(model.offlineMode)
                        } else {
                            Text("不适用").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("实时额度查询")
            }

            Section("白名单") {
                Text("aibar 只允许访问下列域名。这是编译期常量，CI 有静态检查强制 —— 源码中出现任何其他 host 的网络调用，构建直接失败。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(NetworkGuard.allowedHosts.sorted(), id: \.self) { host in
                    Label(host, systemImage: "checkmark.shield")
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            Section {
                Toggle("额度告警通知", isOn: $model.notifyOnQuota)
                Button("重新查看首启说明") { model.wantsDisclosure = true }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 网络活动

    private var activity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本次运行的全部网络请求").font(.system(size: 12, weight: .medium))
                    Text("\(model.networkLog.count) 次 · 全部命中白名单")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新") { Task { await model.refreshNetworkLog() } }
                    .controlSize(.small)
            }

            if model.networkLog.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "network.slash").font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text(model.offlineMode ? "离线模式已开启，没有发出任何请求"
                                           : "本次运行还没有发出任何请求")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.networkLog) {
                    TableColumn("时间") { e in
                        Text(e.at.formatted(.dateTime.hour().minute().second()))
                            .font(.system(size: 11, design: .monospaced))
                    }.width(72)
                    TableColumn("域名 / 路径") { e in
                        Text(e.host + e.path)
                            .font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    }
                    TableColumn("状态") { e in
                        Text(e.status.map(String.init) ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(e.ok ? Color.green : Color.orange)
                    }.width(48)
                    TableColumn("耗时") { e in
                        Text("\(Int(e.duration * 1000))ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }.width(56)
                }
            }

            Text("这里列出的是 aibar 本次运行发出的每一个请求，凭据不会出现在其中。想自己复核可以跑：lsof -i -p $(pgrep aibar)")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .task { await model.refreshNetworkLog() }
    }

    private var dataSources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("aibar 只读取以下目录中的用量字段，不读取对话正文，全程不联网。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Provider.allCases, id: \.self) { provider in
                let paths = pathsFor(provider)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(provider.tint).frame(width: 7, height: 7)
                        Text(provider.displayName).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(paths.contains(where: { FileManager.default.fileExists(atPath: $0) })
                             ? "已找到" : "未安装")
                            .font(.caption2)
                            .foregroundStyle(paths.contains(where: { FileManager.default.fileExists(atPath: $0) })
                                             ? Color.green : Color.secondary)
                    }
                    ForEach(paths, id: \.self) { p in
                        Text(p.replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            HStack {
                Button("重建索引") { Task { await model.rebuild() } }
                    .disabled(model.isRefreshing)
                Text("完整重新解析所有日志。数据只在本机，重建不会丢失任何东西。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private func pathsFor(_ provider: Provider) -> [String] {
        let providers: [any UsageProvider] = [ClaudeCodeProvider(), CodexProvider(), GrokProvider()]
        return providers.first { $0.provider == provider }?.rootPaths.map(\.path) ?? []
    }

    private var about: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.needle").font(.system(size: 34))
            Text("aibar").font(.system(size: 17, weight: .semibold))
            Text("Claude Code / Codex / Grok 用量统计")
                .font(.caption).foregroundStyle(.secondary)

            Divider().padding(.horizontal, 60).padding(.vertical, 4)

            VStack(spacing: 3) {
                Text("成本为按公开 API 价格的估算值，非实际账单。")
                Text("价格表版本 \(PricingTable.builtin.version)")
                Text("零第三方依赖 · MIT License")
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
