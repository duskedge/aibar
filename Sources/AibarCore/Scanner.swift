import Foundation

/// 扫描编排器：发现文件 → 判断是否需要续读 → 增量解析 → 落库。
public final class Scanner {
    public let store: UsageStore
    public let providers: [any UsageProvider]

    public init(store: UsageStore, providers: [any UsageProvider]? = nil) {
        self.store = store
        self.providers = providers ?? [ClaudeCodeProvider(), CodexProvider(), GrokProvider()]
    }

    public struct Progress: Sendable {
        public var provider: Provider
        public var filesDone: Int
        public var filesTotal: Int
        public var eventsInserted: Int
    }

    public struct Summary: Sendable {
        public var filesScanned = 0
        public var filesSkipped = 0
        public var eventsInserted = 0
        public var rateLimitsInserted = 0
        public var malformedLines = 0
        public var bytesRead: UInt64 = 0
        public var duration: TimeInterval = 0
        public var errors: [String] = []
    }

    /// 全量 / 增量扫描。已扫过且 size 与 inode 都没变的文件直接跳过。
    ///
    /// `enabled` 为 nil 时扫全部；为空集合时一家都不扫。
    public func scan(enabled: Set<Provider>? = nil,
                     onProgress: ((Progress) -> Void)? = nil) throws -> Summary {
        let started = Date()
        var summary = Summary()

        let active = providers.filter { enabled?.contains($0.provider) ?? true }
        for provider in active {
            let files = provider.discoverFiles()
            var done = 0
            for file in files {
                done += 1
                defer {
                    onProgress?(Progress(provider: provider.provider, filesDone: done,
                                         filesTotal: files.count,
                                         eventsInserted: summary.eventsInserted))
                }
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                    let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                    let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

                    let prior = try store.fileState(path: file.path)
                    var offset = prior?.offset ?? 0
                    var cursor = prior?.cursor

                    // 文件被轮转（inode 变了）或被截断（size 小于已读 offset）→ 从头重读
                    if let prior, prior.inode != inode || size < prior.offset {
                        offset = 0
                        cursor = nil
                    }
                    if offset >= size, prior != nil {
                        summary.filesSkipped += 1
                        continue
                    }

                    let result = try provider.parse(file: file, from: offset, cursor: cursor)
                    try store.db.transaction {
                        summary.eventsInserted += try store.insert(events: result.events)
                        try store.insert(rateLimits: result.rateLimits)
                        for q in result.quotas.values { try store.insert(quota: q) }
                        try store.saveFileState(path: file.path, provider: provider.provider,
                                                inode: inode, size: size, mtime: mtime,
                                                offset: result.newOffset, cursor: result.cursor)
                    }
                    summary.rateLimitsInserted += result.rateLimits.count
                    summary.malformedLines += result.malformedLines
                    summary.bytesRead += result.newOffset - offset
                    summary.filesScanned += 1
                } catch {
                    // 单个文件出问题不能拖垮整次扫描，但必须留下痕迹
                    summary.errors.append("\(file.lastPathComponent): \(error)")
                }
            }
        }

        summary.duration = Date().timeIntervalSince(started)
        return summary
    }
}
