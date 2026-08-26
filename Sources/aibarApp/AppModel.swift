import SwiftUI
import AibarCore

/// UI 侧的唯一状态源。所有数据库操作都发生在 `UsageEngine` actor 里，
/// 这里只持有它交回来的 Snapshot 值。
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case launching
        case indexing(String)     // 首次全量扫描，带进度文案
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .launching
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    @AppStorage(SettingsKey.display) var display: MenuBarDisplay = .quota
    @AppStorage(SettingsKey.warnThreshold) var warnThreshold: Double = 80
    @AppStorage(SettingsKey.critThreshold) var critThreshold: Double = 95
    @AppStorage(SettingsKey.notifyOnQuota) var notifyOnQuota = true
    @AppStorage(SettingsKey.menuBarTarget) var menuBarTargetRaw = MenuBarTarget.tightest.rawValue
    @AppStorage(SettingsKey.menuBarWindow) var menuBarWindowRaw = MenuBarWindow.tightest.rawValue
    /// 显示「7天:」这样的窗口前缀。菜单栏窄的时候可以关掉。
    @AppStorage(SettingsKey.menuBarShowWindowName) var menuBarShowWindowName = true
    /// 显示「6d21h」这样的重置倒计时。
    @AppStorage(SettingsKey.menuBarShowReset) var menuBarShowReset = false
    /// 默认 false = 默认联网。改这个默认值等于改变产品承诺，动之前先看 README。
    @AppStorage(SettingsKey.offlineMode) var offlineMode = false
    @AppStorage(SettingsKey.liveQuotaClaude) var liveQuotaClaude = true
    @AppStorage(SettingsKey.disclosureShown) var disclosureShown = false

    @Published private(set) var networkLog: [NetworkGuard.LogEntry] = []
    /// 设置页点「重新查看首启说明」时置位，由 App 层监听并开窗。
    @Published var wantsDisclosure = false
    /// 已经就某个窗口提醒过，避免同一个窗口反复推送。
    private var notifiedWindows: Set<String> = []

    /// 仪表盘复用同一个引擎实例，两个窗口共享一份连接与扫描状态。
    private(set) var engine: UsageEngine?

    /// 供离屏渲染用（生成 README 截图、做视觉回归）。
    /// 不启动引擎，也不监听文件，纯粹把给定快照渲染出来。
    static func preview(snapshot: Snapshot) -> AppModel {
        let m = AppModel()
        m.snapshot = snapshot
        m.phase = .ready
        m.lastRefresh = .now
        return m
    }

    var thresholds: Thresholds { Thresholds(warn: warnThreshold, critical: critThreshold) }

    func start() async {
        guard engine == nil else { return }
        // 没看过披露页之前一个请求都不发 —— 先告知，再联网。
        // 披露页由 AibarApp 打开成独立窗口，这里只保证网络是关着的。
        do {
            let engine = try UsageEngine()
            self.engine = engine
            await applyNetworkSettings()

            // 冷启动先把已有数据显示出来，不让用户对着空面板等全量扫描
            if let cached = try? await engine.snapshot(), !cached.isEmpty {
                snapshot = cached
                phase = .ready
            } else {
                phase = .indexing("正在建立索引…")
            }

            await refresh()
            await engine.startWatching { [weak self] in
                Task { @MainActor in await self?.refresh() }
            }
        } catch {
            phase = .failed("\(error)")
        }
    }

    func refresh(force: Bool = false) async {
        guard let engine, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await engine.refresh(force: force)
            snapshot.offlineMode = offlineMode
            lastRefresh = .now
            phase = .ready
            networkLog = await NetworkGuard.RequestLog.shared.all()
            checkQuotaAlerts()
        } catch {
            phase = .failed("\(error)")
        }
    }

    func rebuild() async {
        guard let engine else { return }
        phase = .indexing("正在重建索引…")
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await engine.rebuild()
            snapshot.offlineMode = offlineMode
            lastRefresh = .now
            phase = .ready
        } catch {
            phase = .failed("\(error)")
        }
    }

    // MARK: - 网络设置

    /// 把界面上的开关同步给引擎。离线模式一开，L2 连凭据都不会去读。
    func applyNetworkSettings() async {
        guard let engine else { return }
        var enabled: Set<Provider> = []
        if liveQuotaClaude { enabled.insert(.claudeCode) }
        await engine.configureLiveQuota(.init(
            offline: offlineMode || !disclosureShown,
            enabled: enabled,
            minInterval: 60))
        snapshot.offlineMode = offlineMode
    }

    func toggleOffline() {
        offlineMode.toggle()
        Task {
            await applyNetworkSettings()
            await refresh(force: true)
        }
    }

    func refreshNetworkLog() async {
        networkLog = await NetworkGuard.RequestLog.shared.all()
    }

    // MARK: - 额度提醒

    /// 越过阈值时推一次通知。同一个窗口在重置之前只提醒一次。
    private func checkQuotaAlerts() {
        guard notifyOnQuota else { return }
        for q in snapshot.quotas + snapshot.liveQuotas {
            let level = thresholds.level(for: q.usedPercent)
            guard level != .normal else { continue }
            // 用 (来源, 窗口, 重置时刻) 作键：窗口一重置，键就变了，可以再提醒
            let key = "\(q.provider.rawValue)-\(q.windowMinutes)-\(q.resetsAt?.timeIntervalSince1970 ?? 0)-\(level)"
            guard !notifiedWindows.contains(key) else { continue }
            notifiedWindows.insert(key)
            Notifications.quotaAlert(quota: q, level: level)
        }
    }

    // MARK: - 菜单栏标题

    /// 取三家里最紧张的一家。M2 只有 Codex 从本地日志拿得到额度，
    /// Claude / Grok 需要 L2 接口层（M4）。
    var menuBarTarget: MenuBarTarget {
        get { MenuBarTarget(rawValue: menuBarTargetRaw) ?? .tightest }
        set { menuBarTargetRaw = newValue.rawValue }
    }

    var menuBarWindow: MenuBarWindow {
        get { MenuBarWindow(rawValue: menuBarWindowRaw) ?? .tightest }
        set { menuBarWindowRaw = newValue.rawValue }
    }

    /// 菜单栏当前显示的那条额度。
    var displayedQuota: QuotaStatus? {
        snapshot.quota(target: menuBarTarget, window: menuBarWindow)
    }

    var tightestQuota: QuotaStatus? { snapshot.tightestQuota }

    /// 菜单栏文案。
    ///
    /// 额度模式形如 `7天: 3%` 或 `5小时: 74% · 3h12m`，
    /// 窗口前缀与倒计时都可以在设置里关掉 —— 刘海屏空间是真的紧张。
    var menuBarTitle: String? {
        switch display {
        case .iconOnly: return nil
        case .cost: return Fmt.cost(snapshot.today.cost)
        case .tokens: return Fmt.tokens(snapshot.today.tokens)
        case .quota:
            guard let q = displayedQuota else {
                // 一条额度都没有时退回今日 token，总比空着强
                return Fmt.tokens(snapshot.today.tokens)
            }
            var text = ""
            if menuBarShowWindowName { text += Fmt.compactWindow(q.windowMinutes) + ": " }
            text += Fmt.percent(q.usedPercent)
            if menuBarShowReset, let reset = q.timeUntilReset, reset > 0 {
                text += " " + Fmt.compactDuration(reset)
            }
            return text
        }
    }

    /// 菜单栏图标要不要报警，看的是**当前显示的那条**。
    /// 显示 A 却按 B 的水位变红，用户会以为 A 出了问题。
    var quotaLevel: Thresholds.Level {
        guard let q = displayedQuota else { return .normal }
        return thresholds.level(for: q.usedPercent)
    }

    /// 菜单栏用哪家的颜色。多家混显时保持中性。
    var menuBarTint: Provider? {
        if case .provider(let p) = menuBarTarget { return p }
        return displayedQuota?.provider
    }
}
