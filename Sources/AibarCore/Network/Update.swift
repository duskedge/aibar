import CryptoKit
import Foundation

/// 从 GitHub Release 检查 / 下载新版本。
///
/// 不引入 Sparkle：零第三方依赖是这个项目的产品承诺。
/// 元数据走 `github.com` 的 Atom 订阅，安装包走同一域名（会 302 到 githubusercontent）。
/// 不打 `api.github.com`：未登录 REST 限额是每 IP 每小时 60 次，共享出口很容易 403。
/// 都不带凭据，离线模式下一律短路。
public enum AppUpdate {
    public static let owner = "duskedge"
    public static let repo = "aibar"
    public static let defaultMinInterval: TimeInterval = 86_400

    public static var latestFeedURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases.atom")!
    }

    public static var releasesPageURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    }

    public struct Release: Sendable, Equatable {
        public let version: String
        public let tag: String
        public let notes: String
        public let dmgURL: URL
        public let sha256URL: URL?
        public let htmlURL: URL?

        public init(version: String, tag: String, notes: String,
                    dmgURL: URL, sha256URL: URL?, htmlURL: URL?) {
            self.version = version; self.tag = tag; self.notes = notes
            self.dmgURL = dmgURL; self.sha256URL = sha256URL; self.htmlURL = htmlURL
        }
    }

    public enum Status: Sendable, Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    /// `v0.5.2` / `0.5.2` → 数字段。对不上的段当 0。
    public static func versionParts(_ raw: String) -> [Int] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        return s.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = versionParts(lhs), b = versionParts(rhs)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    /// 按仓库现有发布约定拼下载地址：`aibar-<tag>.dmg` / `.dmg.sha256`。
    public static func release(for tag: String, notes: String = "") -> Release {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (tag.first == "v" || tag.first == "V") ? String(tag.dropFirst()) : tag
        let base = "https://github.com/\(owner)/\(repo)/releases"
        return Release(
            version: version,
            tag: tag,
            notes: notes,
            dmgURL: URL(string: "\(base)/download/\(tag)/aibar-\(tag).dmg")!,
            sha256URL: URL(string: "\(base)/download/\(tag)/aibar-\(tag).dmg.sha256"),
            htmlURL: URL(string: "\(base)/tag/\(tag)"))
    }

    /// GitHub 的 `releases.atom`。草稿不进订阅；取第一条 entry 即最新发布。
    public static func parseAtom(_ data: Data) throws -> Release {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw NetworkGuard.NetworkError.badResponse("Release 订阅不是文本")
        }
        guard let start = xml.range(of: "<entry"),
              let end = xml.range(of: "</entry>", range: start.upperBound..<xml.endIndex)
        else {
            throw NetworkGuard.NetworkError.badResponse("订阅里没有 Release")
        }
        let entry = xml[start.upperBound..<end.lowerBound]
        guard let tag = tag(fromAtomEntry: String(entry)) else {
            throw NetworkGuard.NetworkError.badResponse("Release 没有 tag")
        }
        return release(for: tag)
    }

    /// 优先从 `/releases/tag/<tag>` 链里取，避免用到 feed 级 `<title>`。
    static func tag(fromAtomEntry entry: String) -> String? {
        let marker = "/releases/tag/"
        if let range = entry.range(of: marker) {
            let rest = entry[range.upperBound...]
            let tag = rest.prefix(while: { ch in
                ch != "\"" && ch != "'" && ch != "<" && ch != ">" && !ch.isWhitespace
            })
            if !tag.isEmpty { return String(tag) }
        }
        if let t0 = entry.range(of: "<title"),
           let gt = entry[t0.upperBound...].firstIndex(of: ">"),
           let t1 = entry.range(of: "</title>", range: gt..<entry.endIndex) {
            let title = entry[entry.index(after: gt)..<t1.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }

    public static func parseSHA256(_ text: String) -> String? {
        guard let token = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hex = token.lowercased()
        guard hex.count == 64, hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return nil
        }
        return hex
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 拉最新 Release。`fetch` 注入是为了单测不联网。
    public static func check(
        current: String = AibarVersion.current,
        fetch: (() async throws -> Data)? = nil
    ) async throws -> Status {
        let data: Data
        if let fetch {
            data = try await fetch()
        } else {
            data = try await NetworkGuard.send(
                url: latestFeedURL,
                headers: ["Accept": "application/atom+xml"])
        }
        let release = try parseAtom(data)
        return isNewer(release.version, than: current)
            ? .available(release)
            : .upToDate
    }

    /// 下载 DMG，有 sha256 文件就校验。返回落盘路径给安装脚本用。
    public static func downloadAndVerify(
        _ release: Release,
        to directory: URL = FileManager.default.temporaryDirectory,
        fetch: ((URL) async throws -> Data)? = nil
    ) async throws -> URL {
        let pull: (URL) async throws -> Data = fetch ?? { url in
            try await NetworkGuard.send(url: url, timeout: 120)
        }
        let data = try await pull(release.dmgURL)
        if let shaURL = release.sha256URL {
            let raw = String(data: try await pull(shaURL), encoding: .utf8) ?? ""
            guard let expected = parseSHA256(raw) else {
                throw NetworkGuard.NetworkError.badResponse("无法解析 sha256 文件")
            }
            let actual = sha256(of: data)
            guard actual == expected else {
                throw NetworkGuard.NetworkError.badResponse("安装包校验失败")
            }
        }
        let dest = directory.appendingPathComponent("aibar-\(release.tag).dmg")
        try data.write(to: dest, options: .atomic)
        return dest
    }
}

/// 用系统自带的 hdiutil / ditto 替换正在运行的 .app，然后拉起新进程。
///
/// 替换必须等当前进程退出，所以这里只负责把脚本丢到后台，
/// 调用方随后 `NSApplication.terminate`。
public enum AppInstaller {
    public static func launchReplacement(dmg: URL, destination: URL, pid: Int32) throws {
        let script = """
        #!/bin/bash
        set -euo pipefail
        PID="$1"
        DMG="$2"
        DEST="$3"
        MOUNT=$(mktemp -d /tmp/aibar-update-XXXX)
        cleanup() { hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; rm -rf "$MOUNT"; }
        trap cleanup EXIT
        for _ in $(seq 1 50); do
          kill -0 "$PID" 2>/dev/null || break
          sleep 0.2
        done
        hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
        APP=$(find "$MOUNT" -maxdepth 1 -name '*.app' -print -quit)
        if [ -z "$APP" ]; then
          echo "dmg 里没有 .app" >&2
          exit 1
        fi
        rm -rf "$DEST"
        /usr/bin/ditto "$APP" "$DEST"
        xattr -dr com.apple.quarantine "$DEST" || true
        /usr/bin/open "$DEST"
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-apply-update.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [url.path, "\(pid)", dmg.path, destination.path]
        try proc.run()
    }

    public static var runningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
