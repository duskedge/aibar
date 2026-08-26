import Foundation
import CoreServices

/// FSEvents 目录监听。
///
/// 用 FSEvents 而不是逐文件 DispatchSource：本机 628 个会话文件还在涨，
/// 每个都开一个 fd 既浪费又会撞上 fd 上限。FSEvents 自带 latency 参数，
/// 直接当去抖用 —— CLI 写日志是高频小批量，2 秒合并一次足够。
public final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "aibar.fsevents", qos: .utility)
    private let handler: @Sendable () -> Void

    /// - Parameter latency: 事件合并窗口（秒）。这就是去抖。
    public init(paths: [URL], latency: TimeInterval = 2.0, handler: @escaping @Sendable () -> Void) {
        self.handler = handler

        let existing = paths.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            existing.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
