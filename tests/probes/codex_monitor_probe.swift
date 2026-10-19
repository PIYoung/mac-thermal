import AppKit
import Foundation
import Darwin

@main
struct CodexMonitorProbe {
    static func main() throws {
        protocolAndFrames()
        observations()
        usageAndQuotas()
        try socketSecurity()
        lifecycle()
        print("Codex monitor fixtures passed: read-only methods/opt-outs, bounded frames, absent-app lifecycle, stale delivery cancellation, numeric filtering, account/model attribution baselines, dedup/rollback/thread isolation, union activity time, approval exclusion and secure socket metadata. No live daemon, credentials, conversation history, model call or account endpoint was accessed.")
    }

    private static func protocolAndFrames() {
        precondition(CodexReadProtocol.integer(true) == nil)
        precondition(CodexReadProtocol.integer(-1) == nil)
        precondition(CodexReadProtocol.integer(1.5) == nil)
        precondition(CodexReadProtocol.integer(Double.nan) == nil)
        precondition(CodexReadProtocol.integer(0) == 0)
        precondition(CodexReadProtocol.percentage(42.5) == 42.5)
        precondition(CodexReadProtocol.percentage(true) == nil)
        precondition(CodexReadProtocol.percentage(Double.nan) == nil)
        precondition(CodexReadProtocol.percentage(Double.infinity) == nil)
        precondition(CodexReadProtocol.identifier("gpt-6.1-sol") != nil)
        precondition(CodexReadProtocol.identifier("/Users/private-file") == nil)
        precondition(CodexReadProtocol.identifier("a title with text") == nil)
        for method in ["turn/start", "thread/resume", "thread/read", "thread/list", "config/write", "account/login/start", "thread/settings/update"] {
            precondition(CodexReadProtocol.request(id: 1, method: method, parameters: [:]) == nil)
        }
        precondition(CodexReadProtocol.request(id: 1, method: "thread/turns/list", parameters: ["threadId": "t", "itemsView": "summary", "limit": 1]) == nil)
        precondition(CodexReadProtocol.request(id: 1, method: "thread/turns/list", parameters: ["threadId": "t", "itemsView": "notLoaded", "limit": 1]) != nil)
        precondition(CodexReadProtocol.suppressedNotifications.contains("thread/settings/updated"))
        precondition(CodexReadProtocol.suppressedNotifications.contains("item/agentMessage/delta"))
        precondition(CodexReadProtocol.suppressedNotifications.contains("turn/completed"))
        precondition(Set(CodexReadProtocol.suppressedNotifications).isDisjoint(with: CodexReadProtocol.notifications))
        var buffer = CodexLineBuffer()
        precondition(buffer.append(Data("{\"x\":".utf8))?.isEmpty == true)
        let frames = buffer.append(Data("1}\n{\"y\":2}\n".utf8))!
        precondition(frames.count == 2 && frames[0] == Data("{\"x\":1}".utf8))
        precondition(buffer.append(Data(repeating: 65, count: CodexLineBuffer.maximumFrameBytes + 1)) == nil)
    }

    private static func observations() {
        var state = CodexObservationStore()
        let now = Date()
        state.connection(.connected, notice: nil, monotonic: 0)
        state.loadedThreads(["a", "b"], complete: true)
        precondition(state.snapshot.activeCount == nil)
        precondition(state.turns(["data": [["status": "inProgress", "itemsView": "notLoaded", "items": [], "startedAt": 1_700_000_000]]], threadID: "a", now: now))
        precondition(state.turns(["data": [["status": "completed", "itemsView": "notLoaded", "items": []]]], threadID: "b", now: now))
        precondition(state.snapshot.activeCount == nil, "inProgress alone cannot distinguish active work from approval waits")
        state.advance(monotonic: 2)
        precondition(state.snapshot.observedActiveSeconds == 0)
        state.notification(method: "thread/status/changed", parameters: ["threadId": "a", "status": ["type": "active", "activeFlags": []]])
        state.advance(monotonic: 5)
        precondition(state.snapshot.activeCount == 1 && state.snapshot.observedActiveSeconds == 3)
        state.notification(method: "thread/status/changed", parameters: ["threadId": "b", "status": ["type": "active", "activeFlags": []]])
        state.advance(monotonic: 6)
        precondition(state.snapshot.activeCount == 2 && state.snapshot.observedActiveSeconds == 4, "Parallel work counts once in active union time")
        state.notification(method: "thread/status/changed", parameters: ["threadId": "a", "status": ["type": "active", "activeFlags": ["waitingOnApproval"]]])
        state.notification(method: "thread/status/changed", parameters: ["threadId": "b", "status": ["type": "active", "activeFlags": ["waitingOnUserInput"]]])
        state.advance(monotonic: 10)
        precondition(state.snapshot.activeCount == 0 && state.snapshot.waitingCount == 2 && state.snapshot.observedActiveSeconds == 4)
        state.notification(method: "thread/status/changed", parameters: ["threadId": "a", "status": ["type": "active", "activeFlags": []]])
        state.notification(method: "model/rerouted", parameters: ["threadId": "a", "toModel": "gpt-6.1-sol"])
        precondition(state.snapshot.currentModel == "gpt-6.1-sol")
        state.advance(monotonic: 100)
        precondition(state.snapshot.observedActiveSeconds == 4, "A suspension/disconnected sampling gap is not active work")
        state.notification(method: "thread/status/changed", parameters: ["threadId": "a", "status": ["type": "idle"]])
        precondition(state.snapshot.currentModel == nil)
        precondition(state.turns(["data": [["status": "completed", "itemsView": "notLoaded", "items": [], "startedAt": 1_000]]], threadID: "a", now: now))
        state.notification(method: "thread/status/changed", parameters: ["threadId": "a", "status": ["type": "active", "activeFlags": []]])
        precondition(state.snapshot.currentStartedAt == nil, "A new active turn cannot reuse a previous terminal turn timestamp")
        state.notification(method: "thread/settings/updated", parameters: ["threadId": "a", "threadSettings": ["model": "private-title-sentinel", "cwd": "/private/path-sentinel"]])
        precondition(!String(describing: state.snapshot).contains("sentinel"))
        precondition(!state.turns(["data": [["status": "completed", "itemsView": "full", "items": []]]], threadID: "a", now: now))
        precondition(!state.turns(["data": [["status": "completed", "itemsView": "notLoaded", "items": ["private-content-sentinel"]]]], threadID: "a", now: now))
        precondition(state.turns(["data": [["status": "failed", "itemsView": "notLoaded", "items": [], "error": ["message": "private-error-sentinel"]]]], threadID: "a", now: now))
        precondition(!String(describing: state.snapshot).contains("sentinel"))
        state.connection(.unavailable, notice: nil, monotonic: 101)
        precondition(state.snapshot.activeCount == nil && state.snapshot.waitingCount == nil)
    }

