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

/// Only numeric usage and runtime metadata reach the view. No credentials,
/// conversation text, tool arguments, working directories or task titles.
struct CodexMonitorSnapshot {
    var appStartedAt: Date?
    var connection: CodexConnectionState = .notRunning
    var recordsEnabled = false
    /// UTC-today numeric usage records accepted from this Mac, not file count.
    var recordsCount: Int?
    var lastRecordAt: Date?
    var incomplete = false
    var currentModel: String?
    /// UTC-today totals from local records; not the whole account's usage.
    var dailyTokens: Int64?
    var models: [CodexModelUsage] = []
    var updatedAt: Date?
    /// An original localized UI key, never an upstream error message.
    var noticeKey: String?

    static var pending: Self { Self() }
}
