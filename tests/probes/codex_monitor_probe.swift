import AppKit
import Foundation
import Darwin

@main
struct CodexMonitorProbe {
    static var checks = 0
    static let session = "11111111-1111-4111-8111-111111111111"
    static let turnA = "22222222-2222-4222-8222-222222222222"
    static let turnB = "33333333-3333-4333-8333-333333333333"
    static let now = date("2026-10-19T12:00:00Z")
    static let day = date("2026-10-19T00:00:00Z")
    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static func require(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !value() { fputs("FAIL: \(label)\n", stderr); exit(1) }
    }
    static func line(_ type: String, _ timestamp: String, _ payload: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: ["type": type, "timestamp": timestamp, "payload": payload], options: [.sortedKeys])
        data.append(10); return data
    }
    static func meta(_ timestamp: String = "2026-10-19T01:00:00Z", id: String = session, fork: Bool = false) -> Data {
        var payload: [String: Any] = ["id": id, "body": "PRIVATE_BODY_SHOULD_NEVER_LEAVE_PARSER"]
        if fork { payload["forked_from_id"] = session }
        return line("session_meta", timestamp, payload)
    }
    static func context(_ timestamp: String = "2026-10-19T01:00:00Z", model: String = "gpt-6.1-sol", turn: String = turnA) -> Data {
        line("turn_context", timestamp, ["model": model, "turn_id": turn, "instructions": "PRIVATE_INSTRUCTIONS"])
    }
    static func numbers(_ total: Int, cached: Int = 0, output: Int = 0, reasoning: Int = 0) -> [String: Any] {
        ["input_tokens": total - output, "cached_input_tokens": cached, "output_tokens": output,
         "reasoning_output_tokens": reasoning, "total_tokens": total]
    }
    static func token(_ timestamp: String, total: Int, last: Int? = nil, cached: Int = 0, output: Int = 0, reasoning: Int = 0) -> Data {
        line("event_msg", timestamp, ["type": "token_count", "info": [
            "total_token_usage": numbers(total, cached: cached, output: output, reasoning: reasoning),
            "last_token_usage": numbers(last ?? total)
        ]])
    }
    static func feed(_ state: CodexLocalRecordState, _ bytes: Data, limit: Int = 100) {
        for record in bytes.split(separator: 10) {
            state.consume(Data(record), now: now, dayStart: day, dayEnd: day.addingTimeInterval(86_400), maxRecords: limit)
        }
    }
    static func main() throws {
        require(CodexTokenNumbers.integer(true) == nil, "boolean counter rejected")
        require(CodexTokenNumbers.integer(1.5) == nil, "fractional counter rejected")
        require(CodexTokenNumbers.integer(-1) == nil, "negative counter rejected")
        require(CodexTokenNumbers.parse(numbers(100, cached: 101)) == nil, "invalid cached subset rejected")
        require(CodexTokenNumbers.parse(numbers(100, output: 10, reasoning: 11)) == nil, "invalid reasoning subset rejected")
        require(CodexLocalRecordState.model("gpt-6.1-sol") != nil, "model identifier accepted")
        require(CodexLocalRecordState.model("/private/task") == nil, "path model rejected")
        require(CodexLocalRecordState.model("private message text") == nil, "text model rejected")

        let fixture = try Fixture()
        defer { fixture.remove() }
        let base = meta() + context() + token("2026-10-19T01:00:01Z", total: 100)
        let path = try fixture.write("2026/10/19/one.jsonl", base)
        let reader = CodexLocalRecordsReader(root: fixture.root)
        var first = reader.scan(now: now, cancellation: CodexRecordsCancellation())!
        require(first.dailyTokens == 100 && first.recordsCount == 1, "first complete local usage")
        require(first.models.first?.model == "gpt-6.1-sol" && first.currentModel == "gpt-6.1-sol", "verified model context")
        require(first.lastRecordAt == date("2026-10-19T01:00:01Z"), "numeric record timestamp")
        require(!first.incomplete && first.recordsEnabled && first.connection == .connected, "complete source status")
        let again = reader.scan(now: now.addingTimeInterval(1), cancellation: CodexRecordsCancellation())!
        require(again.dailyTokens == 100 && again.recordsCount == 1 && reader.bytesReadLastScan == 0, "unchanged file does not replay or reread")
        try fixture.append(path, token("2026-10-19T01:00:02Z", total: 100))
        let duplicate = reader.scan(now: now.addingTimeInterval(2), cancellation: CodexRecordsCancellation())!
        require(duplicate.dailyTokens == 100 && duplicate.recordsCount == 1, "duplicate cumulative notification adds zero")
        try fixture.append(path, context("2026-10-19T01:00:03Z", model: "gpt-6-astra", turn: turnB) + token("2026-10-19T01:00:04Z", total: 160, last: 60))
        let switched = reader.scan(now: now.addingTimeInterval(3), cancellation: CodexRecordsCancellation())!
        require(switched.dailyTokens == 160 && switched.models.count == 2, "model switch shares one session baseline")
        require(switched.models.first(where: { $0.model == "gpt-6-astra" })?.totalTokens == 60, "new model receives delta only")
        try fixture.append(path, token("2026-10-19T01:00:01Z", total: 110, last: 10) + token("2026-10-19T01:00:05Z", total: 50) + token("2026-10-19T01:00:06Z", total: 180, last: 20))
        let rollback = reader.scan(now: now.addingTimeInterval(4), cancellation: CodexRecordsCancellation())!
        require(rollback.dailyTokens == 180 && rollback.incomplete, "old events and rollback never replay historical totals")

        let previous = try Fixture(); defer { previous.remove() }
        let previousData = meta("2026-10-18T23:00:00Z") + context("2026-10-18T23:00:00Z") + token("2026-10-18T23:59:00Z", total: 1_000) + token("2026-10-19T00:00:01Z", total: 1_025, last: 25)
        try previous.write("2026/10/18/long-lived.jsonl", previousData)
        let previousReader = CodexLocalRecordsReader(root: previous.root)
        let today = previousReader.scan(now: now, cancellation: CodexRecordsCancellation())!
        require(today.dailyTokens == 25 && today.recordsCount == 1, "old folder session contributes current UTC day deltas")
        let tomorrow = previousReader.scan(now: now.addingTimeInterval(86_400), cancellation: CodexRecordsCancellation())!
        require(tomorrow.dailyTokens == 0 && tomorrow.models.isEmpty, "UTC rollover clears previous day counts")

        let copied = try Fixture(); defer { copied.remove() }
        try copied.write("2026/10/19/a.jsonl", base)
        try copied.write("2026/10/19/b.jsonl", base)
        let copiedSnapshot = CodexLocalRecordsReader(root: copied.root).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(copiedSnapshot.dailyTokens == 100 && copiedSnapshot.recordsCount == 1, "copied same-turn history deduplicated across files")
        try copied.write("2026/10/19/c.jsonl", meta(id: "44444444-4444-4444-8444-444444444444") + context(turn: "55555555-5555-4555-8555-555555555555") + token("2026-10-19T01:00:01Z", total: 100))
        let independent = CodexLocalRecordsReader(root: copied.root).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(independent.dailyTokens == 200 && independent.recordsCount == 2, "independent same numeric events are not incorrectly deduplicated")

        let conflict = try Fixture(); defer { conflict.remove() }
        try conflict.write("2026/10/19/a.jsonl", base + token("2026-10-19T01:00:02Z", total: 200, last: 100))
        let conflictingCopy = meta() + context() + token("2026-10-19T01:00:02Z", total: 200)
        try conflict.write("2026/10/19/b.jsonl", conflictingCopy)
        try conflict.write("2026/10/19/c.jsonl", conflictingCopy)
        let conflicted = CodexLocalRecordsReader(root: conflict.root).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(conflicted.dailyTokens == 100 && conflicted.incomplete, "conflicting copied baseline excluded even with third copy")

        let nullableFork = try Fixture(); defer { nullableFork.remove() }
        let nullMeta = line("session_meta", "2026-10-19T01:00:00Z", ["id": session, "forked_from_id": NSNull()])
        try nullableFork.write("2026/10/19/null.jsonl", nullMeta + context() + token("2026-10-19T01:00:01Z", total: 100))
        let nullForkSnapshot = CodexLocalRecordsReader(root: nullableFork.root).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(nullForkSnapshot.dailyTokens == 100 && !nullForkSnapshot.incomplete, "null fork metadata equals absent optional")
        let malformedFork = try Fixture(); defer { malformedFork.remove() }
        try malformedFork.write("2026/10/19/bad.jsonl", line("session_meta", "2026-10-19T01:00:00Z", ["id": session, "forked_from_id": true]) + context() + token("2026-10-19T01:00:01Z", total: 100))
        let malformedForkSnapshot = CodexLocalRecordsReader(root: malformedFork.root).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(malformedForkSnapshot.dailyTokens == nil && malformedForkSnapshot.incomplete, "malformed nonnull fork metadata fails conservatively")

        let fork = try Fixture(); defer { fork.remove() }
        let forked = base + meta("2026-10-19T02:00:00Z", id: "66666666-6666-4666-8666-666666666666", fork: true)
            + context("2026-10-19T02:00:00Z", model: "gpt-6-astra", turn: turnB)
            + token("2026-10-19T02:00:01Z", total: 130, last: 30)
            + token("2026-10-19T02:00:02Z", total: 150, last: 20)
        try fork.write("2026/10/19/fork.jsonl", forked)
        let forkedSnapshot = CodexLocalRecordsReader(root: fork.root).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(forkedSnapshot.dailyTokens == 20 && forkedSnapshot.incomplete, "fork copied prefix excluded and first inherited baseline conservatively excluded")

        let unknown = try Fixture(); defer { unknown.remove() }
        try unknown.write("2026/10/19/unknown.jsonl", meta() + token("2026-10-19T01:00:01Z", total: 100))
        let unknownSnapshot = CodexLocalRecordsReader(root: unknown.root).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(unknownSnapshot.dailyTokens == nil && unknownSnapshot.models.isEmpty && unknownSnapshot.incomplete, "missing model is unavailable rather than false zero")

        let invalid = try Fixture(); defer { invalid.remove() }
        let malformedContext = line("turn_context", "2026-10-19T01:00:02Z", ["model": "/private/not-model", "turn_id": turnB])
        try invalid.write("2026/10/19/invalid.jsonl", base + malformedContext + token("2026-10-19T01:00:03Z", total: 160, last: 60))
        let invalidSnapshot = CodexLocalRecordsReader(root: invalid.root).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(invalidSnapshot.dailyTokens == 100 && invalidSnapshot.models.count == 1 && invalidSnapshot.incomplete, "invalid new context cannot inherit old model attribution")
        let invalidSession = try Fixture(); defer { invalidSession.remove() }
        try invalidSession.write("2026/10/19/invalid.jsonl", base + line("session_meta", "2026-10-19T01:00:02Z", ["id": "invalid"])
            + context("2026-10-19T01:00:03Z", turn: turnB) + token("2026-10-19T01:00:04Z", total: 160, last: 60))
        require(CodexLocalRecordsReader(root: invalidSession.root).scan(now: now, cancellation: CodexRecordsCancellation())!.dailyTokens == 100, "invalid new session cannot inherit old baseline")

        let midnight = try Fixture(); defer { midnight.remove() }
        let midnightPath = try midnight.write("2026/10/18/live.jsonl", meta("2026-10-18T23:58:00Z") + context("2026-10-18T23:58:00Z") + token("2026-10-18T23:59:00Z", total: 100))
        let midnightReader = CodexLocalRecordsReader(root: midnight.root)
        require(midnightReader.scan(now: date("2026-10-18T23:59:01Z"), cancellation: CodexRecordsCancellation())!.dailyTokens == 100, "midnight baseline setup")
        let nextDay = token("2026-10-19T00:00:01Z", total: 125, last: 25)
        try midnight.append(midnightPath, nextDay)
        let crossedMidnight = midnightReader.scan(now: date("2026-10-19T00:00:02Z"), cancellation: CodexRecordsCancellation())!
        require(crossedMidnight.dailyTokens == 25 && midnightReader.bytesReadLastScan == nextDay.count, "UTC rollover retains cursor and baseline without replay")

        let tails = try Fixture(); defer { tails.remove() }
        let tailPath = try tails.write("2026/10/19/tail.jsonl", meta() + context() + token("2026-10-19T01:00:01Z", total: 100).dropLast())
        let tailReader = CodexLocalRecordsReader(root: tails.root)
        require(tailReader.scan(now: now, cancellation: CodexRecordsCancellation())!.dailyTokens == nil && !tailReader.needsCatchUp, "partial raw line waits for append without hot catch-up")
        try tails.append(tailPath, Data([10]))
        require(tailReader.scan(now: now.addingTimeInterval(1), cancellation: CodexRecordsCancellation())!.dailyTokens == 100, "completed tail reread without retaining raw body")
        let oversizedPath = try tails.write("2026/10/19/oversize.jsonl", Data(repeating: 65, count: 200_000) + Data([10]) + base)
        _ = oversizedPath
        let oversized = CodexLocalRecordsReader(root: tails.root).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(oversized.incomplete && oversized.dailyTokens == 100, "oversized line discarded and later complete records parsed")

        let truncated = try Fixture(); defer { truncated.remove() }
        let truncPath = try truncated.write("2026/10/19/truncate.jsonl", base + token("2026-10-19T01:00:02Z", total: 160, last: 60))
        let truncReader = CodexLocalRecordsReader(root: truncated.root)
        require(truncReader.scan(now: now, cancellation: CodexRecordsCancellation())!.dailyTokens == 160, "truncation setup")
        try base.write(to: truncPath)
        let rebuilt = truncReader.scan(now: now.addingTimeInterval(1), cancellation: CodexRecordsCancellation())!
        require(rebuilt.dailyTokens == 100 && rebuilt.incomplete, "truncation rebuild replaces old contributions without replay")

        let bounded = try Fixture(); defer { bounded.remove() }
        try bounded.write("2026/10/19/a.jsonl", base)
        try bounded.write("2026/10/19/b.jsonl", base)
        var tiny = CodexRecordsBudget(); tiny.maxFiles = 1
        require(CodexLocalRecordsReader(root: bounded.root, budget: tiny).scan(now: now, cancellation: CodexRecordsCancellation())!.incomplete, "catalog cap disclosed")
        tiny = CodexRecordsBudget(); tiny.bytesPerScan = 10; tiny.bytesPerFile = 10
        let capped = CodexLocalRecordsReader(root: bounded.root, budget: tiny).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(capped.incomplete && capped.dailyTokens == nil, "read budget never claims initial exact zero")
        tiny = CodexRecordsBudget(); tiny.maxRecordsTotal = 1
        let limited = CodexLocalRecordsReader(root: fixture.root, budget: tiny).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(limited.incomplete && limited.recordsCount == 1, "numeric cache cap disclosed")

        let global = try Fixture(); defer { global.remove() }
        for index in 0..<4 {
            let id = String(format: "%08d-7777-4777-8777-777777777777", index)
            try global.write("2026/10/19/\(index).jsonl", meta(id: id) + context(turn: id) + token("2026-10-19T01:00:01Z", total: 100))
        }
        var globalBudget = CodexRecordsBudget(); globalBudget.maxRecordsTotal = 2
        let globalReader = CodexLocalRecordsReader(root: global.root, budget: globalBudget)
        let globalSnapshot = globalReader.scan(now: now, cancellation: CodexRecordsCancellation())!
        require(globalReader.retainedRecordCount <= 2 && globalSnapshot.incomplete, "global retained cache is bounded across multiple files")
        let recent = try Fixture(); defer { recent.remove() }
        try recent.write("2020/01/01/old.jsonl", base)
        try recent.write("2026/10/19/new.jsonl", meta() + context(model: "gpt-6-astra") + token("2026-10-19T01:00:01Z", total: 10))
        var recentBudget = CodexRecordsBudget(); recentBudget.maxFiles = 1
        let recentSnapshot = CodexLocalRecordsReader(root: recent.root, budget: recentBudget).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(recentSnapshot.dailyTokens == 10 && recentSnapshot.currentModel == "gpt-6-astra" && recentSnapshot.incomplete, "metadata cutoff prioritizes recent date folders")
        let catchup = try Fixture(); defer { catchup.remove() }
        var backlog = meta() + context()
        let ignored = line("response_item", "2026-10-19T01:00:00Z", ["body": String(repeating: "x", count: 4_096)])
        for _ in 0..<100 { backlog.append(ignored) }
        backlog.append(token("2026-10-19T01:00:01Z", total: 100))
        try catchup.write("2026/10/19/catchup.jsonl", backlog)
        var catchupBudget = CodexRecordsBudget(); catchupBudget.bytesPerScan = 32_768; catchupBudget.bytesPerFile = 32_768
        let catchupReader = CodexLocalRecordsReader(root: catchup.root, budget: catchupBudget)
        var catchupSnapshot = catchupReader.scan(now: now, cancellation: CodexRecordsCancellation())!
        require(catchupReader.needsCatchUp && catchupSnapshot.dailyTokens == nil, "unread backlog requests bounded catch-up")
        for _ in 0..<30 where catchupReader.needsCatchUp {
            catchupSnapshot = catchupReader.scan(now: now.addingTimeInterval(1), cancellation: CodexRecordsCancellation())!
            require(catchupReader.bytesReadLastScan <= 32_768, "catch-up respects each byte budget")
        }
        require(!catchupReader.needsCatchUp && catchupSnapshot.dailyTokens == 100, "catch-up finishes then becomes idle")

        let external = try Fixture(); defer { external.remove() }
        let externalPath = try external.write("outside.jsonl", base)
        let links = try Fixture(); defer { links.remove() }
        try FileManager.default.createSymbolicLink(at: links.root.appendingPathComponent("linked.jsonl"), withDestinationURL: externalPath)
        try FileManager.default.createSymbolicLink(at: links.root.appendingPathComponent("linked-dir"), withDestinationURL: external.root)
        let linksSnapshot = CodexLocalRecordsReader(root: links.root).scan(now: now, cancellation: CodexRecordsCancellation())!
        require(linksSnapshot.dailyTokens == nil && linksSnapshot.incomplete, "file and directory symlinks never traversed")
        let symlinkRoot = external.base.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: fixture.root)
        require(CodexLocalRecordsReader(root: symlinkRoot).scan(now: now, cancellation: CodexRecordsCancellation())!.connection == .unavailable, "symlink root refused")
        let moved = try Fixture(); defer { moved.remove() }
        try moved.write("2026/10/19/a.jsonl", base)
        let movedReader = CodexLocalRecordsReader(root: moved.root)
        require(movedReader.scan(now: now, cancellation: CodexRecordsCancellation())!.dailyTokens == 100, "root identity setup")
        let oldRoot = moved.root.deletingLastPathComponent().appendingPathComponent("old-sessions")
        try FileManager.default.moveItem(at: moved.root, to: oldRoot)
        try FileManager.default.createDirectory(at: moved.root, withIntermediateDirectories: false)
        let replaced = movedReader.scan(now: now.addingTimeInterval(1), cancellation: CodexRecordsCancellation())!
        require(replaced.connection == .unavailable && replaced.dailyTokens == nil, "replaced root clears stale numeric data")
        let cancelled = CodexRecordsCancellation(); cancelled.cancel()
        require(reader.scan(now: now, cancellation: cancelled) == nil, "cancelled scan performs no work or delivery")

        let suite = "MacThermal.CodexMonitorProbe." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let launch = now.addingTimeInterval(-3600)
        let monitor = CodexMonitor(defaults: defaults, recordsRoot: fixture.root,
            isRunning: { true }, launchDate: { launch }, workspaceNotificationsEnabled: false)
        var snapshots: [CodexMonitorSnapshot] = []
        monitor.onUpdate = { snapshots.append($0) }
        monitor.start()
        require(snapshots.last?.recordsEnabled == false && snapshots.last?.appStartedAt == launch, "opt-in defaults off while runtime remains local")
        monitor.setRecordsEnabled(true)
        monitor.setRecordsEnabled(false)
        let until = Date().addingTimeInterval(0.3)
        while RunLoop.current.run(mode: .default, before: until), Date() < until {}
        require(snapshots.last?.recordsEnabled == false && snapshots.last?.dailyTokens == nil && snapshots.last?.models.isEmpty == true, "off clears counts and rejects in-flight enabled callbacks")
        require(!defaults.bool(forKey: CodexMonitor.recordsEnabledKey), "explicit toggle persistence")
        monitor.stop(); let count = snapshots.count; monitor.refresh()
        require(snapshots.count == count, "stop has no late refresh delivery")
        first = CodexMonitorSnapshot()
        print("Codex local-record monitor probe PASS (\(checks) checks; synthetic fixtures only)")
    }
}

private final class Fixture {
    let base: URL
    let root: URL
    init() throws {
        base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mac-thermal-codex-fixture-" + UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    @discardableResult func write(_ relative: String, _ data: Data) throws -> URL {
        let path = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
        return path
    }
    func append(_ path: URL, _ data: Data) throws {
        let fd = Darwin.open(path.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: "Fixture", code: 1) }
        defer { Darwin.close(fd) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        if count != data.count { throw NSError(domain: "Fixture", code: 2) }
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
