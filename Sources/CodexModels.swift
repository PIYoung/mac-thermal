import Foundation
import CoreFoundation

enum CodexQuotaConnection: String {
    case disconnected, disconnecting, connecting, authorizing, connected, unavailable, needsLogin, helperMissing
}

struct CodexQuotaWindow: Equatable {
    let slot: Int
    let usedPercent: Double
    let durationMinutes: Int?
    let resetsAt: Date?

    func remaining(at now: Date) -> Double? {
        guard usedPercent.isFinite, (0...100).contains(usedPercent),
              resetsAt.map({ $0 > now }) ?? true else { return nil }
        return 100 - usedPercent
    }
}

/// Account numbers only. Login codes, URLs, account IDs and credentials never
/// enter a monitor snapshot or a menu/rendering cache.
struct CodexQuotaSnapshot: Equatable {
    var connection: CodexQuotaConnection = .disconnected
    var windows: [CodexQuotaWindow] = []
    var fetchedAt: Date?
    var blocked = false
    var usage = CodexUsageSnapshot()

    var isEnabled: Bool { connection != .disconnected }
    func isFresh(at now: Date) -> Bool {
        guard connection == .connected, let fetchedAt else { return false }
        return (-5...180).contains(now.timeIntervalSince(fetchedAt))
    }
    func remaining(at now: Date) -> Double? {
        guard isFresh(at: now), !blocked else { return nil }
        let values = windows.compactMap { $0.remaining(at: now) }
        guard values.count == windows.count else { return nil }
        return values.min()
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    static func parse(_ result: [String: Any], now: Date) -> Self {
        // Prefer the metered Codex bucket. A different named bucket must never
        // be relabeled as Codex, even when it is the only map entry.
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let candidate = (buckets?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any])
        guard let candidate,
              (candidate["limitId"] as? String).map({ $0 == "codex" }) ?? true else {
            return Self(connection: .unavailable)
        }
        var snapshot = Self(connection: .connected, fetchedAt: now)
        snapshot.blocked = (result["ordinaryUsageAllowed"] as? Bool) == false ||
            (candidate["rateLimitReachedType"] as? String).map({ !$0.isEmpty }) == true ||
            (candidate["spendControlReached"] as? Bool) == true
        for (slot, name) in ["primary", "secondary"].enumerated() {
            guard candidate[name] != nil, !(candidate[name] is NSNull) else { continue }
            guard let window = candidate[name] as? [String: Any],
                  let used = number(window["usedPercent"]), (0...100).contains(used) else { return Self(connection: .unavailable) }
            let minutes = number(window["windowDurationMins"]).flatMap {
                $0.rounded() == $0 && (1...527_040).contains($0) ? Int($0) : nil
            }
            let reset = number(window["resetsAt"]).flatMap {
                $0.rounded() == $0 && (1...4_102_444_800).contains($0) ? Date(timeIntervalSince1970: $0) : nil
            }
            snapshot.windows.append(CodexQuotaWindow(slot: slot, usedPercent: used,
                                                     durationMinutes: minutes, resetsAt: reset))
        }
        return snapshot
    }
}

enum CodexUsageState { case disabled, loading, ready, unavailable }
struct CodexDailyUsage: Equatable {
    let day: String
    let tokens: Int64?
}
struct CodexUsageSnapshot: Equatable {
    var state: CodexUsageState = .disabled
    var days: [CodexDailyUsage] = []
    var fetchedAt: Date?

    func isFresh(at now: Date) -> Bool {
        guard state == .ready, let fetchedAt else { return false }
        return (-5...900).contains(now.timeIntervalSince(fetchedAt))
    }
    static func parse(_ result: [String: Any], now: Date) -> Self {
        guard let rows = result["dailyUsageBuckets"] as? [[String: Any]], rows.count <= 4096 else { return Self(state: .unavailable) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = formatter.timeZone
        let today = calendar.startOfDay(for: now)
        let keys = (0..<7).map { formatter.string(from: calendar.date(byAdding: .day, value: $0 - 6, to: today)!) }
        var values: [String: Int64] = [:], conflicts = Set<String>()
        for row in rows {
            guard let day = row["startDate"] as? String, day.utf8.count == 10,
                  let date = formatter.date(from: day), formatter.string(from: date) == day, keys.contains(day),
                  let tokens = CodexQuotaSnapshot.number(row["tokens"]), tokens.rounded() == tokens,
                  (0...9_007_199_254_740_991).contains(tokens) else { continue }
            let count = Int64(tokens)
            if let previous = values[day], previous != count { conflicts.insert(day) }
            values[day] = count
        }
        return Self(state: .ready, days: keys.map { CodexDailyUsage(day: $0, tokens: conflicts.contains($0) ? nil : values[$0]) }, fetchedAt: now)
    }
}

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
    var quota = CodexQuotaSnapshot()

    static var pending: Self { Self() }
}
