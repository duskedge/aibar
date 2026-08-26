import Foundation

/// 手写的 ISO8601 UTC 解析器。
///
/// 用 `ISO8601DateFormatter` 解析上百万行会成为热点，而且它对
/// “有没有小数秒” 还得配两套实例。这里直接按字节算，形如
/// `2026-08-20T09:57:56.668Z`，只认 UTC（三家日志都是 Z 结尾）。
public enum DateParsing {
    public static func iso8601UTC(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 19 else { return nil }

        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<(from + len) {
                let c = b[i]
                guard c >= 0x30, c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }
        guard b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54 || b[10] == 0x20,
              b[13] == 0x3A, b[16] == 0x3A,
              let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2)
        else { return nil }

        var fraction = 0.0
        if b.count > 19, b[19] == 0x2E {  // '.'
            var i = 20, scale = 0.1
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                fraction += Double(b[i] - 0x30) * scale
                scale /= 10
                i += 1
            }
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let secs = Double(days * 86_400 + hour * 3600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: secs)
    }

    /// Howard Hinnant 的 days_from_civil：不建 Calendar 就能算出距 1970-01-01 的天数。
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
