import SwiftUI
import AibarCore

/// 主窗口的状态。和菜单栏面板分开：
/// 面板要秒开所以读预聚合快照，仪表盘则按用户选的范围现查。
@MainActor
final class DashboardModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case overview, sessions, projects, models
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "仪表盘"
            case .sessions: "会话明细"
            case .projects: "按项目"
            case .models: "按模型"
            }
        }
        var icon: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .sessions: "list.bullet.rectangle"
            case .projects: "folder"
            case .models: "cube"
            }
        }
    }

    enum Metric: String, CaseIterable {
        case tokens, cost
        var title: String { self == .tokens ? "Token" : "成本" }
    }

    @Published var tab: Tab = .overview
    @Published var range: DateRange = .week
    @Published var metric: Metric = .tokens
    @Published var providerFilter: Provider?
    @Published var search = ""
    @Published var selectedSession: SessionDetail?

    @Published private(set) var data = DashboardData()
    @Published private(set) var sessions: [SessionDetail] = []
    @Published private(set) var timeline: [TurnPoint] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private var engine: UsageEngine?
    private var loadTask: Task<Void, Never>?

    /// 离屏渲染用：直接注入数据，不接引擎。
    static func preview(data: DashboardData, sessions: [SessionDetail]) -> DashboardModel {
        let m = DashboardModel()
        m.data = data
        m.sessions = sessions
        m.range = data.range
        return m
    }

    func attach(_ engine: UsageEngine) {
        guard self.engine == nil else { return }
        self.engine = engine
        reload()
    }

    /// 每次改筛选条件都会调用。旧请求直接取消，避免慢查询回来覆盖新结果。
    func reload() {
        guard let engine else { return }
        loadTask?.cancel()
        let (range, provider, search, tab) = (range, providerFilter, search, tab)
        loadTask = Task { [weak self] in
            await MainActor.run { self?.loading = true }
            do {
                let d = try await engine.dashboard(range: range)
                let list = tab == .sessions
                    ? try await engine.sessions(range: range, provider: provider, search: search)
                    : []
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.data = d
                    self?.sessions = list
                    self?.error = nil
                    self?.loading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.error = "\(error)"
                    self?.loading = false
                }
            }
        }
    }

    func select(_ session: SessionDetail?) {
        selectedSession = session
        timeline = []
        guard let session, let engine else { return }
        Task { [weak self] in
            let points = (try? await engine.timeline(sessionId: session.sessionId,
                                                     provider: session.provider)) ?? []
            await MainActor.run { self?.timeline = points }
        }
    }

    /// 当前指标下的取值，让图表和排行共用一套口径。
    func value(_ bucket: Reports.Bucket) -> Double {
        metric == .tokens ? Double(bucket.tokens) : (bucket.cost ?? 0)
    }

    func formatted(_ bucket: Reports.Bucket) -> String {
        metric == .tokens ? Fmt.tokens(bucket.tokens) : Fmt.cost(bucket.cost)
    }
}
