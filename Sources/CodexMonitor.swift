import AppKit
import Foundation
import Darwin
import Security

enum CodexReadProtocol {
    static let methods: Set<String> = ["initialize", "account/usage/read", "account/rateLimits/read", "thread/loaded/list", "thread/turns/list"]
    static let notifications: Set<String> = ["thread/status/changed", "thread/tokenUsage/updated", "account/rateLimits/updated", "model/rerouted"]
    // Exact opt-outs from the bundled 0.162 protocol. Unknown future events are
    // also discarded locally; no generic event, payload or upstream error is logged.
    static let suppressedNotifications = [
        "error", "thread/started", "thread/archived", "thread/deleted", "thread/unarchived", "thread/closed", "thread/reverted",
        "skills/changed", "thread/name/updated", "thread/attachment/updated", "thread/goal/updated", "thread/prediction/updated",
        "thread/goal/cleared", "thread/queue/changed", "project/changed", "thread/project/updated", "thread/environment/connected",
        "thread/environment/disconnected", "thread/settings/updated", "turn/started", "hook/started", "turn/completed", "hook/completed",
        "turn/diff/updated", "turn/plan/updated", "item/started", "item/autoApprovalReview/started", "item/autoApprovalReview/completed",
        "autoApprovalReview/strictReviewRequired", "item/completed", "item/agentMessage/delta", "item/plan/delta", "command/exec/outputDelta",
        "process/outputDelta", "process/exited", "item/commandExecution/outputDelta", "item/commandExecution/terminalInteraction",
        "item/fileChange/outputDelta", "item/fileChange/patchUpdated", "serverRequest/resolved", "item/mcpToolCall/progress",
        "mcpServer/oauthLogin/completed", "mcpServer/startupStatus/updated", "mcpServer/event/stream/notification", "account/updated",
        "account/gatewayOAuth/changed", "app/list/updated", "remoteControl/status/changed", "externalAgentConfig/import/progress",
        "externalAgentConfig/import/completed", "fs/changed", "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded",
        "item/reasoning/textDelta", "thread/compacted", "model/verification", "modelProvider/authRecoveryStarted",
        "modelProvider/authRecoveryCompleted", "turn/moderationMetadata", "model/safetyBuffering/updated", "warning", "guardianWarning",
        "deprecationNotice", "configWarning", "fuzzyFileSearch/sessionUpdated", "fuzzyFileSearch/sessionCompleted", "thread/realtime/started",
        "thread/realtime/itemAdded", "thread/realtime/item/started", "thread/realtime/item/transcript/delta", "thread/realtime/item/completed",
        "thread/realtime/transcript/delta", "thread/realtime/transcript/done", "thread/realtime/outputAudio/delta", "thread/realtime/sdp",
        "thread/realtime/error", "thread/realtime/closed", "windows/worldWritableWarning", "windowsSandbox/setupCompleted", "account/login/completed"
    ]

    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int64.max), number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.int64Value
    }

    static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 80,
              !value.contains(".."), value.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
              }) else { return nil }
        return value
    }

    static func percentage(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...100).contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }

    static func request(id: Int, method: String, parameters: [String: Any]) -> Data? {
        guard methods.contains(method) else { return nil }
        if method == "thread/turns/list" {
            guard parameters["itemsView"] as? String == "notLoaded", integer(parameters["limit"]) == 1,
                  identifier(parameters["threadId"]) != nil else { return nil }
        }
        if method == "account/usage/read", let thread = parameters["threadId"], identifier(thread) == nil { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": parameters]), data.count <= 16_384 else { return nil }
        return data + Data([10])
    }

    static func add(_ left: Int64, _ right: Int64) -> Int64 {
        let result = left.addingReportingOverflow(right)
        return result.overflow ? Int64.max : result.partialValue
    }
}

struct CodexLineBuffer {
    private var pending = Data()
    static let maximumFrameBytes = 262_144
    mutating func append(_ bytes: Data) -> [Data]? {
        guard bytes.count <= Self.maximumFrameBytes, pending.count + bytes.count <= Self.maximumFrameBytes * 2 else { return nil }
        pending.append(bytes)
        var result: [Data] = []
        while let end = pending.firstIndex(of: 10) {
            guard end <= Self.maximumFrameBytes else { return nil }
            if end > 0 { result.append(Data(pending[..<end])) }
            pending.removeSubrange(...end)
        }
        return pending.count <= Self.maximumFrameBytes ? result : nil
    }
}

struct CodexSocketIdentity: Equatable {
    struct Node: Equatable {
        let path: String
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let mode: mode_t
    }
    let url: URL
    let nodes: [Node]
}

