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

    private var engine: UsageEngine?

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
        do {
            let engine = try UsageEngine()
            self.engine = engine

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
            lastRefresh = .now
            phase = .ready
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
            lastRefresh = .now
            phase = .ready
        } catch {
            phase = .failed("\(error)")
        }
    }

    // MARK: - 菜单栏标题

    /// 取三家里最紧张的一家。M2 只有 Codex 从本地日志拿得到额度，
    /// Claude / Grok 需要 L2 接口层（M4）。
    var tightestQuota: QuotaStatus? {
        snapshot.quotas.max { $0.usedPercent < $1.usedPercent }
    }

    var menuBarTitle: String? {
        switch display {
        case .iconOnly: nil
        case .quota: tightestQuota.map { Fmt.percent($0.usedPercent) } ?? Fmt.tokens(snapshot.today.tokens)
        case .cost: Fmt.cost(snapshot.today.cost)
        case .tokens: Fmt.tokens(snapshot.today.tokens)
        }
    }

    var quotaLevel: Thresholds.Level {
        guard let q = tightestQuota else { return .normal }
        return thresholds.level(for: q.usedPercent)
    }
}
