import Foundation
import Testing
@testable import AibarCore

/// 本地化的静态检查。
///
/// 单测跑在没有 .lproj 的裸二进制里，查不到翻译 —— 这正好用来验证
/// **回落行为**：缺翻译时必须回落到中文原文，而不是把裸 key 漏到界面上。
/// 翻译文件本身的完整性由下面的解析检查覆盖。
@Suite("本地化")
struct LocalizationTests {

    /// 中文原文即 key，所以缺翻译时 L() 必须原样返回。
    @Test("缺翻译时回落到中文原文，不漏裸 key")
    func fallsBackToSource() {
        #expect(L("今日") == "今日")
        #expect(L("一个绝对不存在的条目") == "一个绝对不存在的条目")
    }

    @Test("带参数的格式化正确")
    func formatting() {
        #expect(L("%lld 个会话", 3) == "3 个会话")
        #expect(L("%@ tokens", "1.2M") == "1.2M tokens")
        #expect(L("%lld 天 %lld 小时", 6, 21) == "6 天 21 小时")
    }

    // MARK: - 翻译文件本身

    /// 定位仓库里的 en.lproj，测试进程的 bundle 里没有它。
    /// 从本文件位置向上找仓库根。`#filePath` 在不同构建方式下
    /// 可能是相对路径，所以先按 cwd 解析再逐级上溯。
    static var englishStrings: [String: String]? {
        var dir = URL(fileURLWithPath: #filePath, relativeTo: URL(fileURLWithPath: "."))
            .standardizedFileURL
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("Resources/en.lproj/Localizable.strings")
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            guard let data = try? Data(contentsOf: candidate),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, format: nil) as? [String: String]
            else { return nil }
            return plist
        }
        return nil
    }

    @Test("英文翻译文件能被解析")
    func englishParses() throws {
        let table = try #require(Self.englishStrings, "找不到或无法解析 en.lproj")
        #expect(table.count > 100, "条目太少，可能没加载全")
        #expect(table["今日"] == "Today")
    }

    /// key 里有几个占位符，翻译里就得有几个 —— 少一个会在
    /// String(format:) 时读到垃圾内存，多一个会崩。
    @Test("占位符数量与类型和原文一致")
    func placeholdersMatch() throws {
        let table = try #require(Self.englishStrings)
        let pattern = try NSRegularExpression(pattern: "%(?:lld|ld|d|@|f|\\.[0-9]f)")

        func specifiers(_ s: String) -> [String] {
            let range = NSRange(s.startIndex..., in: s)
            return pattern.matches(in: s, range: range).map {
                String(s[Range($0.range, in: s)!])
            }
        }

        var problems: [String] = []
        for (key, value) in table {
            let a = specifiers(key), b = specifiers(value)
            if a.sorted() != b.sorted() {
                problems.append("\(key) → \(value)（原文 \(a)，译文 \(b)）")
            }
        }
        if !problems.isEmpty { Issue.record("占位符不匹配：\n\(problems.joined(separator: "\n"))") }
    }

    /// 英文译文不该还留着中文 —— 多半是漏翻或复制粘贴。
    @Test("英文译文里没有残留中文")
    func noChineseLeftInEnglish() throws {
        let table = try #require(Self.englishStrings)
        let leftovers = table.filter { _, value in
            value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        if !leftovers.isEmpty { Issue.record("以下译文仍含中文：\(leftovers.keys.sorted())") }
    }

    /// 空译文会让界面出现空白，比没翻译更糟。
    @Test("没有空译文")
    func noEmptyTranslations() throws {
        let table = try #require(Self.englishStrings)
        let empties = table.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        if !empties.isEmpty { Issue.record("空译文：\(empties.keys.sorted())") }
    }

    @Test("语言枚举能往返编码")
    func languageRoundTrip() {
        for l in Localization.Language.allCases {
            #expect(Localization.Language(rawValue: l.rawValue) == l)
            #expect(!l.label.isEmpty)
        }
        #expect(Localization.Language.system.appleLanguages == nil)
        #expect(Localization.Language.en.appleLanguages == ["en"])
    }
}