enum CodexEndpointSecurity {
    static func metadata(_ path: String) -> stat? {
        var value = stat()
        return lstat(path, &value) == 0 ? value : nil
    }

    static func inspect(socketURL: URL, homeURL: URL,
                        readMetadata: (String) -> stat? = metadata) -> CodexSocketIdentity? {
        let home = homeURL.path
        let allowed = [home + "/.codex/app-server-control/app-server-control.sock", home + "/.codex/app-server-control.sock"]
        guard socketURL.isFileURL, allowed.contains(socketURL.path), socketURL.path.utf8.count < 104 else { return nil }
        var nodes: [CodexSocketIdentity.Node] = []
        var path = ""
        for component in socketURL.pathComponents {
            path = component == "/" ? "/" : path == "/" ? "/" + component : path + "/" + component
            guard let value = readMetadata(path), value.st_mode & S_IFMT != S_IFLNK else { return nil }
            let isSocket = path == socketURL.path
            if isSocket {
                guard value.st_mode & S_IFMT == S_IFSOCK, value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else { return nil }
            } else {
                guard value.st_mode & S_IFMT == S_IFDIR else { return nil }
                if path == home || path.hasPrefix(home + "/") {
                    guard value.st_uid == geteuid(), value.st_mode & 0o022 == 0 else { return nil }
                } else {
                    // System ancestors may use the conventional root-owned
                    // sticky temporary directory; no writable non-sticky ancestor.
                    guard value.st_uid == 0 || value.st_uid == geteuid(),
                          value.st_mode & 0o022 == 0 || (value.st_uid == 0 && value.st_mode & S_ISVTX != 0) else { return nil }
                }
            }
            nodes.append(.init(path: path, device: value.st_dev, inode: value.st_ino, owner: value.st_uid, mode: value.st_mode))
        }
        return CodexSocketIdentity(url: socketURL, nodes: nodes)
    }

    static func current() -> CodexSocketIdentity? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".codex/app-server-control/app-server-control.sock", ".codex/app-server-control.sock"].compactMap {
            inspect(socketURL: home.appendingPathComponent($0), homeURL: home)
        }.first
    }

    static func unchanged(_ identity: CodexSocketIdentity, readMetadata: (String) -> stat? = metadata) -> Bool {
        identity.nodes.allSatisfy { node in
            guard let current = readMetadata(node.path) else { return false }
            return current.st_dev == node.device && current.st_ino == node.inode &&
                current.st_uid == node.owner && current.st_mode == node.mode
        }
    }

    static func installedCLI() -> URL? {
        for path in [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ] {
            var value = stat()
            guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
                  value.st_uid == 0 || value.st_uid == geteuid(), value.st_mode & 0o022 == 0,
                  value.st_mode & 0o111 != 0 else { continue }
            var code: SecStaticCode?
            var requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
                  let code,
                  SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"" as CFString, [], &requirement) == errSecSuccess,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate).union(.noNetworkAccess), requirement) == errSecSuccess else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

struct CodexObservationStore {
    enum Activity { case unknown, idle, active, waiting }
    private enum QuotaSelection { case identified(String), legacy }
    struct ThreadMetadata {
        var activity: Activity = .unknown
        var startedAt: Date?
        var routedModel: String?
    }
    struct Counters: Equatable {
        var input: Int64, cached: Int64, output: Int64, total: Int64
        func delta(after old: Counters) -> Counters? {
            guard input >= old.input, cached >= old.cached, output >= old.output, total >= old.total else { return nil }
            return Counters(input: input - old.input, cached: cached - old.cached, output: output - old.output, total: total - old.total)
        }
    }
    private(set) var snapshot = CodexMonitorSnapshot.pending
    private var threads: [String: ThreadMetadata] = [:]
    private var loaded = Set<String>()
    private var completeLoadedList = false
    private var baselines: [String: [String: Counters]] = [:]
    private var totals: [String: CodexModelUsage] = [:]
    private var quotaWindows: [String: CodexQuota] = [:]
    private var quotaSelection: QuotaSelection?
    private var lastMonotonic: TimeInterval?

    mutating func advance(monotonic: TimeInterval) {
        if let last = lastMonotonic {
            let elapsed = monotonic - last
            if elapsed >= 0, elapsed <= 15, threads.values.contains(where: { $0.activity == .active }), snapshot.connection == .connected {
                snapshot.observedActiveSeconds += elapsed
            }
        }
        lastMonotonic = monotonic
    }

