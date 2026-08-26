import Foundation
import UserNotifications
import AibarCore

/// 额度告警通知。
///
/// 只在越过阈值的那一刻推一次 —— 常驻应用最容易惹人烦的就是重复提醒。
///
/// **不要给这个类型加 `@MainActor`。** `UNUserNotificationCenter` 的
/// 完成回调是在它自己的派发队列上调用的；一旦类型是 MainActor 隔离的，
/// 闭包会继承该隔离，Swift 并发运行时检查当前执行器时会直接
/// `dispatch_assert_queue_fail` 崩掉整个进程。用 async API 就没有这个问题。
enum Notifications {
    private static var center: UNUserNotificationCenter { .current() }

    static func requestAuthorizationIfNeeded() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func quotaAlert(quota: QuotaStatus, level: Thresholds.Level) {
        let content = UNMutableNotificationContent()
        content.title = level == .critical
            ? L("%@ 额度即将耗尽", quota.provider.displayName)
            : L("%@ 额度告警", quota.provider.displayName)

        var body = L("%@已用 %@", quota.windowDescription, Fmt.percent(quota.usedPercent))
        if let reset = quota.resetsAt, reset > .now {
            body += L("，%@后重置", Fmt.duration(reset.timeIntervalSinceNow))
        }
        content.body = body
        content.sound = level == .critical ? .default : nil

        center.add(UNNotificationRequest(
            identifier: "quota-\(quota.provider.rawValue)-\(quota.windowMinutes)-\(level)",
            content: content, trigger: nil))
    }
}
