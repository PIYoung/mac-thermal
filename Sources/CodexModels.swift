import Foundation

enum CodexConnectionState: String {
    case notRunning, connecting, connected, unavailable
}

struct CodexModelUsage: Equatable {
    var model: String
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var reasoningOutputTokens: Int64 = 0
    var totalTokens: Int64 = 0
}

struct CodexQuota: Equatable {
    var name: String
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
}

/// Only numeric usage and runtime metadata reach the view. No credentials,
/// conversation text, tool arguments, working directories or task titles.
struct CodexMonitorSnapshot {
    var appStartedAt: Date?
    var connection: CodexConnectionState = .notRunning
    var activeCount: Int?
    var waitingCount: Int?
    var currentModel: String?
    var currentStartedAt: Date?
    var observedActiveSeconds: TimeInterval = 0
    var observedTokens: Int64 = 0
    var observedSince: Date = Date()
    var dailyTokens: Int64?
    var lifetimeTokens: Int64?
    var models: [CodexModelUsage] = []
    var quotas: [CodexQuota] = []
    var updatedAt: Date?
    /// An original localized UI key, never an upstream error message.
    var noticeKey: String?

    static var pending: Self { Self() }
}