    mutating func connection(_ value: CodexConnectionState, notice: String?, monotonic: TimeInterval) {
        advance(monotonic: monotonic)
        if value == .connecting {
            baselines.removeAll()
            totals.removeAll()
            snapshot.observedActiveSeconds = 0
            snapshot.observedTokens = 0
            snapshot.models = []
            snapshot.observedSince = Date()
            snapshot.dailyTokens = nil
            snapshot.lifetimeTokens = nil
            snapshot.quotas = []
            quotaWindows.removeAll()
            quotaSelection = nil
            snapshot.updatedAt = nil
        }
        snapshot.connection = value
        snapshot.noticeKey = notice
        if value != .connected {
            threads.removeAll()
            loaded.removeAll()
            completeLoadedList = false
        }
        updateActivity()
    }

    mutating func errorNotice() { snapshot.noticeKey = "Codex 데이터를 읽을 수 없습니다" }

    mutating func appStartedAt(_ value: Date?) { snapshot.appStartedAt = value }

    mutating func received(monotonic: TimeInterval, now: Date) {
        advance(monotonic: monotonic)
        snapshot.updatedAt = now
    }

    mutating func loadedThreads(_ identifiers: [String], complete: Bool) {
        loaded = Set(identifiers.prefix(128).compactMap(CodexReadProtocol.identifier))
        completeLoadedList = complete && identifiers.count <= 128
        threads = threads.filter { loaded.contains($0.key) }
        for id in loaded where threads[id] == nil { threads[id] = ThreadMetadata() }
        // Evicted threads establish a fresh baseline if seen again, so old
        // account totals are never replayed as new observed token usage.
        if baselines.count > 128 { baselines = baselines.filter { loaded.contains($0.key) } }
        updateActivity()
    }

