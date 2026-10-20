import AppKit
import Foundation
import Darwin

/// Cancellation is shared with the main thread: OFF does not wait behind a scan.
final class CodexRecordsCancellation {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

struct CodexTokenNumbers: Equatable, Hashable {
    var input: Int64
    var cached: Int64
    var output: Int64
    var reasoning: Int64
    var total: Int64
    static let zero = Self(input: 0, cached: 0, output: 0, reasoning: 0, total: 0)

    static func parse(_ value: Any?) -> Self? {
        guard let object = value as? [String: Any],
              let input = integer(object["input_tokens"]),
              let cached = integer(object["cached_input_tokens"]),
              let output = integer(object["output_tokens"]),
              let reasoning = integer(object["reasoning_output_tokens"]),
              let total = integer(object["total_tokens"]),
              cached <= input, reasoning <= output,
              input <= Int64.max - output, input + output == total else { return nil }
        return Self(input: input, cached: cached, output: output, reasoning: reasoning, total: total)
    }
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let text = number.stringValue
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let result = Int64(text), result >= 0 else { return nil }
        return result
    }
    func delta(after old: Self) -> Self? {
        guard input >= old.input, cached >= old.cached, output >= old.output,
              reasoning >= old.reasoning, total >= old.total else { return nil }
        return Self(input: input - old.input, cached: cached - old.cached,
                    output: output - old.output, reasoning: reasoning - old.reasoning,
                    total: total - old.total)
    }
    func usage(model: String) -> CodexModelUsage {
        CodexModelUsage(model: model, inputTokens: input, cachedInputTokens: cached,
                        outputTokens: output, reasoningOutputTokens: reasoning, totalTokens: total)
    }
}

private struct CodexNodeIdentity: Equatable, Hashable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let kind: mode_t
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; owner = info.st_uid
        kind = info.st_mode & S_IFMT
        birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
    }
}

private struct CodexRecordsScope {
    let components: [String]
    let identities: [CodexNodeIdentity]
    let device: dev_t

    static func open(_ root: URL, expected: Self? = nil) -> (Self, Int32)? {
        let path = root.path
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        var identities: [CodexNodeIdentity] = []
        var succeeded = false
        defer { if !succeeded { Darwin.close(descriptor) } }
        for (index, component) in components.enumerated() {
            guard component != ".", component != ".." else { return nil }
            let next = component.withCString { openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard next >= 0 else { return nil }
            Darwin.close(descriptor); descriptor = next
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == 0 || info.st_uid == geteuid() else { return nil }
            // Root-owned sticky temporary ancestors are allowed for isolated probes.
            let stickyTemporary = info.st_uid == 0 && (info.st_mode & S_ISVTX) != 0
            guard (info.st_mode & 0o022) == 0 || stickyTemporary else { return nil }
            if index >= max(0, components.count - 2), info.st_uid != geteuid() { return nil }
            identities.append(CodexNodeIdentity(info))
        }
        let scope = Self(components: components, identities: identities, device: identities.last!.device)
        if let expected, expected.components != components || expected.identities != identities { return nil }
        succeeded = true
        return (scope, descriptor)
    }
}

private struct CodexRecordKey: Hashable {
    let turnID: String
    let timestamp: Date
    let cumulative: CodexTokenNumbers
}
private struct CodexUsageRecord {
    let key: CodexRecordKey
    let model: String
    let numbers: CodexTokenNumbers
}
private struct CodexContext {
    let model: String
    let turnID: String
    let timestamp: Date
}

/// A bounded JSONL parser retains only identifiers, counters and dates. Raw lines
/// and dictionaries are transient; incomplete raw lines are reread, never cached.
final class CodexLocalRecordState {
    fileprivate var offset: Int64 = 0
    fileprivate var discardedLine = false
    fileprivate var partialLine = false
    fileprivate var waitingForAppend = false
    fileprivate var incomplete = false
    fileprivate var sessionID: String?
    fileprivate var sessionStartedAt: Date?
    fileprivate var forkBoundary: Date?
    fileprivate var context: CodexContext?
    fileprivate var baseline: CodexTokenNumbers?
    fileprivate var baselineAt: Date?
    fileprivate var records: [CodexRecordKey: CodexUsageRecord] = [:]
    fileprivate var latestModel: String?
    fileprivate var latestModelAt: Date?
    fileprivate var knownSize: Int64 = 0
    fileprivate var catalogSizeAtRead: Int64?
    fileprivate var modifiedSeconds: Int64 = 0
    fileprivate var modifiedNanos: Int64 = 0

