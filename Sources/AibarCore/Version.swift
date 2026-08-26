import Foundation

/// 版本号的唯一来源。
///
/// `scripts/build-app.sh` 从这里读出来盖进 Info.plist，
/// 发布流程会校验 git 标签与它一致 —— 版本号散在几处迟早对不上。
public enum AibarVersion {
    public static let current = "0.5.0"
}