    mutating func account(_ value: [String: Any], now: Date) {
        snapshot.lifetimeTokens = (value["summary"] as? [String: Any]).flatMap { CodexReadProtocol.integer($0["lifetimeTokens"]) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let buckets = (value["dailyUsageBuckets"] as? [[String: Any]] ?? []).prefix(400)
        let matches = buckets.filter { ($0["startDate"] as? String).map { String($0.prefix(10)) == today } ?? false }
        snapshot.dailyTokens = matches.count == 1 ? CodexReadProtocol.integer(matches[0]["tokens"]) : nil
    }

    mutating func usage(_ value: [String: Any], threadID: String) {
        guard loaded.contains(threadID), let usage = value["threadUsage"] as? [String: Any],
              usage["threadId"] as? String == threadID,
              let groups = usage["groups"] as? [[String: Any]], groups.count <= 64 else { return }
        var current: [String: Counters] = [:]
        var invalid = Set<String>()
        for group in groups {
            guard let model = CodexReadProtocol.identifier(group["model"]) else { continue }
            guard let input = CodexReadProtocol.integer(group["inputTokens"]),
                  let cached = CodexReadProtocol.integer(group["cachedInputTokens"]),
                  let output = CodexReadProtocol.integer(group["outputTokens"]),
                  let total = CodexReadProtocol.integer(group["totalTokens"]), cached <= input,
                  !input.addingReportingOverflow(output).overflow, input + output <= total else {
                invalid.insert(model); continue
            }
            let previous = current[model] ?? Counters(input: 0, cached: 0, output: 0, total: 0)
            current[model] = Counters(input: CodexReadProtocol.add(previous.input, input), cached: CodexReadProtocol.add(previous.cached, cached),
                output: CodexReadProtocol.add(previous.output, output), total: CodexReadProtocol.add(previous.total, total))
        }
        for model in invalid { current.removeValue(forKey: model) }
        for (model, counters) in current {
            if let before = baselines[threadID]?[model] {
                guard let delta = counters.delta(after: before) else { continue }
                guard totals[model] != nil || totals.count < 64 else { continue }
                var aggregate = totals[model] ?? CodexModelUsage(model: model)
                aggregate.inputTokens = CodexReadProtocol.add(aggregate.inputTokens, delta.input)
                aggregate.cachedInputTokens = CodexReadProtocol.add(aggregate.cachedInputTokens, delta.cached)
                aggregate.outputTokens = CodexReadProtocol.add(aggregate.outputTokens, delta.output)
                aggregate.totalTokens = CodexReadProtocol.add(aggregate.totalTokens, delta.total)
                // Account usage groups do not expose reasoning tokens. The UI
                // does not render that unsupported field as a measured zero.
                if delta.total > 0 { totals[model] = aggregate }
            }
            if baselines[threadID] == nil { baselines[threadID] = [:] }
            baselines[threadID]?[model] = counters
        }
        snapshot.models = totals.values.sorted { $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens }
        snapshot.observedTokens = snapshot.models.reduce(0) { CodexReadProtocol.add($0, $1.totalTokens) }
    }

    mutating func turns(_ value: [String: Any], threadID: String, now: Date) -> Bool {
        guard loaded.contains(threadID), let data = value["data"] as? [[String: Any]], data.count <= 1 else { return false }
        guard let turn = data.first else { threads[threadID]?.activity = .idle; updateActivity(); return true }
        guard turn["itemsView"] as? String == "notLoaded", let items = turn["items"] as? [Any], items.isEmpty,
              let status = turn["status"] as? String, ["inProgress", "completed", "interrupted", "failed"].contains(status) else { return false }
        threads[threadID]?.startedAt = nil
        if status == "inProgress", let seconds = CodexReadProtocol.integer(turn["startedAt"]),
           Double(seconds) <= now.timeIntervalSince1970 + 300 {
            threads[threadID]?.startedAt = Date(timeIntervalSince1970: Double(seconds))
        }
        // inProgress includes approval waits. It alone cannot prove active work.
        if status != "inProgress" {
            threads[threadID]?.activity = .idle
            threads[threadID]?.routedModel = nil
        }
        updateActivity()
        return true
    }

    mutating func notification(method: String, parameters: [String: Any]) {
        guard CodexReadProtocol.notifications.contains(method) else { return }
        if method == "account/rateLimits/updated" {
            guard let limits = parameters["rateLimits"] as? [String: Any], let quotaSelection else { return }
            switch quotaSelection {
            case .identified(let id):
                guard CodexReadProtocol.identifier(limits["limitId"]) == id else { return }
                quota(limits, bucket: id, sparse: true)
            case .legacy:
                // An anonymous historical default update cannot be assumed to
                // describe a different explicitly identified model bucket.
                guard limits["limitId"] == nil || limits["limitId"] is NSNull else { return }
                quota(limits, bucket: "legacy", sparse: true)
            }
            return
        }
        guard let id = CodexReadProtocol.identifier(parameters["threadId"]), loaded.contains(id) else { return }
        if method == "thread/status/changed", let status = parameters["status"] as? [String: Any] {
            switch status["type"] as? String {
            case "active":
                guard let flags = status["activeFlags"] as? [String], flags.allSatisfy({ ["waitingOnApproval", "waitingOnUserInput"].contains($0) }) else {
                    threads[id]?.activity = .unknown
                    updateActivity()
                    return
                }
                if threads[id]?.activity == .idle || threads[id]?.activity == .unknown {
                    threads[id]?.startedAt = nil
                    threads[id]?.routedModel = nil
                }
                threads[id]?.activity = flags.isEmpty ? .active : .waiting
            case "idle", "notLoaded", "systemError":
                threads[id]?.activity = .idle
                threads[id]?.startedAt = nil
                threads[id]?.routedModel = nil
            default: threads[id]?.activity = .unknown
            }
        } else if method == "model/rerouted", let model = CodexReadProtocol.identifier(parameters["toModel"]) {
            threads[id]?.routedModel = model
        }
        updateActivity()
    }

    mutating func limits(_ value: [String: Any]) {
        quotaWindows.removeAll()
        quotaSelection = nil
        let legacy = value["rateLimits"] as? [String: Any]
        let legacyID = legacy.flatMap { CodexReadProtocol.identifier($0["limitId"]) }
        if let buckets = value["rateLimitsByLimitId"] as? [String: [String: Any]], !buckets.isEmpty {
            let chosen: (String, [String: Any])?
            if let legacyID, let bucket = buckets[legacyID] { chosen = (legacyID, bucket) }
            else if let bucket = buckets["codex"] { chosen = ("codex", bucket) }
            else if buckets.count == 1, let entry = buckets.first, CodexReadProtocol.identifier(entry.key) != nil { chosen = (entry.key, entry.value) }
            else { chosen = nil }
            if let (id, bucket) = chosen {
                quotaSelection = .identified(id)
                quota(bucket, bucket: id, sparse: false)
                return
            }
        }
        if let legacy {
            let hasWindow = ["primary", "secondary"].contains { kind in
                (legacy[kind] as? [String: Any]).flatMap { CodexReadProtocol.percentage($0["usedPercent"]) } != nil
            }
            if let legacyID {
                quotaSelection = .identified(legacyID)
                quota(legacy, bucket: legacyID, sparse: false)
            } else if hasWindow {
                quotaSelection = .legacy
                quota(legacy, bucket: "legacy", sparse: false)
            }
        }
        snapshot.quotas = quotaWindows.values.sorted { $0.name < $1.name }
    }

    private mutating func quota(_ value: [String: Any], bucket: String?, sparse: Bool) {
        let name = CodexReadProtocol.identifier(bucket) ?? CodexReadProtocol.identifier(value["limitId"]) ?? "codex"
        for kind in ["primary", "secondary"] {
            let key = name + "." + kind
            if let window = value[kind] as? [String: Any], let used = CodexReadProtocol.percentage(window["usedPercent"]) {
                let duration = CodexReadProtocol.integer(window["windowDurationMins"]).flatMap { $0 > 0 && $0 <= 525_600 ? Int($0) : nil }
                let reset = CodexReadProtocol.integer(window["resetsAt"]).flatMap { $0 < 32_503_680_000 ? Date(timeIntervalSince1970: Double($0)) : nil }
                quotaWindows[key] = CodexQuota(name: key, usedPercent: used,
                    windowMinutes: duration ?? (sparse ? quotaWindows[key]?.windowMinutes : nil),
                    resetsAt: reset ?? (sparse ? quotaWindows[key]?.resetsAt : nil))
            } else if !sparse { quotaWindows.removeValue(forKey: key) }
        }
        snapshot.quotas = quotaWindows.values.sorted { $0.name < $1.name }
    }

    private mutating func updateActivity() {
        let values = loaded.compactMap { threads[$0] }
        let known = completeLoadedList && !values.contains(where: { $0.activity == .unknown })
        snapshot.activeCount = known ? values.filter { $0.activity == .active }.count : nil
        snapshot.waitingCount = known ? values.filter { $0.activity == .waiting }.count : nil
        let active = values.filter { $0.activity == .active }
        snapshot.currentStartedAt = active.compactMap(\.startedAt).min()
        snapshot.currentModel = active.count == 1 ? active.first?.routedModel : nil
    }
}

private final class CodexReadConnection {
    enum Kind {
        case initialize, account, limits, loaded, turns(String), usage(String)
    }
    struct Pending { let kind: Kind; let since: TimeInterval }
    let queue: DispatchQueue
    var deliver: (CodexMonitorSnapshot) -> Void
    private var store = CodexObservationStore()
    private var process: Process?
    private var processID: UUID?
    private var input: Pipe?
    private var output: Pipe?
    private var runtimeDirectory: URL?
    private var endpoint: CodexSocketIdentity?
    private var buffer = CodexLineBuffer()
    private var pending: [Int: Pending] = [:]
    private var requestID = 0
    private var ready = false
    private var closing = false
    private var retryAt: TimeInterval = 0
    private var failures = 0
    private var timeouts = 0
    private var nextAccount: TimeInterval = 0
    private var nextLimits: TimeInterval = 0
    private var nextLoaded: TimeInterval = 0
    private var loadedIDs: [String] = []
    private var loadingIDs: [String] = []
    private var loadedPage = 0
    private var cursor: String?
    private var usageTimes: [String: TimeInterval] = [:]
    private var turnTimes: [String: TimeInterval] = [:]
    private var unsupported = Set<String>()
    private var appRunning = false
    private var lastForced: TimeInterval = 0

