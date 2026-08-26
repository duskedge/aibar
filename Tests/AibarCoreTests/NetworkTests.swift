import Foundation
import Testing
@testable import AibarCore

@Suite("L2 网络层与导出")
struct NetworkTests {

    // MARK: - 白名单

    /// 白名单是这个产品的核心承诺，改动必须是有意识的。
    @Test("白名单只含官方域名")
    func allowlistIsMinimal() {
        #expect(NetworkGuard.allowedHosts == ["api.anthropic.com"])
    }

    @Test("非白名单域名被拒绝且留下记录")
    func blockedHostIsRejected() async throws {
        // 用独立日志实例：swift-testing 并行跑用例，共用全局单例会互相踩
        let sink = NetworkGuard.RequestLog()
        let url = URL(string: "https://evil.example.com/steal")!
        await #expect(throws: NetworkGuard.NetworkError.self) {
            _ = try await NetworkGuard.send(url: url, token: "dummy", log: sink)
        }
        let log = await sink.all()
        #expect(log.count == 1)
        #expect(log[0].host == "evil.example.com")
        #expect(log[0].note?.contains("拦截") == true)
        #expect(log[0].status == nil)
    }

    /// 日志给用户看，绝不能出现凭据。
    @Test("请求日志不含凭据")
    func logCarriesNoCredential() async throws {
        let sink = NetworkGuard.RequestLog()
        let secret = "sk-ant-oat01-SUPERSECRET"
        _ = try? await NetworkGuard.send(
            url: URL(string: "https://blocked.example.com/x")!, token: secret, log: sink)
        for entry in await sink.all() {
            let dump = "\(entry.host)\(entry.path)\(entry.note ?? "")"
            #expect(!dump.contains(secret))
            #expect(!dump.lowercased().contains("bearer"))
        }
    }

    @Test("日志容量有上限，不会无限增长")
    func logIsBounded() async {
        let sink = NetworkGuard.RequestLog()
        for i in 0..<260 {
            await sink.record(
                .init(host: "api.anthropic.com", path: "/x/\(i)", status: 200, duration: 0.01))
        }
        #expect(await sink.count() == 200)
    }

    // MARK: - 凭据

    @Test("凭据脱敏后看不出原值")
    func tokenRedaction() {
        let t = Credentials.Token(value: "sk-ant-oat01-abcdefghijklmnop",
                                  expiresAt: nil, plan: "pro")
        #expect(!t.redacted.contains("abcdefghijklmnop"))
        #expect(t.redacted.contains("字符"))

        let short = Credentials.Token(value: "abc", expiresAt: nil, plan: nil)
        #expect(short.redacted == "<3 字符>")
    }

    @Test("拒绝钥匙串后给出明确原因，而不是假装没找到")
    func accessDeniedMessage() {
        let err = Credentials.CredentialError.accessDenied
        #expect(err.description.contains("始终允许"))
        Credentials.resetSessionState()
    }

    @Test("过期凭据能被识别")
    func tokenExpiry() {
        let expired = Credentials.Token(value: "x", expiresAt: .now.addingTimeInterval(-60), plan: nil)
        let live = Credentials.Token(value: "x", expiresAt: .now.addingTimeInterval(3600), plan: nil)
        let never = Credentials.Token(value: "x", expiresAt: nil, plan: nil)
        #expect(expired.isExpired)
        #expect(!live.isExpired)
        #expect(!never.isExpired, "没给过期时间就不算过期")
    }

    // MARK: - Claude 响应解析

    @Test("解析 Claude 的多窗口额度")
    func parseClaudeQuota() throws {
        let json = """
        {"five_hour": {"utilization": 74, "resets_at": "2026-08-26T14:00:00Z"},
         "seven_day": {"utilization": 8, "resets_at": "2026-09-02T09:00:00Z"},
         "seven_day_opus": {"utilization": 30, "resets_at": "2026-09-02T09:00:00Z"}}
        """
        let quotas = try ClaudeQuotaClient.parse(Data(json.utf8), plan: "pro")
        #expect(quotas.count == 3)
        #expect(quotas[0].windowMinutes == 300)
        #expect(quotas[0].usedPercent == 74)
        #expect(quotas[0].windowLabel == "5 小时窗口")
        #expect(quotas[0].source == .officialAPI)
        #expect(quotas.allSatisfy { $0.planType == "pro" })
    }

    /// 上游加一个新窗口不该让整个功能挂掉。
    @Test("认不出的字段跳过而不是抛错")
    func parseTolerantToNewFields() throws {
        let json = """
        {"five_hour": {"utilization": 10, "resets_at": "2026-08-26T14:00:00Z"},
         "brand_new_window": {"utilization": 99},
         "extra_usage": {"whatever": true}}
        """
        let quotas = try ClaudeQuotaClient.parse(Data(json.utf8), plan: nil)
        #expect(quotas.count == 1)
        #expect(quotas[0].usedPercent == 10)
    }

    /// 一个都认不出时必须报错，而不是安静地返回空数组假装成功。
    @Test("完全认不出时报错")
    func parseFailsLoudly() {
        let json = #"{"something_else": 1}"#
        #expect(throws: NetworkGuard.NetworkError.self) {
            _ = try ClaudeQuotaClient.parse(Data(json.utf8), plan: nil)
        }
    }

    // MARK: - L2 服务开关

    struct StubClient: LiveQuotaClient {
        let provider: Provider
        let endpointDescription = "stub"
        func fetch() async throws -> [QuotaStatus] {
            [QuotaStatus(provider: provider, usedPercent: 42, windowMinutes: 300,
                         resetsAt: nil, planType: nil, observedAt: .now, source: .officialAPI)]
        }
    }

    @Test("离线模式下一个请求都不发")
    func offlineShortCircuits() async {
        let service = LiveQuotaService(
            config: .init(offline: true, enabled: [.claudeCode], minInterval: 0),
            clients: [StubClient(provider: .claudeCode)])
        let r = await service.refresh(force: true)
        #expect(r.quotas.isEmpty)
        #expect(r.failures.isEmpty, "离线不是失败，不该报错")
    }

    @Test("逐家开关生效")
    func perProviderToggle() async {
        let service = LiveQuotaService(
            config: .init(offline: false, enabled: [], minInterval: 0),
            clients: [StubClient(provider: .claudeCode)])
        #expect(await service.refresh(force: true).quotas.isEmpty)

        await service.update(config: .init(offline: false, enabled: [.claudeCode], minInterval: 0))
        #expect(await service.refresh(force: true).quotas.count == 1)
    }

    struct FailingClient: LiveQuotaClient {
        let provider = Provider.claudeCode
        let endpointDescription = "stub"
        func fetch() async throws -> [QuotaStatus] {
            throw Credentials.CredentialError.expired("Claude Code")
        }
    }

    /// L2 失败绝不能影响 L1，而且要给出原因让用户知道该怎么办。
    @Test("L2 失败记录原因且不抛出")
    func failureIsCaptured() async {
        let service = LiveQuotaService(
            config: .init(offline: false, enabled: [.claudeCode], minInterval: 0),
            clients: [FailingClient()])
        let r = await service.refresh(force: true)
        #expect(r.quotas.isEmpty)
        #expect(r.failures[.claudeCode]?.contains("重新登录") == true)
    }

    /// 只有 Claude 需要联网。Codex 与 Grok 的官方额度本地日志里就有，
    /// 为它们发请求纯属多余。
    @Test("只有 Claude 需要走接口")
    func availabilityIsHonest() {
        #expect(LiveQuotaService.supportsLiveQuota(.claudeCode))
        #expect(!LiveQuotaService.supportsLiveQuota(.codex))
        #expect(!LiveQuotaService.supportsLiveQuota(.grok))
        #expect(LiveQuotaService.availability(for: .grok).contains("本地日志"))
        #expect(LiveQuotaService.availability(for: .codex).contains("本地日志"))
    }

    @Test("默认轮询间隔是 5 分钟，不是 60 秒")
    func defaultIntervalIsFiveMinutes() {
        #expect(LiveQuotaService.defaultMinInterval == 300)
        #expect(LiveQuotaService.backoffDuration(consecutiveFailures: 1) == 300)
        #expect(LiveQuotaService.backoffDuration(consecutiveFailures: 2) == 600)
        #expect(LiveQuotaService.backoffDuration(consecutiveFailures: 3) == 1200)
        #expect(LiveQuotaService.backoffDuration(consecutiveFailures: 4) == 1800)
        #expect(LiveQuotaService.backoffDuration(consecutiveFailures: 9) == 1800)
    }

    final class SequenceClient: LiveQuotaClient, @unchecked Sendable {
        let provider = Provider.claudeCode
        let endpointDescription = "stub"
        private(set) var calls = 0
        var results: [Result<[QuotaStatus], Error>] = []

        func fetch() async throws -> [QuotaStatus] {
            calls += 1
            let idx = min(max(0, calls - 1), max(0, results.count - 1))
            guard !results.isEmpty else { return [] }
            return try results[idx].get()
        }
    }

    func sampleQuota(_ percent: Double = 42) -> QuotaStatus {
        QuotaStatus(provider: .claudeCode, usedPercent: percent, windowMinutes: 300,
                    resetsAt: nil, planType: "pro", observedAt: .now, source: .officialAPI)
    }

    @Test("429 保留上次额度，force 也不能打断静默期")
    func rateLimitKeepsLastQuota() async {
        let client = SequenceClient()
        client.results = [
            .success([sampleQuota(42)]),
            .failure(NetworkGuard.NetworkError.badStatus(429)),
            .success([sampleQuota(10)]),
        ]
        let service = LiveQuotaService(
            config: .init(offline: false, enabled: [.claudeCode], minInterval: 0),
            clients: [client])

        let ok = await service.refresh(force: true)
        #expect(ok.quotas.count == 1)
        #expect(ok.quotas[0].usedPercent == 42)
        #expect(ok.backingOffUntil == nil)

        let limited = await service.refresh(force: true)
        #expect(limited.quotas.count == 1, "429 必须留下上次的环")
        #expect(limited.quotas[0].usedPercent == 42)
        #expect(limited.failures[.claudeCode]?.contains("429") == true)
        #expect(limited.backingOffUntil != nil)
        #expect(await service.isBackingOff())

        let again = await service.refresh(force: true)
        #expect(client.calls == 2, "静默期内连 force 也不能再打")
        #expect(again.quotas[0].usedPercent == 42)
    }

    @Test("离线时留下上次额度，不当成失败")
    func offlineKeepsLastQuota() async {
        let client = SequenceClient()
        client.results = [.success([sampleQuota(77)])]
        let service = LiveQuotaService(
            config: .init(offline: false, enabled: [.claudeCode], minInterval: 0),
            clients: [client])
        _ = await service.refresh(force: true)
        await service.update(config: .init(offline: true, enabled: [.claudeCode], minInterval: 0))
        let r = await service.refresh(force: true)
        #expect(r.quotas.count == 1)
        #expect(r.quotas[0].usedPercent == 77)
        #expect(r.failures.isEmpty, "离线不是失败")
        #expect(client.calls == 1, "离线后一个请求都不能发")
    }

    // MARK: - 导出

    func sample() -> [SessionDetail] {
        [SessionDetail(id: "1", sessionId: "s1", provider: .claudeCode,
                       project: "含,逗号的\"项目\"", projectPath: "/Users/x/a,b",
                       branch: "main", model: "claude-opus-5",
                       started: Date(timeIntervalSince1970: 1_787_700_000),
                       ended: Date(timeIntervalSince1970: 1_787_703_600),
                       tokens: 1000, input: 100, output: 50, cacheRead: 800,
                       cacheWrite: 50, reasoning: 20, cost: 1.5, turns: 4),
         SessionDetail(id: "2", sessionId: "s2", provider: .codex,
                       project: "b", projectPath: nil, branch: nil, model: "codex-auto-review",
                       started: Date(timeIntervalSince1970: 1_787_700_000),
                       ended: Date(timeIntervalSince1970: 1_787_700_000),
                       tokens: 10, input: 10, output: 0, cacheRead: 0,
                       cacheWrite: 0, reasoning: 0, cost: nil, turns: 1)]
    }

    @Test("CSV 正确转义逗号与引号")
    func csvEscaping() {
        let csv = Export.csv(sample())
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[1].contains("\"含,逗号的\"\"项目\"\"\""))
        // 每行列数一致（转义正确的前提下）
        #expect(Export.escape("a,b") == "\"a,b\"")
        #expect(Export.escape("plain") == "plain")
        #expect(Export.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }

    /// 空单元格和 0 在表格里是两个意思。
    @Test("缺定价导出为空而不是 0")
    func csvMissingCostIsBlank() {
        let csv = Export.csv(sample())
        let row = csv.split(separator: "\n")[2]
        let cols = row.split(separator: ",", omittingEmptySubsequences: false)
        #expect(cols[13].isEmpty, "缺定价必须是空单元格，不能写 0")
    }

    @Test("JSON 导出不含凭据且标注估算")
    func jsonExport() throws {
        let data = try Export.json(sample(), pricingVersion: "2026-08-20")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("估算"))
        #expect(!text.lowercased().contains("token\":\"sk-"))
        #expect(!text.lowercased().contains("authorization"))

        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try #require(root["sessions"] as? [[String: Any]])
        #expect(sessions.count == 2)
        #expect(sessions[1]["estimatedCostUSD"] is NSNull, "缺定价必须是 null")
        #expect(sessions[1]["gitBranch"] == nil, "没有分支就不输出这个键")
    }
}

