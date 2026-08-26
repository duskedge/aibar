import Foundation

/// 一次增量解析的产出。
public struct ScanResult: Sendable {
    public var events: [UsageEvent] = []
    public var rateLimits: [RateLimitEvent] = []
    /// 按 window_minutes 索引 —— 同一家可能同时有多个窗口的额度。
    public var quotas: [Int: QuotaStatus] = [:]
    /// 读到的新偏移；写回 scan_state 供下次续读。
    public var newOffset: UInt64
    /// Provider 私有的续读游标（Codex 用它记住上一次的 total）。
    public var cursor: String?
    /// 解析失败的行数。上游改格式时靠它暴露问题，而不是静默丢数据。
    public var malformedLines: Int = 0

    public init(newOffset: UInt64) { self.newOffset = newOffset }
}

/// 新增一家 Provider 只需实现这个协议。
public protocol UsageProvider: Sendable {
    var provider: Provider { get }
    /// 需要监听的根目录（M2 的 FSEvents 会用到）。
    var rootPaths: [URL] { get }
    /// 枚举本 Provider 的全部会话文件。
    func discoverFiles() -> [URL]
    /// 从 `offset` 续读一个文件。`cursor` 是上次返回的私有游标。
    func parse(file: URL, from offset: UInt64, cursor: String?) throws -> ScanResult
}

extension UsageProvider {
    /// 递归枚举指定扩展名的文件；目录不存在时返回空数组而不是抛错——
    /// 用户很可能只装了三家里的一家。
    func files(under root: URL, named: String? = nil, ext: String? = nil) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            if let named, url.lastPathComponent != named { continue }
            if let ext, url.pathExtension != ext { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(url)
            }
        }
        return out
    }
}

/// 从任意 JSON 值里安全取整数——三家有的写 Int 有的写 Double。
@inline(__always)
func jsonInt(_ any: Any?) -> Int {
    switch any {
    case let v as Int: v
    case let v as Double: Int(v)
    case let v as NSNumber: v.intValue
    default: 0
    }
}

@inline(__always)
func jsonDouble(_ any: Any?) -> Double? {
    switch any {
    case let v as Double: v
    case let v as Int: Double(v)
    case let v as NSNumber: v.doubleValue
    default: nil
    }
}