    init(queue: DispatchQueue, deliver: @escaping (CodexMonitorSnapshot) -> Void) {
        self.queue = queue
        self.deliver = deliver
    }

    func refresh(appRunning: Bool, appStartedAt: Date?, force: Bool) {
        self.appRunning = appRunning
        store.appStartedAt(appRunning ? appStartedAt : nil)
        let now = ProcessInfo.processInfo.systemUptime
        if !appRunning {
            disconnect(state: .notRunning, notice: "Codex가 실행되지 않았습니다", retry: false)
            deliver(store.snapshot)
            return
        }
        if process == nil {
            guard now >= retryAt else { deliver(store.snapshot); return }
            connect()
            return
        }
        guard ready else { expire(now: now); return }
        guard let endpoint, CodexEndpointSecurity.unchanged(endpoint) else {
            disconnect(state: .unavailable, notice: "공유 Codex 서버에 연결할 수 없습니다", retry: true)
            return
        }
        store.advance(monotonic: now)
        expire(now: now)
        if force && now - lastForced >= 10 {
            lastForced = now
            nextAccount = 0; nextLimits = 0; nextLoaded = 0
        }
        poll(now: now)
        deliver(store.snapshot)
    }

    func stop() {
        appRunning = false
        disconnect(state: .notRunning, notice: nil, retry: false)
    }

