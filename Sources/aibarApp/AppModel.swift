import AppKit
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
    /// 显示「7d」这样的窗口前缀。**默认关闭** —— 菜单栏默认只给一个百分比，
    /// 那是信息密度最高的形态；想看是哪个窗口再打开。
    @AppStorage(SettingsKey.menuBarShowWindowName) var menuBarShowWindowName = false
    /// 显示「6d21h」这样的重置倒计时。
    @AppStorage(SettingsKey.menuBarShowReset) var menuBarShowReset = false
    @AppStorage(SettingsKey.budgets) var budgetsRaw = "[]"
    @AppStorage(SettingsKey.language) var languageRaw = Localization.Language.system.rawValue
    /// 默认 false = 默认联网。改这个默认值等于改变产品承诺，动之前先看 README。
    @AppStorage(SettingsKey.offlineMode) var offlineMode = false
    @AppStorage(SettingsKey.liveQuotaClaude) var liveQuotaClaude = true
    @AppStorage(SettingsKey.disclosureShown) var disclosureShown = false
    @AppStorage(SettingsKey.autoCheckUpdates) var autoCheckUpdates = true

    @Published private(set) var networkLog: [NetworkGuard.LogEntry] = []
    @Published private(set) var updateStatus: AppUpdate.Status = .idle
    @Published private(set) var isUpdating = false
    /// 设置页点「重新查看首启说明」时置位，由 App 层监听并开窗。
    @Published var wantsDisclosure = false
    /// 已经就某个窗口提醒过，避免同一个窗口反复推送。
    private var notifiedWindows: Set<String> = []
    /// 额度接口自己的轮询。跟文件监听拆开，免得对话写日志时把接口打爆。
    private var quotaPollTask: Task<Void, Never>?
    private var updatePollTask: Task<Void, Never>?

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
            await engine.configure(budgets: budgets)
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
                // 文件变更只扫本地日志，不碰额度接口
                Task { @MainActor in await self?.refresh(includeLiveQuota: false) }
            }
            startQuotaPolling()
            startUpdatePolling()
        } catch {
            phase = .failed("\(error)")
        }
    }

    func refresh(force: Bool = false, includeLiveQuota: Bool = true) async {
        guard let engine, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await engine.refresh(force: force, includeLiveQuota: includeLiveQuota)
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
    var language: Localization.Language {
        get { Localization.Language(rawValue: languageRaw) ?? .system }
        set {
            languageRaw = newValue.rawValue
            applyLanguage(newValue)
        }
    }

    /// 写 `AppleLanguages` 覆盖界面语言。
    ///
    /// 已经渲染出来的视图不会自动重排 —— SwiftUI 在启动时就把 bundle
    /// 的语言定下来了，所以设置页会提示需要重启。这比假装能热切换、
    /// 结果切一半更诚实。
    func applyLanguage(_ language: Localization.Language) {
        if let codes = language.appleLanguages {
            UserDefaults.standard.set(codes, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    var budgets: [Budget] {
        get { BudgetStore.normalized(BudgetStore.decode(budgetsRaw)) }
        set { budgetsRaw = BudgetStore.encode(newValue) }
    }

    func updateBudget(_ budget: Budget) {
        var all = budgets
        if let i = all.firstIndex(where: { $0.provider == budget.provider }) {
            all[i] = budget
        } else {
            all.append(budget)
        }
        budgets = all
        Task {
            await engine?.configure(budgets: all)
            await refresh(force: true)
        }
    }

    func applyNetworkSettings() async {
        guard let engine else { return }
        var enabled: Set<Provider> = []
        if liveQuotaClaude { enabled.insert(.claudeCode) }
        await engine.configureLiveQuota(.init(
            offline: offlineMode || !disclosureShown,
            enabled: enabled,
            minInterval: LiveQuotaService.defaultMinInterval))
        snapshot.offlineMode = offlineMode
    }

    /// 额度按自己的节奏拉，不跟 FSEvents 绑在一起。
    private func startQuotaPolling() {
        quotaPollTask?.cancel()
        quotaPollTask = Task { [weak self] in
            let interval = LiveQuotaService.defaultMinInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.refresh(includeLiveQuota: true)
            }
        }
    }

    func toggleOffline() {
        offlineMode.toggle()
        Task {
            await applyNetworkSettings()
            await refresh(force: true)
            if !offlineMode { await checkForUpdate() }
        }
    }

    func refreshNetworkLog() async {
        networkLog = await NetworkGuard.RequestLog.shared.all()
    }

    // MARK: - 额度提醒

    /// 越过阈值时推一次通知。同一个窗口在重置之前只提醒一次。
    private func checkQuotaAlerts() {
        guard notifyOnQuota else { return }
        for q in snapshot.allQuotas {
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
            var text = Fmt.percent(q.usedPercent)
            if menuBarShowWindowName { text = Fmt.compactWindow(q.windowMinutes) + " " + text }
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

    // MARK: - 应用更新

    /// 正在跑的是 .app 才允许就地替换；从 `swift run` 起来的只能打开下载页。
    var canSelfUpdate: Bool { AppInstaller.runningFromAppBundle }

    var availableRelease: AppUpdate.Release? {
        if case .available(let r) = updateStatus { return r }
        return nil
    }

    var isCheckingUpdate: Bool {
        if case .checking = updateStatus { return true }
        return false
    }

    private func startUpdatePolling() {
        updatePollTask?.cancel()
        updatePollTask = Task { [weak self] in
            await self?.checkForUpdate()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppUpdate.defaultMinInterval))
                guard !Task.isCancelled else { break }
                await self?.checkForUpdate()
            }
        }
    }

    /// 查 GitHub 上有没有更新。离线、未看过披露页、或关了自动检查时跳过。
    /// `force` 是设置页「检查更新」—— 仍尊重离线，但不再看自动检查开关。
    func checkForUpdate(force: Bool = false) async {
        guard disclosureShown, !offlineMode else { return }
        guard force || autoCheckUpdates else { return }
        if case .available = updateStatus, !force { return }
        updateStatus = .checking
        do {
            updateStatus = try await AppUpdate.check()
        } catch {
            // 自动检查失败保持安静：网络抖一下不该在关于页留下一条错误。
            updateStatus = force ? .failed("\(error)") : .idle
        }
        networkLog = await NetworkGuard.RequestLog.shared.all()
    }

    func installAvailableUpdate() async {
        guard let release = availableRelease else { return }
        guard canSelfUpdate else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            let dmg = try await AppUpdate.downloadAndVerify(release)
            try AppInstaller.launchReplacement(
                dmg: dmg,
                destination: Bundle.main.bundleURL,
                pid: ProcessInfo.processInfo.processIdentifier)
            // 脚本在本进程退出后才会替换 .app
            NSApplication.shared.terminate(nil)
        } catch {
            updateStatus = .failed("\(error)")
            networkLog = await NetworkGuard.RequestLog.shared.all()
        }
    }

    func openReleasePage() {
        let url = availableRelease?.htmlURL ?? AppUpdate.releasesPageURL
        NSWorkspace.shared.open(url)
    }
}