    func consume(_ line: Data, now: Date, dayStart: Date, dayEnd: Date, maxRecords: Int) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { context = nil; incomplete = true; return }
        guard type == "session_meta" || type == "turn_context" || type == "event_msg" else { return }
        guard let payload = object["payload"] as? [String: Any] else {
            if type == "turn_context" { context = nil }
            if type == "session_meta" { sessionID = nil; context = nil; baseline = nil; baselineAt = nil }
            incomplete = true; return
        }
        if type == "event_msg", payload["type"] as? String != "token_count" { return }
        guard let timestamp = Self.date(object["timestamp"]), timestamp <= now.addingTimeInterval(300) else {
            if type == "turn_context" { context = nil }
            if type == "session_meta" { sessionID = nil; context = nil; baseline = nil; baselineAt = nil }
            incomplete = true; return
        }
        if type == "session_meta" {
            guard let id = Self.identifier(payload["id"]) else {
                sessionID = nil; context = nil; baseline = nil; baselineAt = nil; incomplete = true; return
            }
            if let old = sessionID, old != id { baseline = nil; baselineAt = nil; context = nil; forkBoundary = nil }
            sessionID = id; sessionStartedAt = timestamp
            if let fork = payload["forked_from_id"], !(fork is NSNull) {
                guard Self.identifier(fork) != nil else {
                    sessionID = nil; context = nil; baseline = nil; baselineAt = nil; incomplete = true; return
                }
                forkBoundary = timestamp
                records = records.filter { $0.value.key.timestamp >= timestamp }
                incomplete = true
            }
            return
        }
        if type == "turn_context" {
            if let old = context, timestamp < old.timestamp { incomplete = true; return }
            guard let model = Self.model(payload["model"]), let id = Self.identifier(payload["turn_id"]) else {
                context = nil; incomplete = true; return
            }
            context = CodexContext(model: model, turnID: id, timestamp: timestamp)
            return
        }
        guard let info = payload["info"] as? [String: Any],
              let numbers = CodexTokenNumbers.parse(info["total_token_usage"]) else {
            // Some token_count events intentionally have info:null (no usage yet).
            if !(payload["info"] is NSNull) { incomplete = true }
            return
        }
        guard sessionID != nil else { incomplete = true; return }
        if let previousAt = baselineAt, timestamp < previousAt { incomplete = true; return }
        let increment: CodexTokenNumbers
        if let old = baseline {
            guard let delta = numbers.delta(after: old) else {
                // Keep the high-water baseline: a rollback cannot replay history.
                incomplete = true; return
            }
            increment = delta
        } else {
            let last = CodexTokenNumbers.parse(info["last_token_usage"])
            if last == numbers, forkBoundary == nil, let start = sessionStartedAt, start <= timestamp {
                increment = numbers
            } else {
                baseline = numbers; baselineAt = timestamp
                if timestamp >= dayStart { incomplete = true }
                return
            }
        }
        baseline = numbers; baselineAt = timestamp
        guard increment.total > 0 else { return }
        guard timestamp >= dayStart, timestamp < dayEnd else { return }
        if let boundary = forkBoundary, timestamp < boundary { return }
        guard let context, context.timestamp <= timestamp,
              forkBoundary == nil || context.timestamp >= forkBoundary! else { incomplete = true; return }
        let key = CodexRecordKey(turnID: context.turnID, timestamp: timestamp, cumulative: numbers)
        guard records[key] == nil else { return }
        guard records.count < maxRecords else { incomplete = true; return }
        records[key] = CodexUsageRecord(key: key, model: context.model, numbers: increment)
        if latestModelAt == nil || timestamp >= latestModelAt! { latestModel = context.model; latestModelAt = timestamp }
    }
    static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count <= 64, UUID(uuidString: text) != nil else { return nil }
        return text.lowercased()
    }
    static func model(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 80,
              text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else { return nil }
        return text
    }
    private static let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private static let plainDate = ISO8601DateFormatter()
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, text.utf8.count <= 40 else { return nil }
        return fractionalDate.date(from: text) ?? plainDate.date(from: text)
    }
}