    private func connect() {
        guard process == nil, let endpoint = CodexEndpointSecurity.current(),
              let executable = CodexEndpointSecurity.installedCLI(), CodexEndpointSecurity.unchanged(endpoint) else {
            unavailable()
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacThermalCodexProxy-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { unavailable(); return }
        let helper = Process()
        let incoming = Pipe(), outgoing = Pipe()
        helper.executableURL = executable
        helper.arguments = ["app-server", "proxy", "--sock", endpoint.url.path]
        // Proxying an existing socket needs no CLI config/authentication files.
        // The clean temporary working/home directory also prevents ambient
        // project configuration or inherited API credentials from being used.
        helper.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_HOME": folder.path, "TMPDIR": folder.path, "LANG": "en_US.UTF-8"]
        helper.currentDirectoryURL = folder
        helper.standardInput = incoming
        helper.standardOutput = outgoing
        helper.standardError = FileHandle.nullDevice
        let id = UUID()
        process = helper
        processID = id
        input = incoming
        output = outgoing
        runtimeDirectory = folder
        self.endpoint = endpoint
        buffer = CodexLineBuffer()
        pending.removeAll()
        unsupported.removeAll()
        ready = false
        closing = false
        requestID = 0
        helper.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in self?.terminated(id: id) }
        }
        outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // A concurrently retired helper may close this handle. Use the
            // bounded throwing API so that race becomes a discarded EOF/error.
            let bytes = (try? handle.read(upToCount: 65_536)) ?? Data()
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.processID == id else { return }
                if bytes.isEmpty {
                    self.disconnect(state: .unavailable, notice: "공유 Codex 서버에 연결할 수 없습니다", retry: true)
                } else { self.receive(bytes) }
            }
        }
        store.connection(.connecting, notice: "Codex에 연결하는 중입니다", monotonic: ProcessInfo.processInfo.systemUptime)
        do {
            guard CodexEndpointSecurity.unchanged(endpoint) else { throw CocoaError(.fileReadUnknown) }
            try helper.run()
            let descriptor = incoming.fileHandleForWriting.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            send(method: "initialize", parameters: [
                "clientInfo": ["name": "mac_thermal_usage_monitor", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"],
                "capabilities": ["experimentalApi": false, "optOutNotificationMethods": CodexReadProtocol.suppressedNotifications]
            ], kind: .initialize)
        } catch {
            cleanup(id: id)
            unavailable()
        }
        deliver(store.snapshot)
    }

    private func unavailable() {
        failures = min(5, failures + 1)
        retryAt = ProcessInfo.processInfo.systemUptime + min(120, 5 * pow(2, Double(failures)))
        store.connection(.unavailable, notice: "공유 Codex 서버에 연결할 수 없습니다", monotonic: ProcessInfo.processInfo.systemUptime)
        deliver(store.snapshot)
    }

    private func send(method: String, parameters: [String: Any], kind: Kind) {
        guard process?.isRunning == true, pending.count < 6, !unsupported.contains(method) else { return }
        requestID += 1
        guard let bytes = CodexReadProtocol.request(id: requestID, method: method, parameters: parameters) else { return }
        pending[requestID] = Pending(kind: kind, since: ProcessInfo.processInfo.systemUptime)
        write(bytes)
    }

    private func write(_ bytes: Data) {
        guard let input else { return }
        let count = bytes.withUnsafeBytes { pointer in
            Darwin.write(input.fileHandleForWriting.fileDescriptor, pointer.baseAddress, pointer.count)
        }
        if count != bytes.count { disconnect(state: .unavailable, notice: "공유 Codex 서버에 연결할 수 없습니다", retry: true) }
    }

    private func method(for kind: Kind) -> String {
        switch kind {
        case .initialize: return "initialize"
        case .account, .usage: return "account/usage/read"
        case .limits: return "account/rateLimits/read"
        case .loaded: return "thread/loaded/list"
        case .turns: return "thread/turns/list"
        }
    }

    private func containsPending(_ method: String) -> Bool { pending.values.contains { self.method(for: $0.kind) == method } }

    private func poll(now: TimeInterval) {
        guard ready, process?.isRunning == true else { return }
        if now >= nextAccount, !containsPending("account/usage/read") {
            nextAccount = now + 60
            send(method: "account/usage/read", parameters: [:], kind: .account)
        }
        if now >= nextLimits, !containsPending("account/rateLimits/read") {
            nextLimits = now + 60
            send(method: "account/rateLimits/read", parameters: ["excludeResetCreditDetails": true, "supportsLunaReserve": false], kind: .limits)
        }
        if now >= nextLoaded, !containsPending("thread/loaded/list") {
            nextLoaded = now + 15
            loadingIDs = []
            loadedPage = 0
            cursor = nil
            send(method: "thread/loaded/list", parameters: ["limit": 32], kind: .loaded)
        }
        if !containsPending("thread/turns/list"), let id = loadedIDs.min(by: { (turnTimes[$0] ?? 0) < (turnTimes[$1] ?? 0) }), now - (turnTimes[id] ?? 0) >= 30 {
            turnTimes[id] = now
            send(method: "thread/turns/list", parameters: ["threadId": id, "itemsView": "notLoaded", "limit": 1, "sortDirection": "desc"], kind: .turns(id))
        }
        if now < nextAccount, !containsPending("account/usage/read"), let id = loadedIDs.min(by: { (usageTimes[$0] ?? 0) < (usageTimes[$1] ?? 0) }), now - (usageTimes[id] ?? 0) >= 30 {
            usageTimes[id] = now
            send(method: "account/usage/read", parameters: ["threadId": id], kind: .usage(id))
        }
    }

    private func expire(now: TimeInterval) {
        let expired = pending.filter { now - $0.value.since >= 15 }
        for (id, request) in expired {
            pending.removeValue(forKey: id)
            timeouts += 1
            store.errorNotice()
            if case .initialize = request.kind {
                disconnect(state: .unavailable, notice: "공유 Codex 서버에 연결할 수 없습니다", retry: true)
                return
            }
        }
        if timeouts >= 3 { disconnect(state: .unavailable, notice: "Codex 데이터를 읽을 수 없습니다", retry: true) }
    }

    private func receive(_ bytes: Data) {
        guard let lines = buffer.append(bytes) else {
            disconnect(state: .unavailable, notice: "Codex 데이터를 읽을 수 없습니다", retry: true)
            return
        }
        for line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                disconnect(state: .unavailable, notice: "Codex 데이터를 읽을 수 없습니다", retry: true)
                return
            }
            if let method = object["method"] as? String {
                // Never respond to approval/tool/login requests from the server.
                guard object["id"] == nil, CodexReadProtocol.notifications.contains(method),
                      let parameters = object["params"] as? [String: Any], ready else { continue }
                store.received(monotonic: ProcessInfo.processInfo.systemUptime, now: Date())
                store.notification(method: method, parameters: parameters)
                deliver(store.snapshot)
                continue
            }
            guard let id = CodexReadProtocol.integer(object["id"]), id <= Int64(Int.max),
                  let request = pending.removeValue(forKey: Int(id)) else { continue }
            if let error = object["error"] as? [String: Any] {
                if (error["code"] as? NSNumber)?.intValue == -32601 { unsupported.insert(method(for: request.kind)) }
                store.errorNotice()
                if case .initialize = request.kind {
                    disconnect(state: .unavailable, notice: "공유 Codex 서버에 연결할 수 없습니다", retry: true)
                    return
                }
                deliver(store.snapshot)
                continue
            }
            guard let result = object["result"] as? [String: Any] else { store.errorNotice(); continue }
            timeouts = 0
            let now = Date()
            store.received(monotonic: ProcessInfo.processInfo.systemUptime, now: now)
            switch request.kind {
            case .initialize:
                ready = true
                failures = 0
                nextAccount = 0; nextLimits = 0; nextLoaded = 0
                usageTimes = [:]; turnTimes = [:]
                write(Data("{\"method\":\"initialized\"}\n".utf8))
                store.connection(.connected, notice: "연결 이후 관측한 활동만 집계합니다", monotonic: ProcessInfo.processInfo.systemUptime)
                poll(now: ProcessInfo.processInfo.systemUptime)
            case .account: store.account(result, now: now)
            case .limits: store.limits(result)
            case .usage(let thread): store.usage(result, threadID: thread)
            case .turns(let thread):
                guard store.turns(result, threadID: thread, now: now) else {
                    disconnect(state: .unavailable, notice: "Codex 데이터를 읽을 수 없습니다", retry: true)
                    return
                }
            case .loaded:
                guard let data = result["data"] as? [String], data.count <= 32,
                      data.allSatisfy({ CodexReadProtocol.identifier($0) != nil }) else {
                    disconnect(state: .unavailable, notice: "Codex 데이터를 읽을 수 없습니다", retry: true)
                    return
                }
                loadingIDs.append(contentsOf: data)
                loadedPage += 1
                cursor = (result["nextCursor"] as? String).flatMap { $0.utf8.count <= 1_024 ? $0 : nil }
                if let cursor, loadedPage < 4, loadingIDs.count < 128 {
                    send(method: "thread/loaded/list", parameters: ["limit": 32, "cursor": cursor], kind: .loaded)
                } else {
                    loadedIDs = Array(Set(loadingIDs)).sorted()
                    store.loadedThreads(loadedIDs, complete: cursor == nil)
                    usageTimes = usageTimes.filter { loadedIDs.contains($0.key) }
                    turnTimes = turnTimes.filter { loadedIDs.contains($0.key) }
                }
            }
            deliver(store.snapshot)
        }
    }

    private func disconnect(state: CodexConnectionState, notice: String?, retry: Bool) {
        closing = true
        ready = false
        pending.removeAll()
        loadedIDs = []
        buffer = CodexLineBuffer()
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        store.connection(state, notice: notice, monotonic: ProcessInfo.processInfo.systemUptime)
        if retry {
            failures = min(5, failures + 1)
            retryAt = ProcessInfo.processInfo.systemUptime + min(120, 5 * pow(2, Double(failures)))
        } else { retryAt = 0 }
        if let helper = process, helper.isRunning {
            let id = processID
            helper.terminate()
            queue.asyncAfter(deadline: .now() + 1) { [weak self, helper] in
                guard helper.isRunning else { return }
                if let self, self.processID != id { return }
                kill(helper.processIdentifier, SIGKILL)
            }
        } else if let id = processID { cleanup(id: id) }
        deliver(store.snapshot)
    }

    private func terminated(id: UUID) {
        guard id == processID else { return }
        let unexpectedExit = appRunning && !closing
        cleanup(id: id)
        if unexpectedExit { unavailable() }
    }

    private func cleanup(id: UUID) {
        guard processID == id else { return }
        ready = false
        process?.terminationHandler = nil
        process = nil
        processID = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close()
        try? input?.fileHandleForWriting.close()
        output = nil
        input = nil
        endpoint = nil
        pending.removeAll()
        if let folder = runtimeDirectory { try? FileManager.default.removeItem(at: folder) }
        runtimeDirectory = nil
    }
}

