import CryptoKit
import Foundation

/// 从 GitHub Release 检查 / 下载新版本。
///
/// 不引入 Sparkle：零第三方依赖是这个项目的产品承诺。
/// 元数据走 `api.github.com`，安装包走 `github.com`（会 302 到 githubusercontent）。
/// 都不带凭据，离线模式下一律短路。
public enum AppUpdate {
    public static let owner = "duskedge"
    public static let repo = "aibar"
    public static let defaultMinInterval: TimeInterval = 86_400

    public static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
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

    /// GitHub `releases/latest` 的 JSON。草稿和预发布 GitHub 自己会跳过。
    public static func parseRelease(_ data: Data) throws -> Release {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkGuard.NetworkError.badResponse("Release 响应不是对象")
        }
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true {
            throw NetworkGuard.NetworkError.badResponse("最新 Release 是草稿或预发布")
        }
        let tag = (root["tag_name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !tag.isEmpty else {
            throw NetworkGuard.NetworkError.badResponse("Release 没有 tag_name")
        }
        let assets = root["assets"] as? [[String: Any]] ?? []
        func asset(_ pred: (String) -> Bool) -> URL? {
            for item in assets {
                guard let name = item["name"] as? String, pred(name),
                      let raw = item["browser_download_url"] as? String,
                      let url = URL(string: raw) else { continue }
                return url
            }
            return nil
        }
        guard let dmg = asset({ $0.hasSuffix(".dmg") && !$0.hasSuffix(".sha256") }) else {
            throw NetworkGuard.NetworkError.badResponse("Release 里没有 DMG")
        }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return Release(
            version: version,
            tag: tag,
            notes: root["body"] as? String ?? "",
            dmgURL: dmg,
            sha256URL: asset { $0.hasSuffix(".dmg.sha256") || $0.hasSuffix(".sha256") },
            htmlURL: (root["html_url"] as? String).flatMap(URL.init(string:)))
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
                url: latestReleaseURL,
                headers: [
                    "Accept": "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28",
                ])
        }
        let release = try parseRelease(data)
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