struct CodexRecordsBudget {
    var maxEntries = 8_000
    var maxFiles = 512
    var maxDirectories = 512
    var maxDepth = 5
    var bytesPerScan = 4 * 1_024 * 1_024
    var bytesPerFile = 4 * 1_024 * 1_024
    var maxLineBytes = 128 * 1_024
    var maxRecordsPerFile = 8_192
    var maxRecordsTotal = 24_576
    var secondsPerScan = 0.35
}
private struct CodexRecordFile {
    let names: [String]
    let ancestors: [CodexNodeIdentity]
    let identity: CodexNodeIdentity
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
}

/// Reader has one worker-queue owner; it never starts a process or touches another
/// Codex directory. Its only durable state is in-memory numeric parsing metadata.
final class CodexLocalRecordsReader {
    private let root: URL
    private let budget: CodexRecordsBudget
    private var scope: CodexRecordsScope?
    private var states: [CodexNodeIdentity: CodexLocalRecordState] = [:]
    private var dayStart: Date?
    private var roundRobin = 0
    private var catalog: [CodexRecordFile] = []
    private var catalogAt: Date?
    private var catalogPartial = false
    private var catalogValid = false
    private var failedFiles = Set<CodexNodeIdentity>()
    private(set) var needsCatchUp = false
    private(set) var bytesReadLastScan = 0
    var retainedRecordCount: Int { states.values.reduce(0) { $0 + $1.records.count } }

    init(root: URL, budget: CodexRecordsBudget = CodexRecordsBudget()) { self.root = root; self.budget = budget }

