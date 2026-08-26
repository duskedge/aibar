import Foundation

/// 各家 CLI 的登录凭据读取。
///
/// 三条铁律：
/// 1. **只取需要的那一个字段。** Claude 的 Keychain 条目里同时存着 MCP 服务器的
///    OAuth 凭据（accessToken / refreshToken / clientSecret），本机实测就有 figma 的。
///    代码只读 `claudeAiOauth.accessToken`，绝不整块读出来更不整块外传。
/// 2. **只在内存里过一遍。** 不落库、不写日志、不进导出文件。
/// 3. **打印一律脱敏。** 调试信息只给长度和前后各 4 字符。
public enum Credentials {

    /// 硬性禁读开关。
    ///
    /// 由 `AIBAR_NO_CREDENTIALS=1` 打开，scripts/test.sh 会设置它。
    /// 起因是一次真实事故：单测构造了真的 UsageEngine，其 L2 默认开着，
    /// 一路调到这里，**弹出了用户的钥匙串授权框**。
    /// 默认关闭 L2 已经修掉了根因，这里是第二道闸 —— 测试环境下
    /// 任何读取凭据的路径都直接抛错，而不是弹框。
    public static var isBlocked: Bool {
        ProcessInfo.processInfo.environment["AIBAR_NO_CREDENTIALS"] == "1"
    }


    public struct Token: Sendable {
        public let value: String
        public let expiresAt: Date?
        public let plan: String?

        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < .now
        }

        /// 任何需要写进日志或界面的地方都用它，绝不用 `value`。
        public var redacted: String {
            guard value.count > 12 else { return "<\(value.count) 字符>" }
            return "\(value.prefix(4))…\(value.suffix(4)) <\(value.count) 字符>"
        }
    }

    public enum CredentialError: Error, CustomStringConvertible {
        case notFound(String)
        case unreadable(String)
        case expired(String)

        public var description: String {
            switch self {
            case .notFound(let where_): "未找到登录凭据（\(where_)）"
            case .unreadable(let why): "凭据无法解析：\(why)"
            case .expired(let who): "\(who) 的登录已过期，请重新登录该 CLI"
            }
        }
    }

    // MARK: - Claude Code

    /// Keychain service = `Claude Code-credentials`，值是一整块 JSON。
    /// 老版本 CLI 也可能放在 `~/.claude/.credentials.json`。
    public static func claudeCode() throws -> Token {
        guard !isBlocked else { throw CredentialError.notFound("AIBAR_NO_CREDENTIALS=1 已禁止读取凭据") }
        let json = try claudeCredentialBlob()
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else { throw CredentialError.unreadable("缺少 claudeAiOauth 字段") }

        guard let access = oauth["accessToken"] as? String, !access.isEmpty else {
            throw CredentialError.unreadable("claudeAiOauth 中没有 accessToken")
        }
        // 毫秒时间戳
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        let token = Token(value: access, expiresAt: expires,
                          plan: oauth["subscriptionType"] as? String)
        if token.isExpired { throw CredentialError.expired("Claude Code") }
        return token
    }

    private static func claudeCredentialBlob() throws -> Data {
        guard !isBlocked else { throw CredentialError.notFound("AIBAR_NO_CREDENTIALS=1 已禁止读取凭据") }
        // 先试文件（老版本），再试 Keychain
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return data }

        // 有些安装会把账号写进 kSecAttrAccount，去掉 service 限定再试一次
        query[kSecAttrService as String] = nil
        query[kSecAttrAccount as String] = "Claude Code-credentials"
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data { return data }

        throw CredentialError.notFound("Keychain: Claude Code-credentials")
    }

    // MARK: - Codex
    //
    // M4 不用它：Codex 的额度本地日志里就有，发请求纯属多余。
    // 留着是为了让设置页能显示"凭据在哪"，以及将来万一需要。

    public static var codexCredentialPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    // MARK: - Grok

    public static var grokCredentialPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
    }

    /// 凭据存在与否（不读取内容）。设置页用它显示"已登录 / 未登录"。
    public static func exists(for provider: Provider) -> Bool {
        guard !isBlocked else { return false }
        return switch provider {
        case .claudeCode:
            (try? claudeCredentialBlob()) != nil
        case .codex:
            FileManager.default.fileExists(atPath: codexCredentialPath.path)
        case .grok:
            FileManager.default.fileExists(atPath: grokCredentialPath.path)
        }
    }

    /// 凭据位置的人类可读描述。首启披露页要逐条列出来。
    public static func location(for provider: Provider) -> String {
        switch provider {
        case .claudeCode: "Keychain · Claude Code-credentials"
        case .codex: "~/.codex/auth.json"
        case .grok: "~/.grok/auth.json"
        }
    }
}
