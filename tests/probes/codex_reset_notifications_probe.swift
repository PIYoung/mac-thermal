import Foundation

final class FakeResetNotifications: CodexResetNotificationTransport {
    var permissionValue = CodexResetPermission.allowed
    var permissions = 0, requests = 0, posts = 0, clears = 0
    var requestReplies: [(CodexResetPermission) -> Void] = []
    var postReplies: [(Bool) -> Void] = []
    func permission(_ completion: @escaping (CodexResetPermission) -> Void) { permissions += 1; completion(permissionValue) }
    func requestPermission(_ completion: @escaping (CodexResetPermission) -> Void) { requests += 1; requestReplies.append(completion) }
    func postReset(_ completion: @escaping (Bool) -> Void) { posts += 1; postReplies.append(completion) }
    func clearReset() { clears += 1 }
}
@main enum ResetNotificationProbe {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        guard value() else { fputs("Reset notification probe failed at \(line): \(message)\n", stderr); exit(1) }
        count += 1
    }
    static func main() {
        let origin = Date(timeIntervalSince1970: 1_792_000_000)
        func date(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
        func sample(_ seconds: Double, reset: Double = 60, used: Double = 100, duration: Int = 300, blocked: Bool = false) -> CodexQuotaSnapshot {
            CodexQuotaSnapshot(connection: .connected, windows: [CodexQuotaWindow(slot: 0, usedPercent: used, durationMinutes: duration, resetsAt: date(reset))], fetchedAt: date(seconds), blocked: blocked)
        }
        var detector = CodexQuotaResetDetector()
        check(!detector.receive(sample(0), at: date(0)), "First sample establishes a baseline without alerting")
        check(!detector.receive(sample(61), at: date(61)), "Expired countdown alone is never reset proof")
        check(detector.receive(sample(62, reset: 360, used: 4), at: date(62)), "Fresh server-confirmed next window alerts")
        check(!detector.receive(sample(63, reset: 360, used: 4), at: date(63)), "Repeated window does not alert twice")
        check(!detector.receive(sample(20, reset: 420), at: date(64)), "Old fetched response cannot advance a baseline")
        check(!detector.receive(sample(65, reset: 120), at: date(65)), "Regressed deadline cannot rewind the baseline")
        check(!detector.receive(sample(200, reset: 720), at: date(200)), "Deadline extension before expiry is not a reset")
        check(!detector.receive(sample(361, reset: 720), at: date(361)), "Old expiry after extension cannot alert")
        check(detector.receive(sample(721, reset: 1080), at: date(721)), "Subsequent genuine reset alerts again")
        detector.clear()
        _ = detector.receive(sample(0), at: date(0))
        check(!detector.receive(sample(61, reset: 360, blocked: true), at: date(61)), "Blocked account never reports regained quota")
        check(!detector.receive(sample(62, reset: 360), at: date(62)), "Unblocking the same observed window is not a new reset")
        detector.clear(); _ = detector.receive(sample(0), at: date(0))
        check(!detector.receive(sample(61, reset: 360, duration: 10080), at: date(61)), "Changed window duration establishes a new baseline")
        detector.clear(); _ = detector.receive(sample(0), at: date(0))
        check(!detector.receive(sample(61, reset: 360), at: date(300)), "Stale responses do not notify")
        check(!detector.receive(sample(1000, reset: 1360), at: date(1000)), "Long sleep does not produce a catch-up alert")
        detector.clear(); _ = detector.receive(sample(0), at: date(0))
        var missing = sample(61, reset: 360); missing.windows = []
        check(!detector.receive(missing, at: date(61)), "Missing windows do not notify")
        check(!detector.receive(sample(62, reset: 360), at: date(62)), "Reappearing window has no inherited baseline")
        for state: CodexQuotaConnection in [.disconnected, .disconnecting, .needsLogin, .authorizing] {
            detector.clear(); _ = detector.receive(sample(0), at: date(0))
            var signedOut = CodexQuotaSnapshot(); signedOut.connection = state
            _ = detector.receive(signedOut, at: date(60))
            check(!detector.receive(sample(61, reset: 360), at: date(61)), "Account boundary clears previous baselines")
        }
        detector.clear(); _ = detector.receive(sample(0), at: date(0))
        _ = detector.receive(CodexQuotaSnapshot(connection: .unavailable), at: date(61))
        check(detector.receive(sample(62, reset: 360), at: date(62)), "Short transient failure can recover a confirmed reset")
        detector.clear(); _ = detector.receive(sample(0), at: date(0))
        var duplicate = sample(61, reset: 360); duplicate.windows.append(duplicate.windows[0])
        check(!detector.receive(duplicate, at: date(61)), "Duplicate slots cannot prove reset")
        var invalid = sample(62, reset: 360); invalid.windows = [CodexQuotaWindow(slot: 0, usedPercent: .nan, durationMinutes: 300, resetsAt: date(360))]
        check(!detector.receive(invalid, at: date(62)), "Invalid numeric payload is ignored")
        detector.clear()
        var both = sample(0); both.windows.append(CodexQuotaWindow(slot: 1, usedPercent: 100, durationMinutes: 10080, resetsAt: date(60)))
        _ = detector.receive(both, at: date(0))
        both = sample(61, reset: 360); both.windows.append(CodexQuotaWindow(slot: 1, usedPercent: 0, durationMinutes: 10080, resetsAt: date(7200)))
        check(detector.receive(both, at: date(61)), "Simultaneous two-window reset is one boolean event")
        check(!detector.receive(both, at: date(62)), "Simultaneous event is consumed once")
        let suite = "mac-thermal.reset-alert-probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var current = date(0)
        let wire = FakeResetNotifications()
        let client = CodexResetNotifications(defaults: defaults, transport: wire, now: { current })
        client.start(); client.receive(sample(0))
        check(wire.permissions == 0 && wire.requests == 0 && wire.posts == 0 && !client.enabled, "Default off: no permission query/request or notification")
        client.setEnabled(true)
        check(client.requesting && !client.enabled && wire.requests == 1, "Only explicit enable requests permission")
        wire.requestReplies.removeFirst()(.allowed)
        check(client.enabled && defaults.bool(forKey: CodexResetNotifications.enabledKey) && wire.posts == 0, "Permission approval enables without initial alert")
        current = date(61); client.receive(sample(61, reset: 360))
        check(wire.posts == 1, "Confirmed reset posts one generic notification")
        client.receive(sample(61, reset: 360))
        check(wire.posts == 1, "Repeated account updates do not duplicate delivery")
        client.setEnabled(false)
        wire.postReplies.removeFirst()(true)
        check(!client.enabled && wire.clears >= 2 && !defaults.bool(forKey: CodexResetNotifications.enabledKey), "Off clears alerts, including late delivery completion")
        client.setEnabled(true); client.setEnabled(false)
        wire.requestReplies.removeFirst()(.allowed)
        check(!client.enabled, "Late permission approval after off cannot enable alerts")
        client.setEnabled(true); wire.requestReplies.removeFirst()(.denied)
        check(!client.enabled && client.statusKey == "macOS 설정에서 알림을 허용하세요", "Denied permission is truthful and stays off")
        defaults.set(true, forKey: CodexResetNotifications.enabledKey)
        let restartWire = FakeResetNotifications()
        let restart = CodexResetNotifications(defaults: defaults, transport: restartWire, now: { current })
        restart.start(); restart.receive(sample(61, reset: 360))
        check(restartWire.permissions == 1 && restartWire.requests == 0 && restartWire.posts == 0 && restart.enabled, "Saved opt-in checks permission without a prompt or launch alert")
        current = date(361); restart.receive(sample(361, reset: 720))
        restartWire.postReplies.removeFirst()(false)
        check(restart.statusKey == "리셋 알림을 전달하지 못했습니다", "Delivery failure is reported without inventing success")
        restart.stop(); current = date(721); restart.receive(sample(721, reset: 1080))
        current = date(1081); restart.receive(sample(1081, reset: 1440))
        check(restartWire.posts == 1 && !restart.enabled, "Stop prevents all later reset deliveries while preserving the saved preference")
        print("Codex reset notification probe PASS (\(count) checks; synthetic quota and notification transport only; no real permission prompt, account query or notification)")
    }
}
