import Foundation

public enum Provider: String, Sendable, CaseIterable, Codable {
    case claudeCode = "claude"
    case codex
    case grok

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }
}
