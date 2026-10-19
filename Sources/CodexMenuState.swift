import Foundation

/// A new local usage record triggers a bounded activity gesture. Neither app runtime
/// nor a recent timestamp is treated as evidence of a task's live state.
struct CodexMenuActivity {
    static let activityDuration: TimeInterval = 10
    private(set) var snapshot = CodexMonitorSnapshot.pending
    private(set) var gestureEndsAt: TimeInterval = 0
    private var hasBaseline = false
    private var observingSince: Date?

    var isVisible: Bool { snapshot.appStartedAt != nil }
    var canShowUsage: Bool { isVisible && snapshot.recordsEnabled && snapshot.connection == .connected }
    var tokens: Int64? {
        guard canShowUsage, let value = snapshot.dailyTokens, value >= 0,
              !(snapshot.incomplete && value == 0) else { return nil }
        return value
    }
    func recentLabel(now: Date) -> String {
        guard snapshot.recordsEnabled else { return L10n.text("읽기 꺼짐") }
        guard snapshot.connection == .connected else {
            return L10n.text(snapshot.connection == .connecting ? "확인 중" : "읽기 불가")
        }
        guard let last = snapshot.lastRecordAt else { return L10n.text("기록 없음") }
        let age = now.timeIntervalSince(last)
        guard age.isFinite, age >= -5 else { return L10n.text("확인 중") }
        if age < 60 { return L10n.text("방금 기록") }
        if age < 3_600 { return L10n.format("%lld분 전", Int64(age / 60)) }
        if age < 86_400 { return L10n.format("%lld시간 전", Int64(age / 3_600)) }
        return L10n.format("%lld일 전", Int64(min(999, age / 86_400)))
    }
    func isAnimating(at uptime: TimeInterval) -> Bool {
        canShowUsage && uptime < gestureEndsAt
    }
    mutating func cancelGesture() { gestureEndsAt = 0 }
    mutating func receive(_ next: CodexMonitorSnapshot, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let previous = snapshot
        let wasReadable = canShowUsage
        snapshot = next
        defer { hasBaseline = true }
        guard canShowUsage else { observingSince = nil; cancelGesture(); return }
        if !wasReadable || previous.appStartedAt != next.appStartedAt {
            observingSince = now
            cancelGesture()
        }
        // Initial scans, old catch-up records, repeated snapshots, counter-only
        // corrections and app relaunches must not masquerade as new activity.
        guard hasBaseline, wasReadable, previous.appStartedAt == next.appStartedAt,
              let last = next.lastRecordAt, let observingSince, last > observingSince,
              previous.lastRecordAt.map({ last > $0 }) ?? (previous.recordsCount == 0),
              let count = tokens, let oldCount = previous.dailyTokens, count != oldCount,
              (0...30).contains(now.timeIntervalSince(last)) else { return }
        gestureEndsAt = uptime + Self.activityDuration
    }
}