    private static func usage(_ thread: String, input: Int64, cached: Int64, output: Int64, model: String = "gpt-6.1-sol") -> [String: Any] {
        ["threadUsage": ["threadId": thread, "groups": [["model": model, "inputTokens": input, "cachedInputTokens": cached, "outputTokens": output, "totalTokens": input + output]]]]
    }

    private static func usageAndQuotas() {
        var state = CodexObservationStore()
        state.loadedThreads(["a", "b"], complete: true)
        state.usage(usage("a", input: 60, cached: 20, output: 40), threadID: "a")
        precondition(state.snapshot.models.isEmpty && state.snapshot.observedTokens == 0)
        state.usage(usage("a", input: 100, cached: 25, output: 50), threadID: "a")
        state.usage(usage("a", input: 100, cached: 25, output: 50), threadID: "a")
        precondition(state.snapshot.observedTokens == 50 && state.snapshot.models[0].cachedInputTokens == 5)
        state.usage(usage("a", input: 10, cached: 0, output: 10), threadID: "a")
        state.usage(usage("a", input: 100, cached: 25, output: 50), threadID: "a")
        precondition(state.snapshot.observedTokens == 50, "Counter rollback and recovery cannot replay an already counted delta")
        state.usage(usage("a", input: 130, cached: 30, output: 70), threadID: "a")
        state.usage(usage("b", input: 60, cached: 20, output: 40), threadID: "b")
        state.usage(usage("b", input: 100, cached: 25, output: 50), threadID: "b")
        precondition(state.snapshot.observedTokens == 150 && state.snapshot.models[0].totalTokens == 150)
        state.usage(usage("wrong", input: 500, cached: 0, output: 100), threadID: "a")
        state.usage(usage("a", input: 500, cached: 0, output: 100, model: "/private/path-sentinel"), threadID: "a")
        precondition(state.snapshot.observedTokens == 150 && !String(describing: state.snapshot).contains("sentinel"))
        state.connection(.unavailable, notice: nil, monotonic: 0)
        precondition(state.snapshot.observedTokens == 150, "Unavailable display can retain clearly stale values")
        state.connection(.connecting, notice: nil, monotonic: 1)
        state.connection(.connected, notice: nil, monotonic: 2)
        state.loadedThreads(["a"], complete: true)
        state.usage(usage("a", input: 500, cached: 100, output: 500), threadID: "a")
        precondition(state.snapshot.observedTokens == 0 && state.snapshot.models.isEmpty,
            "A reconnect must baseline the disconnected gap rather than charging it as observed usage")
        let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
        state.account(["summary": ["lifetimeTokens": 123_456], "dailyUsageBuckets": [["startDate": "2026-10-19", "tokens": 789], ["startDate": "2026-10-18", "tokens": 321]]], now: now)
        precondition(state.snapshot.lifetimeTokens == 123_456 && state.snapshot.dailyTokens == 789)
        state.account(["summary": ["lifetimeTokens": NSNull()], "dailyUsageBuckets": NSNull()], now: now)
        precondition(state.snapshot.lifetimeTokens == nil && state.snapshot.dailyTokens == nil)
        state.limits(["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 0, "windowDurationMins": 300, "resetsAt": 2_000_000_000], "secondary": ["usedPercent": 60, "windowDurationMins": 10_080]]], "rateLimits": ["primary": ["usedPercent": 99]]])
        precondition(state.snapshot.quotas.count == 2 && state.snapshot.quotas.first?.usedPercent == 0)
        state.notification(method: "account/rateLimits/updated", parameters: ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 20]]])
        precondition(state.snapshot.quotas[0].usedPercent == 20 && state.snapshot.quotas[0].windowMinutes == 300 && state.snapshot.quotas[1].usedPercent == 60)
        state.notification(method: "account/rateLimits/updated", parameters: ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 42.5]]])
        precondition(state.snapshot.quotas[0].usedPercent == 42.5)
        state.limits(["rateLimits": ["primary": ["usedPercent": 101]]])
        precondition(state.snapshot.quotas.isEmpty)
        state.account(["summary": ["lifetimeTokens": 42], "dailyUsageBuckets": [["startDate": "2026-10-19", "tokens": 12]]], now: now)
        state.limits(["rateLimits": ["primary": ["usedPercent": 50]]])
        state.connection(.connecting, notice: nil, monotonic: 3)
        precondition(state.snapshot.dailyTokens == nil && state.snapshot.lifetimeTokens == nil && state.snapshot.quotas.isEmpty)
        state.appStartedAt(now)
        precondition(state.snapshot.appStartedAt == now)
        state.appStartedAt(nil)
        precondition(state.snapshot.appStartedAt == nil)
    }

    private static func socketSecurity() throws {
        // Synthetic lstat records exercise the production validator without
        // opening any real IPC endpoint or requiring sandbox network access.
        let home = URL(fileURLWithPath: "/Users/codex-fixture", isDirectory: true)
        let url = home.appendingPathComponent(".codex/app-server-control/app-server-control.sock")
        let parent = url.deletingLastPathComponent().path
        var records: [String: stat] = [:]
        var path = ""
        for (index, component) in url.pathComponents.enumerated() {
            path = component == "/" ? "/" : path == "/" ? "/" + component : path + "/" + component
            var value = stat()
            value.st_dev = 1
            value.st_ino = ino_t(index + 1)
            value.st_uid = path == home.path || path.hasPrefix(home.path + "/") ? geteuid() : 0
            value.st_mode = path == url.path ? S_IFSOCK | 0o600 : S_IFDIR | 0o700
            records[path] = value
        }
        let identity = CodexEndpointSecurity.inspect(socketURL: url, homeURL: home, readMetadata: { records[$0] })!
        precondition(CodexEndpointSecurity.unchanged(identity, readMetadata: { records[$0] }))
        precondition(CodexEndpointSecurity.inspect(socketURL: home.appendingPathComponent("arbitrary.sock"), homeURL: home, readMetadata: { records[$0] }) == nil)
        let originalParent = records[parent]!
        records[parent]?.st_mode = S_IFDIR | 0o770
        precondition(CodexEndpointSecurity.inspect(socketURL: url, homeURL: home, readMetadata: { records[$0] }) == nil)
        records[parent] = originalParent
        records[url.path]?.st_mode = S_IFSOCK | 0o660
        precondition(CodexEndpointSecurity.inspect(socketURL: url, homeURL: home, readMetadata: { records[$0] }) == nil)
        records[url.path]?.st_mode = S_IFSOCK | 0o600
        records[parent]?.st_mode = S_IFLNK | 0o700
        precondition(CodexEndpointSecurity.inspect(socketURL: url, homeURL: home, readMetadata: { records[$0] }) == nil)
        precondition(!CodexEndpointSecurity.unchanged(identity, readMetadata: { records[$0] }))
        records[parent] = originalParent
        records[parent]?.st_ino += 1
        precondition(CodexEndpointSecurity.inspect(socketURL: url, homeURL: home, readMetadata: { records[$0] }) != nil)
        precondition(!CodexEndpointSecurity.unchanged(identity, readMetadata: { records[$0] }))
        records[parent] = originalParent
        records[url.path]?.st_uid = geteuid() + 1
        precondition(CodexEndpointSecurity.inspect(socketURL: url, homeURL: home, readMetadata: { records[$0] }) == nil)
        records[url.path] = nil
        precondition(CodexEndpointSecurity.inspect(socketURL: url, homeURL: home, readMetadata: { records[$0] }) == nil)
    }

    private static func lifecycle() {
        precondition(Thread.isMainThread)
        let monitor = CodexMonitor(isRunning: { false }, launchDate: { nil }, workspaceNotificationsEnabled: false)
        var callbacks = 0
        monitor.onUpdate = { snapshot in
            precondition(Thread.isMainThread && snapshot.connection == .notRunning)
            callbacks += 1
        }
        monitor.start()
        monitor.start()
        monitor.refresh()
        monitor.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(callbacks == 0, "Queued callbacks from a stopped generation must be discarded")
        monitor.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(callbacks > 0)
        monitor.stop()
        let stopped = callbacks
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(callbacks == stopped)
    }
}
