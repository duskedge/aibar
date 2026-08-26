import Foundation

/// 按 offset 续读的流式逐行读取器。
///
/// 本机 Codex 单目录就有 1.9 GB，绝不能整文件载入内存，
/// 所以按块读、按行切，并把行内容以 `[UInt8]` 交出去，让调用方先做字节级预筛。
public struct LineReader {
    public struct Chunk: Sendable {
        public let lines: [[UInt8]]
        /// 读完这些完整行之后的字节偏移。残缺的尾行不计入，留给下次。
        public let endOffset: UInt64
    }

    public static let defaultChunkSize = 1 << 20  // 1 MiB

    /// 从 `offset` 开始读到文件末尾，逐块把完整行交给 `body`。
    /// 返回最终 offset（不含末尾未以 \n 结尾的残缺行）。
    @discardableResult
    public static func read(
        file: URL,
        from offset: UInt64,
        chunkSize: Int = defaultChunkSize,
        body: (ArraySlice<UInt8>) throws -> Void
    ) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var carry: [UInt8] = []
        var totalRead: UInt64 = 0

        while true {
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            totalRead += UInt64(data.count)

            var buffer = carry
            buffer.append(contentsOf: data)

            var lineStart = 0
            var i = 0
            while i < buffer.count {
                if buffer[i] == 0x0A {  // \n
                    try body(buffer[lineStart..<i])
                    lineStart = i + 1
                }
                i += 1
            }
            // 残缺尾行留到下一轮。注意整块无换行时 lineStart 仍为 0，
            // 所以偏移必须按“已读总量 - 残留长度”算，不能按块累加差值（会出负数）。
            carry = Array(buffer[lineStart...])
        }
        return offset + totalRead - UInt64(carry.count)
    }
}

extension ArraySlice<UInt8> {
    /// 字节级子串查找。用来在 JSON 解析之前快速排除掉绝大多数无关行——
    /// 实测这一步能让全量扫描快一个数量级。
    public func contains(bytes needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        let first = needle[0]
        var i = startIndex
        let last = endIndex - needle.count
        while i <= last {
            if self[i] == first {
                var j = 1
                while j < needle.count, self[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}
