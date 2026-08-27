import SwiftUI
import AibarCore

/// 首启披露页。
///
/// 这不是一份同意书 —— 没有勾选框，「保持开启」和「切换到离线模式」两个按钮**等权并列**。
/// aibar 默认联网并读取本机凭据，用户第一次看到它时就该能做出真实选择，
/// 而不是被引导着点"下一步"。
struct DisclosureView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    layerOne
                    layerTwo
                    layerThree
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 620)
        .raisesAppWindow(WindowID.disclosure)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.needle").font(.system(size: 17))
                Text("aibar 会做这几件事").font(.system(size: 16, weight: .semibold))
            }
            Text("装上就能用，但你有权先知道它在干什么。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var layerOne: some View {
        item(tag: "L1", tint: .green, title: "读取本地会话日志") {
            VStack(alignment: .leading, spacing: 7) {
                Text("只读取下列目录中的 token 用量字段，**不读取对话正文**。全程不联网。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(dataPaths, id: \.self) { path in
                    Text(path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text("这一层不可关闭 —— 它就是 aibar 本身。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    private var layerTwo: some View {
        item(tag: "L2", tint: .orange, title: "查询实时剩余额度") {
            VStack(alignment: .leading, spacing: 9) {
                Text("本地日志答不出「现在还剩多少」。为此 aibar 会读取登录凭据，向下列域名发起**只读**查询，每 5 分钟一次；撞上限流会自动拉长间隔，并继续显示上次拿到的额度：")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Provider.allCases, id: \.self) { p in
                        HStack(alignment: .top, spacing: 7) {
                            Circle().fill(p.tint).frame(width: 6, height: 6).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.displayName).font(.system(size: 11.5, weight: .medium))
                                Text(LiveQuotaService.availability(for: p))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(LiveQuotaService.supportsLiveQuota(p)
                                                     ? .secondary : .tertiary)
                                if LiveQuotaService.supportsLiveQuota(p) {
                                    Text("凭据读自 " + Credentials.location(for: p))
                                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    bullet("凭据只在内存中使用 —— 不落库、不写日志、不进导出文件")
                    bullet("凭据只发给上面列出的额度接口，检查更新不带任何凭据")
                    bullet("除白名单域名外，aibar 不与任何服务器通信")
                    bullet("域名白名单是编译期常量，CI 有静态检查强制")
                    bullet("设置 → 网络活动 可以看到每一个请求的时间、域名、状态码")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.3)))
            }
        }
    }

    private var layerThree: some View {
        item(tag: "L3", tint: .blue, title: "检查应用更新") {
            VStack(alignment: .leading, spacing: 7) {
                Text("启动后会向 GitHub 查询是否有新版本。发现更新后可以在面板里一键下载并替换当前应用。这条请求**不携带任何凭据**，可在设置里关掉自动检查。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("api.github.com / github.com")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Button {
                    model.offlineMode = false
                    finish()
                } label: {
                    Text("保持开启").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Button {
                    model.offlineMode = true
                    finish()
                } label: {
                    Text("切换到离线模式").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .buttonStyle(.bordered)

            Text("随时可在菜单栏面板顶部一键切换，不会丢失任何已有数据。")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private func finish() {
        model.disclosureShown = true
        Task {
            await model.applyNetworkSettings()
            await model.refresh(force: true)
            await model.checkForUpdate()
        }
        dismissWindow(id: WindowID.disclosure)
    }

    // MARK: - 零件

    private func item<C: View>(tag: String, tint: Color, title: String,
                               @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(tag)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(tint))
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                content()
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dataPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let providers: [any UsageProvider] = [ClaudeCodeProvider(), CodexProvider(), GrokProvider()]
        return providers.flatMap(\.rootPaths).map {
            $0.path.replacingOccurrences(of: home, with: "~")
        }
    }
}
