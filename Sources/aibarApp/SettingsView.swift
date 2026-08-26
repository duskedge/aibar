import SwiftUI
import AibarCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            general.tabItem { Label("通用", systemImage: "gearshape") }
            dataSources.tabItem { Label("数据源", systemImage: "internaldrive") }
            about.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 440, height: 320)
    }

    private var general: some View {
        Form {
            Picker("菜单栏显示", selection: $model.display) {
                ForEach(MenuBarDisplay.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text(displayHint)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

            LabeledContent("额度告警") {
                VStack(alignment: .leading, spacing: 6) {
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
                }
            }
        }
        .formStyle(.grouped)
    }

    private var displayHint: String {
        switch model.display {
        case .quota: "显示三家里最紧张的一家。目前只有 Codex 在本地日志中回传官方额度；Claude 与 Grok 需要官方接口查询（计划于 M4）。"
        case .cost: "今日等价 API 成本。订阅制下这笔钱并未真实支出，它量化的是订阅的价值。"
        case .tokens: "今日三家 token 合计。"
        case .iconOnly: "只显示图标，适合刘海屏空间紧张时。"
        }
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
