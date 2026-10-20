import Foundation
import Darwin

private final class FakeWire: CodexQuotaWire {
    var messages: [[String: Any]] = []
    var receiver: ((Data) -> Void)?
    var exit: (() -> Void)?
    var closed = false
    var deferredClose = false
    var closeCompletion: (() -> Void)?
    func start(message: @escaping (Data) -> Void, exited: @escaping () -> Void) -> Bool {
        receiver = message; exit = exited; return true
    }
    func send(_ data: Data) -> Bool { messages.append(try! JSONSerialization.jsonObject(with: data) as! [String: Any]); return true }
    func close(completion: @escaping () -> Void) {
        closed = true
        if deferredClose { closeCompletion = completion } else { completion() }
    }
    func receive(_ value: [String: Any]) { receiver?(try! JSONSerialization.data(withJSONObject: value)) }
    func reply(_ method: String, _ result: [String: Any]) {
        let request = messages.last { $0["method"] as? String == method }!
        receive(["id": request["id"]!, "result": result])
    }
    var methods: [String] { messages.compactMap { $0["method"] as? String } }
}

@main enum QuotaProbe {
    static func main() throws {
        if CommandLine.arguments.contains("--check-installed-signature") {
            let installed = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
            precondition(CodexInstalledQuotaWire.trustedExecutable(installed), "Installed helper must satisfy the OpenAI signing requirement")
            precondition(!CodexInstalledQuotaWire.trustedExecutable(URL(fileURLWithPath: "/usr/bin/true")))
            print("Installed helper static-signature check passed; no helper execution or account access")
        }
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        func bucket(_ used: Any = 32, reset: Any? = nil) -> [String: Any] {
            ["limitId": "codex", "primary": ["usedPercent": used, "windowDurationMins": 300,
                "resetsAt": reset ?? Int(now.timeIntervalSince1970 + 3600)],
             "secondary": ["usedPercent": 75, "windowDurationMins": 10080, "resetsAt": Int(now.timeIntervalSince1970 + 86400)]]
        }
        func result(_ value: [String: Any]) -> [String: Any] { ["rateLimits": value] }
        let valid = result(bucket())
        let snapshot = CodexQuotaSnapshot.parse(valid, now: now)
        precondition(snapshot.remaining(at: now) == 25)
        precondition(snapshot.windows.map(\.durationMinutes) == [300, 10080])
        precondition(snapshot.remaining(at: now.addingTimeInterval(181)) == nil)
        precondition(snapshot.remaining(at: now.addingTimeInterval(-6)) == nil)
        precondition(CodexQuotaSnapshot.parse(result(bucket(reset: Int(now.timeIntervalSince1970))), now: now).remaining(at: now) == nil)
        for invalid: Any in [true, -1, 101, "32"] {
            precondition(CodexQuotaSnapshot.parse(result(bucket(invalid)), now: now).remaining(at: now) == nil)
        }
        precondition(CodexQuotaSnapshot.number(NSNumber(value: Double.nan)) == nil)
        precondition(CodexQuotaSnapshot.number(true) == nil)
        var other = bucket(); other["limitId"] = "other"
        precondition(CodexQuotaSnapshot.parse(result(other), now: now).remaining(at: now) == nil)
        precondition(CodexQuotaSnapshot.parse(["rateLimits": other, "rateLimitsByLimitId": ["codex": bucket(95)]], now: now).remaining(at: now) == 5)
        for blocked in [["ordinaryUsageAllowed": false], ["spendControlReached": true], ["rateLimitReachedType": "ordinaryUsage"]] {
            var payload = valid
            if blocked["ordinaryUsageAllowed"] != nil { payload.merge(blocked) { _, new in new } }
            else { var limits = bucket(); limits.merge(blocked) { _, new in new }; payload = result(limits) }
            let value = CodexQuotaSnapshot.parse(payload, now: now)
            precondition(value.blocked && value.remaining(at: now) == nil)
        }
        let suite = "local.mac-thermal.quota-probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var made = 0, erased = 0, clock = now
        let wire = FakeWire()
        let client = CodexQuotaClient(defaults: defaults, factory: { made += 1; return wire }, erase: { erased += 1; return true }, now: { clock })
        client.startSavedConnection(); client.refresh(); client.tick()
        precondition(made == 0 && wire.messages.isEmpty, "Default-off must not start a process or contact an account")
        client.connectApproved()
        precondition(made == 1 && wire.methods == ["initialize"])
        wire.reply("initialize", [:])
        precondition(wire.methods == ["initialize", "initialized", "account/read"])
        wire.reply("account/read", ["account": NSNull()])
        precondition(wire.methods.last == "account/login/start")
        let loginID = UUID().uuidString
        var deviceCodes = 0
        client.onDeviceLogin = { url, code in
            precondition(url.absoluteString == "https://auth.openai.com/codex/device" && code == "ABCD-1234")
            deviceCodes += 1
        }
        wire.reply("account/login/start", ["type": "chatgptDeviceCode", "loginId": loginID, "userCode": "ABCD-1234", "verificationUrl": "https://auth.openai.com/codex/device"])
        precondition(deviceCodes == 1 && client.latest.connection == .authorizing)
        wire.receive(["method": "account/login/completed", "params": ["loginId": "wrong", "success": true]])
        precondition(client.latest.connection == .authorizing)
        wire.receive(["method": "account/login/completed", "params": ["loginId": loginID, "success": true]])
        wire.reply("account/read", ["account": ["type": "chatgpt", "email": "private@example.test"]])
        wire.reply("account/rateLimits/read", valid)
        precondition(client.latest.remaining(at: clock) == 25)
        precondition(!String(describing: client.latest).contains("private@example") && !String(describing: client.latest).contains("ABCD-1234"))
        let count = wire.messages.count
        client.refresh(); precondition(wire.messages.count == count, "Refresh must be throttled")
        clock = now.addingTimeInterval(16); client.refresh()
        precondition(wire.messages.count == count + 1)
        let outstanding = wire.messages.last!
        wire.receive(["id": "untrusted-request", "method": "item/commandExecution/requestApproval", "params": ["command": "do not execute"]])
        precondition((wire.messages.last?["error"] as? [String: Any])?["code"] as? Int == -32601)
        wire.deferredClose = true
        client.disconnect()
        precondition(client.latest.connection == .disconnecting && !defaults.bool(forKey: CodexQuotaClient.enabledKey))
        wire.receive(["id": outstanding["id"]!, "result": valid])
        wire.receive(["method": "account/rateLimits/updated", "params": valid])
        precondition(client.latest.connection == .disconnecting, "In-flight updates must not reconnect a disconnected client")
        wire.reply("account/logout", [:])
        precondition(erased == 0 && wire.closed, "Credential unlink must wait until the helper is closed")
        client.connectApproved(); precondition(made == 1, "Do not reconnect while old credentials are being removed")
        wire.closeCompletion?()
        precondition(erased == 1 && client.latest.connection == .disconnected && !defaults.bool(forKey: CodexQuotaClient.removalKey))
        let allowed = Set(["initialize", "initialized", "account/read", "account/login/start", "account/login/cancel", "account/rateLimits/read", "account/logout"])
        precondition(Set(wire.methods).isSubset(of: allowed))
        // Saved connections may read account/quota but must never start OAuth by themselves.
        defaults.set(true, forKey: CodexQuotaClient.enabledKey)
        let savedWire = FakeWire()
        let saved = CodexQuotaClient(defaults: defaults, factory: { savedWire }, erase: { true }, now: { now })
        saved.startSavedConnection(); savedWire.reply("initialize", [:]); savedWire.reply("account/read", ["account": NSNull()])
        precondition(saved.latest.connection == .needsLogin && !savedWire.methods.contains("account/login/start"))
        saved.stop()
        // Arbitrary device URLs and server text are rejected, without forwarding them to UI.
        for url in ["https://evil.example/codex/device", "https://auth.openai.com/codex/device?secret=x", "http://auth.openai.com/codex/device"] {
            let bad = FakeWire()
            let account = CodexQuotaClient(defaults: defaults, factory: { bad }, erase: { true }, now: { now })
            account.onDeviceLogin = { _, _ in preconditionFailure("Untrusted URL reached UI") }
            account.connectApproved(); bad.reply("initialize", [:]); bad.reply("account/read", ["account": NSNull()])
            bad.reply("account/login/start", ["type": "chatgptDeviceCode", "loginId": UUID().uuidString, "userCode": "1234-5678", "verificationUrl": url])
            precondition(account.latest.connection == .unavailable)
            account.stop()
        }
        defaults.set(false, forKey: CodexQuotaClient.enabledKey)
        defaults.set(true, forKey: CodexQuotaClient.removalKey)
        var cleanupStarts = 0, cleanups = 0
        let cleanup = CodexQuotaClient(defaults: defaults, factory: { cleanupStarts += 1; return FakeWire() }, erase: { cleanups += 1; return true }, now: { now })
        cleanup.startSavedConnection()
        precondition(cleanups == 1 && cleanupStarts == 0 && !defaults.bool(forKey: CodexQuotaClient.removalKey), "Interrupted disconnect must finish cleanup without starting a helper")
        let emptyDaily = CodexUsageSnapshot.parse(["dailyUsageBuckets": []], now: now)
        precondition(emptyDaily.state == .ready && emptyDaily.days.count == 7 && emptyDaily.days.allSatisfy { $0.tokens == nil })
        let day = emptyDaily.days[3].day
        let dailyPayload: [String: Any] = ["summary": ["lifetimeTokens": 123, "private": "never retain"], "dailyUsageBuckets": [
            ["startDate": day, "tokens": 1200], ["startDate": emptyDaily.days[6].day, "tokens": 0]
        ]]
        let daily = CodexUsageSnapshot.parse(dailyPayload, now: now)
        precondition(daily.days[3].tokens == 1200 && daily.days[6].tokens == 0 && daily.days[0].tokens == nil)
        precondition(!daily.isFresh(at: now.addingTimeInterval(901)))
        precondition(!String(describing: daily).contains("never retain"))
        for bad: Any in [true, -1, 1.5, "123", NSNumber(value: Double.nan)] {
            let rejected = CodexUsageSnapshot.parse(["dailyUsageBuckets": [["startDate": day, "tokens": bad]]], now: now)
            precondition(rejected.days.allSatisfy { $0.tokens == nil })
        }
        let conflict = CodexUsageSnapshot.parse(["dailyUsageBuckets": [["startDate": day, "tokens": 1], ["startDate": day, "tokens": 2], ["startDate": "2026-02-30", "tokens": 99]]], now: now)
        precondition(conflict.days.allSatisfy { $0.tokens == nil })
        precondition(CodexUsageSnapshot.parse(["dailyUsageBuckets": NSNull()], now: now).state == .unavailable)
        let summaryPayload: [String: Any] = ["summary": ["lifetimeTokens": 123456, "peakDailyTokens": 9876, "longestRunningTurnSec": 540, "currentStreakDays": 8, "longestStreakDays": 14, "private": "DO_NOT_RETAIN"], "dailyUsageBuckets": []]
        let noSummary = CodexUsageSnapshot.parse(summaryPayload, now: now)
        precondition(noSummary.summary.isEmpty && !noSummary.summaryEnabled, "Prior daily consent must not retain extra summary fields")
        let withSummary = CodexUsageSnapshot.parse(summaryPayload, now: now, includeSummary: true)
        precondition(withSummary.summary.lifetimeTokens == 123456 && withSummary.summary.longestRunningTurnSec == 540)
        precondition(!String(describing: withSummary).contains("DO_NOT_RETAIN"))
        let summaryOnly = CodexUsageSnapshot.parse(["summary": ["currentStreakDays": 0]], now: now, includeSummary: true)
        precondition(summaryOnly.isFresh(at: now) && summaryOnly.summary.currentStreakDays == 0 && summaryOnly.days.isEmpty)
        for invalid: Any in [true, -1, 1.5, "123", NSNumber(value: Double.nan), 9_007_199_254_740_992] {
            precondition(CodexAccountSummary.parse(["lifetimeTokens": invalid]).lifetimeTokens == nil)
        }
        let split = CodexTokenBreakdown.aggregate([CodexModelUsage(model: "test", inputTokens: 100, cachedInputTokens: 75, outputTokens: 50, reasoningOutputTokens: 25, totalTokens: 150)], knownEmpty: false)!
        precondition(split.total == 150 && split.cacheFraction == 0.75 && split.reasoningFraction == 0.5)
        precondition(CodexTokenBreakdown.aggregate([CodexModelUsage(model: "test", inputTokens: 100, cachedInputTokens: 101, outputTokens: 0, totalTokens: 100)], knownEmpty: false) == nil)
        precondition(CodexTokenBreakdown.aggregate([], knownEmpty: false) == nil)
        precondition(CodexTokenBreakdown.aggregate([], knownEmpty: true)?.total == 0)
        precondition(CodexTokenBreakdown.aggregate([CodexModelUsage(model: "a", inputTokens: Int64.max, totalTokens: Int64.max), CodexModelUsage(model: "b", outputTokens: 1, totalTokens: 1)], knownEmpty: false) == nil)
        let week = CodexWeekInsight.aggregate([CodexDailyUsage(day: "one", tokens: 0), CodexDailyUsage(day: "missing", tokens: nil), CodexDailyUsage(day: "peak", tokens: 100)])
        precondition(week.count == 2 && week.total == 100 && week.average == 50 && week.peakDay == "peak")
        let statsWire = FakeWire()
        var usageClock = now
        defaults.set(true, forKey: CodexQuotaClient.enabledKey)
        let stats = CodexQuotaClient(defaults: defaults, factory: { statsWire }, erase: { true }, now: { usageClock })
        stats.startSavedConnection(); statsWire.reply("initialize", [:]); statsWire.reply("account/read", ["account": ["type": "chatgpt"]]); statsWire.reply("account/rateLimits/read", valid)
        precondition(!statsWire.methods.contains("account/usage/read"), "Quota consent must not silently enable usage statistics")
        stats.setUsageApproved(true)
        precondition(statsWire.methods.last == "account/usage/read")
        precondition((statsWire.messages.last?["params"] as? [String: Any])?.isEmpty == true, "Daily graph must not request a thread")
        statsWire.reply("account/usage/read", dailyPayload)
        precondition(stats.latest.usage.days[3].tokens == 1200 && stats.latest.connection == .connected)
        precondition(!stats.latest.usage.summaryEnabled && stats.latest.usage.summary.isEmpty)
        usageClock = now.addingTimeInterval(16)
        stats.setSummaryApproved(true)
        statsWire.reply("account/usage/read", summaryPayload)
        precondition(stats.latest.usage.summaryEnabled && stats.latest.usage.summary.lifetimeTokens == 123456)
        stats.setSummaryApproved(false)
        precondition(!stats.latest.usage.summaryEnabled && stats.latest.usage.summary.isEmpty, "Summary off immediately drops summary without disconnecting daily statistics")
        usageClock = now.addingTimeInterval(60); stats.refresh(manual: false); statsWire.reply("account/rateLimits/read", valid)
        precondition(statsWire.methods.filter { $0 == "account/usage/read" }.count == 2, "Statistics must not poll every quota tick")
        usageClock = now.addingTimeInterval(316); stats.refresh(manual: false); statsWire.reply("account/rateLimits/read", valid)
        let failedUsage = statsWire.messages.last { $0["method"] as? String == "account/usage/read" }!
        statsWire.receive(["id": failedUsage["id"]!, "error": ["code": -32601, "message": "do not expose raw private error"]])
        precondition(stats.latest.connection == .connected && stats.latest.usage.state == .unavailable, "Unsupported statistics must not break quota")
        usageClock = now.addingTimeInterval(337); stats.refresh(); statsWire.reply("account/rateLimits/read", valid)
        let lateUsage = statsWire.messages.last { $0["method"] as? String == "account/usage/read" }!
        stats.setUsageApproved(false)
        statsWire.receive(["id": lateUsage["id"]!, "result": dailyPayload])
        precondition(stats.latest.usage.state == .disabled && stats.latest.usage.days.isEmpty, "Disabled statistics must clear data and ignore late replies")
        let statsCount = statsWire.methods.filter { $0 == "account/usage/read" }.count
        usageClock = now.addingTimeInterval(900); stats.refresh(manual: false)
        precondition(statsWire.methods.filter { $0 == "account/usage/read" }.count == statsCount)
        stats.stop()
        defaults.set(true, forKey: CodexQuotaClient.usageKey)
        let resumedWire = FakeWire()
        let resumed = CodexQuotaClient(defaults: defaults, factory: { resumedWire }, erase: { true }, now: { now })
        resumed.startSavedConnection(); resumedWire.reply("initialize", [:]); resumedWire.reply("account/read", ["account": ["type": "chatgpt"]])
        precondition(resumedWire.methods.contains("account/usage/read") && !resumedWire.methods.contains("account/login/start"), "An explicitly approved saved statistics connection must resume without OAuth")
        resumed.stop()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-store-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        precondition(CodexAccountStore.clearCredential(home: root), "Absent credentials are already disconnected")
        let fd = CodexAccountStore.openDirectory(home: root, create: true)!
        var info = stat(); precondition(fstat(fd, &info) == 0 && info.st_mode & 0o777 == 0o700); close(fd)
        let store = root.appendingPathComponent("Library/Application Support/Mac Thermal/Codex Account")
        let auth = store.appendingPathComponent("auth.json")
        try Data("synthetic credential fixture".utf8).write(to: auth)
        let outside = root.appendingPathComponent("outside")
        try Data("must survive".utf8).write(to: outside)
        try FileManager.default.removeItem(at: auth)
        try FileManager.default.createSymbolicLink(at: auth, withDestinationURL: outside)
        precondition(CodexAccountStore.clearCredential(home: root))
        let surviving = try Data(contentsOf: outside)
        precondition(surviving == Data("must survive".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: store.path)
        precondition(CodexAccountStore.openDirectory(home: root, create: false) == nil && !CodexAccountStore.clearCredential(home: root), "Insecure permissions must never be reported as removed")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
        try FileManager.default.removeItem(at: store)
        try FileManager.default.createSymbolicLink(at: store, withDestinationURL: root)
        precondition(CodexAccountStore.openDirectory(home: root, create: true) == nil)
        precondition(!CodexAccountStore.clearCredential(home: root))
        print("Codex quota passed: numeric/freshness/reset/bucket boundaries, opt-in, managed login, RPC allowlist, throttle, disconnect races, isolated store and symlink rejection; synthetic only, no helper/account/network")
    }
}