    func scan(now: Date, cancellation: CodexRecordsCancellation) -> CodexMonitorSnapshot? {
        guard !cancellation.isCancelled else { return nil }
        bytesReadLastScan = 0
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: now)
        let end = start.addingTimeInterval(86_400)
        if dayStart != start {
            // Keep validated cumulative baselines/cursors: an old session may cross midnight.
            for state in states.values { state.records.removeAll(); state.incomplete = false }
            catalogAt = nil; dayStart = start
        }
        needsCatchUp = false
        guard let (verified, rootFD) = CodexRecordsScope.open(root, expected: scope) else {
            states.removeAll(); catalog.removeAll(); catalogValid = false; catalogAt = nil
            var snapshot = CodexMonitorSnapshot(); snapshot.recordsEnabled = true; snapshot.connection = .unavailable
            snapshot.noticeKey = "로컬 Codex 기록을 읽을 수 없습니다"; snapshot.updatedAt = now
            return cancellation.isCancelled ? nil : snapshot
        }
        scope = verified
        defer { Darwin.close(rootFD) }
        let deadline = ProcessInfo.processInfo.systemUptime + budget.secondsPerScan
        if catalogAt == nil || now.timeIntervalSince(catalogAt!) >= 16 {
            let result = enumerate(rootFD: rootFD, cancellation: cancellation, deadline: deadline, dayStart: start)
            guard !cancellation.isCancelled else { return nil }
            catalog = result.files; catalogPartial = result.partial; catalogValid = true; catalogAt = now
            failedFiles.removeAll()
            let identities = Set(catalog.map(\.identity))
            states = states.filter { identities.contains($0.key) }
            if roundRobin >= catalog.count { roundRobin = 0 }
        }
        var remaining = budget.bytesPerScan
        var examined = 0
        while examined < catalog.count, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline {
            guard !cancellation.isCancelled else { return nil }
            let index = (roundRobin + examined) % catalog.count
            let file = catalog[index]
            if !failedFiles.contains(file.identity) {
                read(file, rootFD: rootFD, now: now, dayStart: start, dayEnd: end,
                     remaining: &remaining, cancellation: cancellation, deadline: deadline)
            }
            examined += 1
        }
        if !catalog.isEmpty { roundRobin = (roundRobin + max(1, examined)) % catalog.count }
        guard !cancellation.isCancelled else { return nil }
        // Never publish data from a directory that was exchanged during a scan.
        guard let (_, verificationFD) = CodexRecordsScope.open(root, expected: verified) else {
            states.removeAll(); catalog.removeAll(); catalogValid = false; catalogAt = nil
            var snapshot = CodexMonitorSnapshot(); snapshot.recordsEnabled = true; snapshot.connection = .unavailable
            snapshot.noticeKey = "로컬 Codex 기록을 읽을 수 없습니다"; snapshot.updatedAt = now
            return snapshot
        }
        Darwin.close(verificationFD)
        needsCatchUp = catalog.contains { file in
            guard !failedFiles.contains(file.identity) else { return false }
            guard let state = states[file.identity] else { return true }
            let size = state.catalogSizeAtRead == file.size ? state.knownSize : max(file.size, state.knownSize)
            return state.offset < size && !state.waitingForAppend
        }
        return snapshot(now: now, dayStart: start, dayEnd: end)
    }

    private func enumerate(rootFD: Int32, cancellation: CodexRecordsCancellation, deadline: TimeInterval,
                           dayStart: Date) -> (files: [CodexRecordFile], partial: Bool) {
        struct Entry { let name: String; let info: stat }
        var files: [CodexRecordFile] = []
        var entries = 0; var directories = 0; var partial = false
        func visit(_ fd: Int32, names: [String], ancestors: [CodexNodeIdentity]) {
            guard !cancellation.isCancelled else { return }
            let traversalFD = dup(fd)
            guard traversalFD >= 0 else { partial = true; return }
            guard let directory = fdopendir(traversalFD) else { Darwin.close(traversalFD); partial = true; return }
            defer { closedir(directory) }
            var children: [Entry] = []
            while !cancellation.isCancelled {
                guard entries < budget.maxEntries, ProcessInfo.processInfo.systemUptime < deadline else { partial = true; break }
                guard let entry = readdir(directory) else { break }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." || name.hasPrefix(".") { continue }
                entries += 1
                var info = stat()
                guard name.withCString({ fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else { partial = true; continue }
                guard info.st_uid == geteuid(), info.st_dev == scope?.device else { partial = true; continue }
                if (info.st_mode & S_IFMT) == S_IFLNK { partial = true; continue }
                children.append(Entry(name: name, info: info))
            }
            // Session folders use year/month/day names. Visiting those in reverse
            // order makes current records useful even when historic metadata hits a cap.
            children.sort {
                let leftDirectory = ($0.info.st_mode & S_IFMT) == S_IFDIR
                let rightDirectory = ($1.info.st_mode & S_IFMT) == S_IFDIR
                if leftDirectory != rightDirectory { return leftDirectory }
                if leftDirectory { return $0.name > $1.name }
                if $0.info.st_mtimespec.tv_sec != $1.info.st_mtimespec.tv_sec {
                    return $0.info.st_mtimespec.tv_sec > $1.info.st_mtimespec.tv_sec
                }
                return $0.name < $1.name
            }
            for child in children {
                guard !cancellation.isCancelled else { return }
                guard files.count < budget.maxFiles, ProcessInfo.processInfo.systemUptime < deadline else { partial = true; return }
                let name = child.name; let info = child.info
                let kind = info.st_mode & S_IFMT
                if kind == S_IFDIR {
                    guard names.count < budget.maxDepth, directories < budget.maxDirectories,
                          (info.st_mode & 0o022) == 0 else { partial = true; continue }
                    directories += 1
                    let next = name.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
                    guard next >= 0 else { partial = true; continue }
                    var opened = stat()
                    if fstat(next, &opened) == 0, CodexNodeIdentity(opened) == CodexNodeIdentity(info),
                       (opened.st_mode & 0o022) == 0 {
                        visit(next, names: names + [name], ancestors: ancestors + [CodexNodeIdentity(info)])
                    } else { partial = true }
                    Darwin.close(next)
                } else if kind == S_IFREG, name.hasSuffix(".jsonl") {
                    if TimeInterval(info.st_mtimespec.tv_sec) < dayStart.timeIntervalSince1970,
                       states[CodexNodeIdentity(info)] == nil { continue }
                    files.append(CodexRecordFile(names: names + [name], ancestors: ancestors,
                        identity: CodexNodeIdentity(info), size: Int64(info.st_size),
                        modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec)))
                }
            }
        }
        visit(rootFD, names: [], ancestors: [])
        return (files.sorted {
            if $0.modifiedSeconds != $1.modifiedSeconds { return $0.modifiedSeconds > $1.modifiedSeconds }
            return $0.identity.inode < $1.identity.inode
        }, partial)
    }

    private func openFile(_ file: CodexRecordFile, rootFD: Int32, cancellation: CodexRecordsCancellation) -> Int32? {
        var parent = dup(rootFD)
        guard parent >= 0 else { return nil }
        defer { Darwin.close(parent) }
        for (index, component) in file.names.dropLast().enumerated() {
            guard !cancellation.isCancelled else { return nil }
            let next = component.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard next >= 0 else { return nil }
            var info = stat()
            guard fstat(next, &info) == 0, CodexNodeIdentity(info) == file.ancestors[index],
                  (info.st_mode & 0o022) == 0 else { Darwin.close(next); return nil }
            Darwin.close(parent); parent = next
        }
        guard !cancellation.isCancelled, let name = file.names.last else { return nil }
        let fd = name.withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, CodexNodeIdentity(info) == file.identity,
              (info.st_mode & S_IFMT) == S_IFREG else { Darwin.close(fd); return nil }
        return fd
    }

    private func read(_ file: CodexRecordFile, rootFD: Int32, now: Date, dayStart: Date, dayEnd: Date,
                      remaining: inout Int, cancellation: CodexRecordsCancellation, deadline: TimeInterval) {
        guard !cancellation.isCancelled else { return }
        guard let fd = openFile(file, rootFD: rootFD, cancellation: cancellation) else {
            states.removeValue(forKey: file.identity); failedFiles.insert(file.identity); catalogPartial = true; return
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { failedFiles.insert(file.identity); catalogPartial = true; return }
        let size = Int64(info.st_size)
        var state = states[file.identity] ?? CodexLocalRecordState()
        let modified = (Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec))
        let oldModified = (state.modifiedSeconds, state.modifiedNanos)
        if size < state.knownSize || (size == state.knownSize && modified != oldModified && state.knownSize > 0) {
            state = CodexLocalRecordState(); state.incomplete = true
        }
        state.knownSize = size; state.modifiedSeconds = modified.0; state.modifiedNanos = modified.1
        state.catalogSizeAtRead = file.size
        states[file.identity] = state
        guard state.offset < size else { state.partialLine = false; return }
        var cursor = state.offset
        var lineStart = cursor
        var line = Data()
        var fileRemaining = min(remaining, budget.bytesPerFile)
        let existingRecords = states.values.reduce(0) { $0 + $1.records.count }
        let recordLimit = min(budget.maxRecordsPerFile, state.records.count + max(0, budget.maxRecordsTotal - existingRecords))
        state.partialLine = false
        var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
        while cursor < size, fileRemaining > 0, ProcessInfo.processInfo.systemUptime < deadline {
            guard !cancellation.isCancelled else { return }
            let count = min(buffer.count, fileRemaining, Int(min(Int64(Int.max), size - cursor)))
            let received = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, count, off_t(cursor)) }
            guard received > 0 else { state.incomplete = true; failedFiles.insert(file.identity); return }
            bytesReadLastScan += received
            remaining -= received; fileRemaining -= received
            var position = 0
            while position < received {
                guard !cancellation.isCancelled else { return }
                let newline: Int? = buffer.withUnsafeBytes { raw in
                    let base = raw.baseAddress!.advanced(by: position)
                    guard let found = memchr(base, 10, received - position) else { return nil }
                    return position + base.distance(to: found)
                }
                let end = newline ?? received
                let segmentLength = end - position
                if !state.discardedLine {
                    if segmentLength <= budget.maxLineBytes - line.count {
                        line.append(contentsOf: buffer[position..<end])
                    } else {
                        line.removeAll(keepingCapacity: false); state.discardedLine = true
                        state.context = nil; state.incomplete = true
                    }
                }
                cursor += Int64(segmentLength)
                position = end
                if newline != nil {
                    cursor += 1; position += 1
                    if !state.discardedLine, !line.isEmpty {
                        state.consume(line, now: now, dayStart: dayStart, dayEnd: dayEnd, maxRecords: recordLimit)
                    }
                    line.removeAll(keepingCapacity: true); state.discardedLine = false
                    state.offset = cursor; lineStart = cursor
                }
            }
            if state.discardedLine { state.offset = cursor; lineStart = cursor }
        }
        // Discard raw partial bytes; their bounded prefix is reread next scan.
        if !line.isEmpty { state.offset = lineStart; state.partialLine = true }
        if state.discardedLine { state.partialLine = true }
        state.waitingForAppend = cursor == size && state.partialLine
    }

    private func snapshot(now: Date, dayStart: Date, dayEnd: Date) -> CodexMonitorSnapshot {
        var snapshot = CodexMonitorSnapshot(); snapshot.recordsEnabled = true
        snapshot.connection = .connected; snapshot.updatedAt = now
        var incomplete = catalogPartial || !catalogValid
        var records: [CodexRecordKey: CodexUsageRecord] = [:]
        var conflictingKeys = Set<CodexRecordKey>()
        for file in catalog {
            guard let state = states[file.identity] else { incomplete = true; continue }
            if state.offset < max(file.size, state.knownSize) || state.partialLine || state.incomplete { incomplete = true }
            for (key, record) in state.records where key.timestamp >= dayStart && key.timestamp < dayEnd {
                guard !conflictingKeys.contains(key) else { continue }
                if let old = records[key] {
                    if old.model != record.model || old.numbers != record.numbers {
                        incomplete = true; records.removeValue(forKey: key); conflictingKeys.insert(key)
                    }
                    continue
                }
                guard records.count < budget.maxRecordsTotal else { incomplete = true; break }
                records[key] = record
            }
        }
        var models: [String: CodexModelUsage] = [:]
        var total: Int64 = 0
        for record in records.values {
            var usage = models[record.model] ?? CodexModelUsage(model: record.model)
            let values = [usage.inputTokens, usage.cachedInputTokens, usage.outputTokens, usage.reasoningOutputTokens, usage.totalTokens, total]
            let adds = [record.numbers.input, record.numbers.cached, record.numbers.output, record.numbers.reasoning, record.numbers.total, record.numbers.total]
            guard zip(values, adds).allSatisfy({ $0.0 <= Int64.max - $0.1 }) else { incomplete = true; continue }
            usage.inputTokens += record.numbers.input; usage.cachedInputTokens += record.numbers.cached
            usage.outputTokens += record.numbers.output; usage.reasoningOutputTokens += record.numbers.reasoning
            usage.totalTokens += record.numbers.total; total += record.numbers.total
            models[record.model] = usage
            if snapshot.lastRecordAt == nil || record.key.timestamp > snapshot.lastRecordAt! {
                snapshot.lastRecordAt = record.key.timestamp; snapshot.currentModel = record.model
            }
        }
        snapshot.incomplete = incomplete
        snapshot.recordsCount = records.isEmpty && incomplete ? nil : records.count
        snapshot.dailyTokens = records.isEmpty && incomplete ? nil : total
        snapshot.models = models.values.sorted { $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens }
        if incomplete { snapshot.noticeKey = "일부 로컬 기록만 집계했습니다" }
        else if records.isEmpty { snapshot.noticeKey = "사용량이 기록된 로컬 항목이 없습니다" }
        else { snapshot.noticeKey = "이 Mac의 로컬 기록을 UTC 날짜로 집계합니다" }
        return snapshot
    }
}

