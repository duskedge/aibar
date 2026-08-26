import Foundation

/// 域名白名单 + 请求审计。
///
/// aibar 默认联网，所以"我们只连这三个域名"必须是**可验证的**，而不是一句承诺：
/// - 白名单是编译期常量，见 `allowedHosts`
/// - 所有出网请求必须经由 `NetworkGuard.send`，它会在发出前校验 host
/// - CI 有一条静态检查（scripts/check-network.sh），源码里出现
///   非白名单 host 的网络调用直接构建失败
/// - 每个请求都记进 `RequestLog`，设置页的「网络活动」面板原样展示，
///   用户不装抓包工具也能自查
public enum NetworkGuard {

    /// 唯一允许访问的域名。改这里必须同步改 README 和首启披露页。
    public static let allowedHosts: Set<String> = [
        "api.anthropic.com",
    ]

    public enum NetworkError: Error, CustomStringConvertible {
        case blockedHost(String)
        case offline
        case badStatus(Int)
        case badResponse(String)

        public var description: String {
            switch self {
            case .blockedHost(let h): "拒绝访问未在白名单中的域名：\(h)"
            case .offline: "离线模式已开启"
            case .badStatus(let code): "服务返回 \(code)"
            case .badResponse(let why): "响应无法解析：\(why)"
            }
        }
    }

    /// 一条请求记录。**不含任何凭据** —— 只有域名、路径、状态码、耗时。
    public struct LogEntry: Sendable, Identifiable, Hashable {
        public let id = UUID()
        public let at: Date
        public let host: String
        public let path: String
        public let status: Int?
        public let duration: TimeInterval
        public let note: String?

        public var ok: Bool { (200..<300).contains(status ?? 0) }

        public init(at: Date = .now, host: String, path: String,
                    status: Int?, duration: TimeInterval, note: String? = nil) {
            self.at = at; self.host = host; self.path = path
            self.status = status; self.duration = duration; self.note = note
        }
    }

    /// 进程内的请求日志。只留最近 200 条，不落盘。
    public actor RequestLog {
        public static let shared = RequestLog()
        private var entries: [LogEntry] = []
        private let capacity = 200

        public func record(_ entry: LogEntry) {
            entries.append(entry)
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }

        public func all() -> [LogEntry] { entries.reversed() }
        public func count() -> Int { entries.count }
        public func clear() { entries.removeAll() }
    }

    /// 唯一的出网入口。
    ///
    /// - Parameter token: 只用于填 Authorization 头，不会被记录到任何地方。
    public static func send(
        url: URL,
        token: String,
        headers: [String: String] = [:],
        timeout: TimeInterval = 10
    ) async throws -> Data {
        guard let host = url.host else { throw NetworkError.blockedHost("(无 host)") }
        guard allowedHosts.contains(host) else {
            // 记下这次拦截 —— 白名单起作用了，用户应该看得到
            await RequestLog.shared.record(LogEntry(
                host: host, path: url.path, status: nil, duration: 0, note: "已拦截：不在白名单"))
            throw NetworkError.blockedHost(host)
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("aibar/\(version)", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode
            await RequestLog.shared.record(LogEntry(
                host: host, path: url.path, status: code,
                duration: Date().timeIntervalSince(started)))
            guard let code, (200..<300).contains(code) else {
                throw NetworkError.badStatus(code ?? -1)
            }
            return data
        } catch let error as NetworkError {
            throw error
        } catch {
            await RequestLog.shared.record(LogEntry(
                host: host, path: url.path, status: nil,
                duration: Date().timeIntervalSince(started),
                note: (error as NSError).localizedDescription))
            throw error
        }
    }

    public static let version = "0.3.0"

    /// 不用 `URLSession.shared`：关掉 cookie 与凭据缓存，
    /// 避免把任何东西留在磁盘上。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()
}