/// A read-only observer of an already-running, same-user shared Codex daemon.
/// It never starts a daemon, opens authentication/history files, resumes work,
/// or requests a model call. An app using a private transport stays unavailable.
final class CodexMonitor {
    var onUpdate: ((CodexMonitorSnapshot) -> Void)?
    private let queue = DispatchQueue(label: "local.mac-thermal.codex-read-only", qos: .utility)
    private var connection: CodexReadConnection?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var generation: UInt = 0
    private var started = false
    private let runningProvider: () -> Bool
    private let launchDateProvider: () -> Date?
    private let workspaceNotificationsEnabled: Bool

    init(isRunning: @escaping () -> Bool = CodexMonitor.isCodexRunning,
         launchDate: @escaping () -> Date? = CodexMonitor.codexLaunchDate,
         workspaceNotificationsEnabled: Bool = true) {
        runningProvider = isRunning
        launchDateProvider = launchDate
        self.workspaceNotificationsEnabled = workspaceNotificationsEnabled
    }

    static func isCodexRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.openai.codex" && !$0.isTerminated }
    }

    static func codexLaunchDate() -> Date? {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.openai.codex" && !$0.isTerminated
        }.compactMap(\.launchDate).min()
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !started else { return }
        started = true
        generation &+= 1
        let currentGeneration = generation
        let delivery: (CodexMonitorSnapshot) -> Void = { [weak self] snapshot in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.started, self.generation == currentGeneration else { return }
                self.onUpdate?(snapshot)
            }
        }
        let connection = self.connection ?? CodexReadConnection(queue: queue, deliver: delivery)
        queue.async { connection.deliver = delivery }
        self.connection = connection
        if workspaceNotificationsEnabled {
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          application.bundleIdentifier == "com.openai.codex" else { return }
                    self?.refresh()
                })
            }
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.update(force: false) }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        update(force: false)
    }

    func refresh() {
        precondition(Thread.isMainThread)
        update(force: true)
    }

    private func update(force: Bool) {
        guard started, let connection else { return }
        let running = runningProvider()
        let startedAt = running ? launchDateProvider() : nil
        queue.async { connection.refresh(appRunning: running, appStartedAt: startedAt, force: force) }
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard started else { return }
        started = false
        generation &+= 1
        timer?.invalidate()
        timer = nil
        if !observers.isEmpty {
            let workspace = NSWorkspace.shared.notificationCenter
            for observer in observers { workspace.removeObserver(observer) }
        }
        observers = []
        if let connection { queue.async { connection.stop() } }
        // Keep the retiring helper's lifecycle owner. A quick start/stop/start
        // waits for that same helper to exit rather than spawning a second one.
    }
}
