import Foundation

public enum Fmt {
    public static func tokens(_ n: Int) -> String {
        let d = Double(n)
        return switch d {
        case 1e9...: String(format: "%.2fB", d / 1e9)
        case 1e6...: String(format: "%.1fM", d / 1e6)
        case 1e3...: String(format: "%.1fK", d / 1e3)
        default: "\(n)"
        }
    }

    /// nil 一律渲染成 —，绝不退化成 $0.00
    public static func cost(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v == 0 { return "$0" }
        return v >= 1000 ? String(format: "$%.0f", v)
             : v >= 1 ? String(format: "$%.2f", v)
             : String(format: "$%.3f", v)
    }

    public static func percent(_ v: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", v)
    }

    /// “3 天 2 小时后重置” / “12 分钟后重置”
    /// 菜单栏用的窗口简称：`5小时` / `7天`。
    public static func compactWindow(_ minutes: Int) -> String {
        if minutes >= 1440 { return "\(minutes / 1440)天" }
        if minutes >= 60 { return "\(minutes / 60)小时" }
        return "\(minutes)分"
    }

    /// 菜单栏用的倒计时：`6d21h` / `3h12m` / `45m`。
    /// 刻意用英文单位缩写 —— 中文单位在菜单栏里太占地方。
    public static func compactDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        return "\(max(1, m))m"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        let days = Int(s) / 86400
        let hours = (Int(s) % 86400) / 3600
        let minutes = (Int(s) % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天" }
        if hours > 0 { return minutes > 0 ? "\(hours) 小时 \(minutes) 分" : "\(hours) 小时" }
        return "\(max(1, minutes)) 分钟"
    }

    /// “刚刚 / 3 分钟前 / 昨天 14:20”
    public static func relative(_ date: Date, now: Date = .now) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "刚刚" }
        if delta < 3600 { return "\(Int(delta / 60)) 分钟前" }
        if delta < 86400 { return "\(Int(delta / 3600)) 小时前" }
        if delta < 86400 * 2 { return "昨天" }
        let f = DateFormatter()
        f.dateFormat = delta < 86400 * 300 ? "M月d日" : "yyyy/M/d"
        return f.string(from: date)
    }

    /// 环比。基数为 0 时返回 nil —— “从 0 涨到 100” 没有百分比可言。
    public static func delta(_ current: Double, _ previous: Double) -> String? {
        guard previous > 0 else { return nil }
        let pct = (current - previous) / previous * 100
        guard abs(pct) >= 1 else { return "持平" }
        return "\(pct > 0 ? "▲" : "▼") \(String(format: "%.0f%%", abs(pct)))"
    }
}