@Suite("轮询频率约束")
struct ThrottleTests {

    struct CountingClient: LiveQuotaClient {
        let provider = Provider.claudeCode
        let endpointDescription = "counting"
        let counter: Counter
        func fetch() async throws -> [QuotaStatus] {
            await counter.bump()
            return [QuotaStatus(provider: .claudeCode, usedPercent: 10, windowMinutes: 300,
                                resetsAt: nil, planType: nil, observedAt: .now,
                                source: .officialAPI)]
        }
    }

    actor Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    /// 连点刷新按钮曾经就是连着打接口，正是把自己打成 429 的那条路。
    /// force 可以跳过常规间隔，但跳不过 forceFloor。
    @Test("force 也有硬下限，连点不会连着发请求")
    func forceHasFloor() async {
        let counter = Counter()
        let service = LiveQuotaService(
            config: .init(offline: false, enabled: [.claudeCode],
                          minInterval: 300, forceFloor: 60),
            clients: [CountingClient(counter: counter)])

        for _ in 0..<5 { _ = await service.refresh(force: true) }
        #expect(await counter.count == 1, "连点 5 次只应发出 1 个请求")
    }

    @Test("forceFloor 为 0 时 force 可以连续拉取")
    func forceFloorZeroAllowsRepeat() async {
        let counter = Counter()
        let service = LiveQuotaService(
            config: .init(offline: false, enabled: [.claudeCode],
                          minInterval: 300, forceFloor: 0),
            clients: [CountingClient(counter: counter)])
        for _ in 0..<3 { _ = await service.refresh(force: true) }
        #expect(await counter.count == 3)
    }

