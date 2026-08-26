import Foundation
import UserNotifications
import AibarCore

/// 额度告警通知。
///
/// 只在越过阈值的那一刻推一次 —— 常驻应用最容易惹人烦的就是重复提醒。
@MainActor
enum Notifications {
    private static var center: UNUserNotificationCenter { .current() }

    static func requestAuthorizationIfNeeded() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func quotaAlert(quota: QuotaStatus, level: Thresholds.Level) {
        let content = UNMutableNotificationContent()
        content.title = level == .critical
            ? "\(quota.provider.displayName) 额度即将耗尽"
            : "\(quota.provider.displayName) 额度告警"

        var body = "\(quota.windowDescription)已用 \(Fmt.percent(quota.usedPercent))"
        if let reset = quota.resetsAt, reset > .now {
            body += "，\(Fmt.duration(reset.timeIntervalSinceNow))后重置"
        }
        content.body = body
        content.sound = level == .critical ? .default : nil

        center.add(UNNotificationRequest(
            identifier: "quota-\(quota.provider.rawValue)-\(quota.windowMinutes)-\(level)",
            content: content, trigger: nil))
    }
}
