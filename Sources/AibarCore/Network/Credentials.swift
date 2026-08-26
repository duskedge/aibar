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
        /// 用户点了拒绝，或本会话已经弹过一次。不要接着打第二次。
        case accessDenied
        /// 钥匙串锁着。临时状态，解锁后自动恢复。
        case locked

        public var description: String {
            switch self {
            case .notFound(let where_): "未找到登录凭据（\(where_)）"
            case .unreadable(let why): "凭据无法解析：\(why)"
            case .expired(let who): "\(who) 的登录已过期，请重新登录该 CLI"
            case .accessDenied: "钥匙串访问被拒绝。点「始终允许」后不要立刻重编译 —— 临时签名每次都是新应用"
            case .locked: "钥匙串已锁定，解锁后会自动重试"
            }
        }
    }

    // MARK: - Claude Code

    /// 进程内缓存。钥匙串「始终允许」是绑在二进制签名上的，
    /// 但同一次运行里不该每 5 分钟再弹一次。
    /// 访问一律走 `cacheLock`；Swift 6 看不到这把锁，所以标 unsafe。
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedToken: Token?
    nonisolated(unsafe) private static var deniedThisSession = false

    /// 测试用。生产路径不会调。
    static func resetSessionState() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedToken = nil
        deniedThisSession = false
    }

    /// Keychain service = `Claude Code-credentials`，值是一整块 JSON。
    /// 老版本 CLI 也可能放在 `~/.claude/.credentials.json`。
    public static func claudeCode() throws -> Token {
        guard !isBlocked else { throw CredentialError.notFound("AIBAR_NO_CREDENTIALS=1 已禁止读取凭据") }
        cacheLock.lock(); defer { cacheLock.unlock() }
        if deniedThisSession { throw CredentialError.accessDenied }
        if let cachedToken, !cachedToken.isExpired { return cachedToken }

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
        cachedToken = token
        return token
    }

    private static func claudeCredentialBlob() throws -> Data {
        guard !isBlocked else { throw CredentialError.notFound("AIBAR_NO_CREDENTIALS=1 已禁止读取凭据") }
        // 先试文件（老版本），再试 Keychain —— 文件不弹授权框
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }

        switch readKeychain(account: false, returnData: true) {
        case .data(let data): return data
        case .denied:
            deniedThisSession = true
            throw CredentialError.accessDenied
        case .locked:
            // 不记 deniedThisSession —— 解锁后下一轮轮询还该再试
            throw CredentialError.locked
        case .notFound:
            break
        }

        // 有些安装把名字写在 Account 而不是 Service。只在「找不到」时再试，
        // 用户点了拒绝绝不能打第二次，否则就会一直弹。
        switch readKeychain(account: true, returnData: true) {
        case .data(let data): return data
        case .denied:
            deniedThisSession = true
            throw CredentialError.accessDenied
        case .locked:
            throw CredentialError.locked
        case .notFound:
            throw CredentialError.notFound("Keychain: Claude Code-credentials")
        }
    }

    private enum KeychainRead {
        case data(Data)
        case notFound
        case denied
        /// 钥匙串锁着，下次还能再试。
        case locked
    }

    /// 用户点了拒绝 / 取消，本会话就别再弹了。
    ///
    /// 注意 `errSecInteractionNotAllowed` **不算**：它表示钥匙串当前是锁着的、
    /// 且此刻不允许弹 UI —— 这是临时状态，用户解锁后就该能读到。
    /// 把它记成"本会话已拒绝"会让 aibar 在解锁之后依然拒绝查询，直到重启。
    private static func isDenied(_ status: OSStatus) -> Bool {
        status == errSecUserCanceled || status == errSecAuthFailed
    }

    /// 钥匙串锁着，稍后可再试。不进 `deniedThisSession`。
    private static func isTemporarilyUnavailable(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed
    }

    private static func readKeychain(account: Bool, returnData: Bool) -> KeychainRead {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: returnData,
            kSecReturnAttributes as String: !returnData,
        ]
        if account {
            query[kSecAttrAccount as String] = "Claude Code-credentials"
        } else {
            query[kSecAttrService as String] = "Claude Code-credentials"
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            if returnData, let data = item as? Data { return .data(data) }
            if !returnData { return .data(Data()) }
        }
        if status == errSecItemNotFound { return .notFound }
        if isDenied(status) { return .denied }
        if isTemporarilyUnavailable(status) { return .locked }
        return .notFound
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
            // 只查条目在不在，不取密码 —— 否则设置页一打开就弹钥匙串
            claudeCredentialsPresent()
        case .codex:
            FileManager.default.fileExists(atPath: codexCredentialPath.path)
        case .grok:
            FileManager.default.fileExists(atPath: grokCredentialPath.path)
        }
    }

    private static func claudeCredentialsPresent() -> Bool {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if FileManager.default.fileExists(atPath: file.path) { return true }
        switch readKeychain(account: false, returnData: false) {
        case .data: return true
        case .denied, .locked, .notFound: break
        }
        switch readKeychain(account: true, returnData: false) {
        case .data: return true
        case .denied, .locked, .notFound: return false
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