    /// 退避是指数的，且有上限。
    @Test("429 退避按指数增长并封顶")
    func backoffGrowsAndCaps() {
        #expect(LiveQuotaService.backoffDuration(consecutiveFailures: 1) == 300)
        #expect(LiveQuotaService.backoffDuration(consecutiveFailures: 2) == 600)
        #expect(LiveQuotaService.backoffDuration(consecutiveFailures: 3) == 1200)
        let capped = LiveQuotaService.backoffDuration(consecutiveFailures: 20)
        #expect(capped == LiveQuotaService.maxRateLimitBackoff)
        #expect(capped <= 3600)
        // 0 或负数不该算出比一次失败还短的退避
        #expect(LiveQuotaService.backoffDuration(consecutiveFailures: 0) == 300)
    }

    /// 钥匙串锁定是临时状态，不能记成本会话永久拒绝 ——
    /// 否则用户解锁之后 aibar 依然拒绝查询，直到重启。
    @Test("钥匙串锁定与用户拒绝是两回事")
    func lockedIsNotDenied() {
        let locked = Credentials.CredentialError.locked
        let denied = Credentials.CredentialError.accessDenied
        #expect(locked.description.contains("解锁"))
        #expect(denied.description.contains("拒绝"))
        #expect(locked.description != denied.description)
    }
}