final class CodexMonitor {
    static let recordsEnabledKey = "codexLocalRecordsEnabledV1"
    var onUpdate: ((CodexMonitorSnapshot) -> Void)?
    private let queue = DispatchQueue(label: "MacThermal.CodexLocalRecords", qos: .utility)
    private let defaults: UserDefaults
    private let recordsRoot: URL
    private let runningProvider: () -> Bool
    private let launchDateProvider: () -> Date?
    private let workspaceNotificationsEnabled: Bool
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var enabled = false
    private var generation: UInt = 0
    private var cancellation = CodexRecordsCancellation()
    private var pollInFlight = false
    private var catchUpWork: DispatchWorkItem?
    private var hasDeliveredRead = false
    private var reader: CodexLocalRecordsReader? // Worker queue only.

    init(defaults: UserDefaults = .standard,
         recordsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true),
         isRunning: @escaping () -> Bool = CodexMonitor.isCodexRunning,
         launchDate: @escaping () -> Date? = CodexMonitor.codexLaunchDate,
         workspaceNotificationsEnabled: Bool = true) {
        self.defaults = defaults; self.recordsRoot = recordsRoot
        runningProvider = isRunning; launchDateProvider = launchDate
        self.workspaceNotificationsEnabled = workspaceNotificationsEnabled
    }
    static func isCodexRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
    }
    static func codexLaunchDate() -> Date? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").compactMap(\.launchDate).min()
    }
    func start() {
        precondition(Thread.isMainThread)
        guard !started else { return }
        started = true; enabled = defaults.bool(forKey: Self.recordsEnabledKey)
        replaceReader()
        if workspaceNotificationsEnabled {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          application.bundleIdentifier == "com.openai.codex" else { return }
                    self?.refresh()
                })
            }
        }
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 1; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        refresh()
    }
    func setRecordsEnabled(_ value: Bool) {
        precondition(Thread.isMainThread)
        defaults.set(value, forKey: Self.recordsEnabledKey)
        guard value != enabled else { if started { refresh() }; return }
        enabled = value
        // Permission revocation is synchronous; queued work sees this token now.
        replaceReader()
        if started { refresh() }
    }
    private func replaceReader() {
        cancellation.cancel(); generation &+= 1
        catchUpWork?.cancel(); catchUpWork = nil; pollInFlight = false; hasDeliveredRead = false
        cancellation = CodexRecordsCancellation()
        let shouldRead = enabled; let root = recordsRoot; let token = cancellation
        queue.async { [weak self] in
            guard let self else { return }
            self.reader = shouldRead && !token.isCancelled ? CodexLocalRecordsReader(root: root) : nil
        }
    }
    func refresh() {
        precondition(Thread.isMainThread)
        guard started else { return }
        let running = runningProvider()
        let launchDate = running ? launchDateProvider() : nil
        guard enabled else {
            var snapshot = CodexMonitorSnapshot(); snapshot.appStartedAt = launchDate
            snapshot.recordsEnabled = false; snapshot.connection = running ? .unavailable : .notRunning
            snapshot.noticeKey = "로컬 기록 읽기가 꺼져 있습니다"; onUpdate?(snapshot); return
        }
        guard !pollInFlight else { return }
        catchUpWork?.cancel(); catchUpWork = nil
        pollInFlight = true
        if !hasDeliveredRead {
            var snapshot = CodexMonitorSnapshot(); snapshot.recordsEnabled = true; snapshot.connection = .connecting
            snapshot.appStartedAt = launchDate; snapshot.noticeKey = "로컬 Codex 기록을 읽는 중입니다"; onUpdate?(snapshot)
        }
        let token = cancellation; let revision = generation
        queue.async { [weak self] in
            guard let self, !token.isCancelled,
                  var snapshot = self.reader?.scan(now: Date(), cancellation: token), !token.isCancelled else { return }
            let catchUp = self.reader?.needsCatchUp == true
            snapshot.appStartedAt = launchDate
            DispatchQueue.main.async { [weak self] in
                guard let self, self.started, self.enabled, self.generation == revision, !token.isCancelled else { return }
                self.pollInFlight = false; self.hasDeliveredRead = true
                self.onUpdate?(snapshot)
                if catchUp, self.enabled, self.generation == revision, !token.isCancelled {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.started, self.enabled, self.generation == revision, !token.isCancelled else { return }
                        self.catchUpWork = nil; self.refresh()
                    }
                    self.catchUpWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
                }
            }
        }
    }
    func stop() {
        precondition(Thread.isMainThread)
        guard started else { return }
        started = false; cancellation.cancel(); generation &+= 1
        catchUpWork?.cancel(); catchUpWork = nil; pollInFlight = false
        timer?.invalidate(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers.removeAll()
        queue.async { [weak self] in self?.reader = nil }
    }
    deinit {
        cancellation.cancel(); timer?.invalidate()
        catchUpWork?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
