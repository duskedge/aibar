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
        await NetworkGuard.RequestLog.shared.clear()
        let url = URL(string: "https://evil.example.com/steal")!
        await #expect(throws: NetworkGuard.NetworkError.self) {
            _ = try await NetworkGuard.send(url: url, token: "dummy")
        }
        let log = await NetworkGuard.RequestLog.shared.all()
        #expect(log.count == 1)
        #expect(log[0].host == "evil.example.com")
        #expect(log[0].note?.contains("拦截") == true)
        #expect(log[0].status == nil)
    }

    /// 日志给用户看，绝不能出现凭据。
    @Test("请求日志不含凭据")
    func logCarriesNoCredential() async throws {
        await NetworkGuard.RequestLog.shared.clear()
        let secret = "sk-ant-oat01-SUPERSECRET"
        _ = try? await NetworkGuard.send(
            url: URL(string: "https://blocked.example.com/x")!, token: secret)
        for entry in await NetworkGuard.RequestLog.shared.all() {
            let dump = "\(entry.host)\(entry.path)\(entry.note ?? "")"
            #expect(!dump.contains(secret))
            #expect(!dump.lowercased().contains("bearer"))
        }
    }

    @Test("日志容量有上限，不会无限增长")
    func logIsBounded() async {
        await NetworkGuard.RequestLog.shared.clear()
        for i in 0..<260 {
            await NetworkGuard.RequestLog.shared.record(
                .init(host: "api.anthropic.com", path: "/x/\(i)", status: 200, duration: 0.01))
        }
        #expect(await NetworkGuard.RequestLog.shared.count() == 200)
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

    @Test("各家 L2 可用性如实汇报")
    func availabilityIsHonest() {
        #expect(LiveQuotaService.supportsLiveQuota(.claudeCode))
        #expect(!LiveQuotaService.supportsLiveQuota(.codex))
        #expect(!LiveQuotaService.supportsLiveQuota(.grok))
        // Grok 经查证没有官方额度接口，不能靠成本反推假百分比
        #expect(LiveQuotaService.availability(for: .grok).contains("未提供"))
        #expect(LiveQuotaService.availability(for: .codex).contains("本地日志"))
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
