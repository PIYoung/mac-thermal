import Foundation
import Security
import Darwin

/// Private stdio only; there is no socket proxy, model call or thread API.
protocol CodexQuotaWire: AnyObject {
    func start(message: @escaping (Data) -> Void, exited: @escaping () -> Void) -> Bool
    func send(_ data: Data) -> Bool
    func close(completion: @escaping () -> Void)
}

extension CodexQuotaWire { func close() { close(completion: {}) } }

enum CodexAccountStore {
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Mac Thermal/Codex Account", isDirectory: true)
    }

    /// Walk only real, user-owned directories. Never follow an account-store link.
    static func openDirectory(home: URL, create: Bool) -> Int32? {
        var fd = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var homeInfo = stat()
        guard fstat(fd, &homeInfo) == 0, homeInfo.st_uid == getuid(), homeInfo.st_mode & 0o022 == 0 else {
            Darwin.close(fd); errno = EACCES; return nil
        }
        for component in ["Library", "Application Support", "Mac Thermal", "Codex Account"] {
            var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { Darwin.close(fd); return nil }
                next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { let failure = errno; Darwin.close(fd); errno = failure; return nil }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                Darwin.close(next); Darwin.close(fd); errno = EACCES; return nil
            }
            Darwin.close(fd); fd = next
        }
        if create, fchmod(fd, 0o700) != 0 { Darwin.close(fd); return nil }
        return fd
    }

    static func clearCredential(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        guard let fd = openDirectory(home: home, create: false) else { return errno == ENOENT }
        defer { Darwin.close(fd) }
        // The installed Codex manages the file credential store. Unlink the
        // exact private file, without opening tokens or traversing a symlink.
        return unlinkat(fd, "auth.json", 0) == 0 || errno == ENOENT
    }
}

final class CodexInstalledQuotaWire: CodexQuotaWire {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let io = DispatchQueue(label: "MacThermal.CodexQuotaWire", qos: .utility)
    private var buffer = Data()
    private var closed = false

    static func trustedExecutable(_ url: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"" as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)), requirement) == errSecSuccess
    }

    func start(message: @escaping (Data) -> Void, exited: @escaping () -> Void) -> Bool {
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                          "/Applications/Codex.app/Contents/Resources/codex"]
        guard let executable = candidates.map({ URL(fileURLWithPath: $0) }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path) && Self.trustedExecutable($0)
        }), let fd = CodexAccountStore.openDirectory(home: URL(fileURLWithPath: NSHomeDirectory()), create: true) else { return false }
        Darwin.close(fd)
        process.executableURL = executable
        process.currentDirectoryURL = CodexAccountStore.url
        // Do not inherit API keys, auth overrides, workspace config or a user's
        // Codex home. Existing desktop/CLI authentication is never imported.
        process.environment = ["HOME": NSHomeDirectory(), "CODEX_HOME": CodexAccountStore.url.path,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                               "TMPDIR": NSTemporaryDirectory()]
        process.arguments = ["app-server", "--listen", "stdio://", "--strict-config",
                             "-c", "cli_auth_credentials_store=\"file\"", "-c", "analytics.enabled=false"]
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { return false }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard let self else { return }
            self.io.async {
                guard !self.closed else { return }
                guard !bytes.isEmpty, bytes.count <= 1_048_576, self.buffer.count + bytes.count <= 1_048_576 else {
                    DispatchQueue.main.async { [weak self] in self?.close(); exited() }; return
                }
                self.buffer.append(bytes)
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer.prefix(upTo: end)
                    self.buffer.removeSubrange(...end)
                    guard line.count <= 131_072 else {
                        DispatchQueue.main.async { [weak self] in self?.close(); exited() }; return
                    }
                    let value = Data(line)
                    DispatchQueue.main.async { message(value) }
                }
                if self.buffer.count > 131_072 { DispatchQueue.main.async { [weak self] in self?.close(); exited() } }
            }
        }
        process.terminationHandler = { _ in DispatchQueue.main.async { exited() } }
        do { try process.run(); return true }
        catch { close(); return false }
    }

    func send(_ data: Data) -> Bool {
        guard process.isRunning, data.count <= 16_384 else { return false }
        do { try input.fileHandleForWriting.write(contentsOf: data + Data([10])); return true }
        catch { return false }
    }

    func close(completion: @escaping () -> Void) {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
        io.async {
            self.closed = true; self.buffer.removeAll()
            if self.process.isRunning {
                self.process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while self.process.isRunning && Date() < deadline { usleep(20_000) }
                if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
                self.process.waitUntilExit()
            }
            DispatchQueue.main.async(execute: completion)
        }
    }
}

/// Main-queue account state machine. Its wire is injectable for tests, which
/// never start the real helper, use a user's account or contact a service.
final class CodexQuotaClient {
    private enum Request: Equatable {
        case initialize, account, login, limits, usage, cancel, logout
        var method: String {
            switch self {
            case .initialize: return "initialize"
            case .account: return "account/read"
            case .login: return "account/login/start"
            case .limits: return "account/rateLimits/read"
            case .usage: return "account/usage/read"
            case .cancel: return "account/login/cancel"
            case .logout: return "account/logout"
            }
        }
    }
    static let enabledKey = "codexAccountQuotaEnabledV1"
    static let removalKey = "codexAccountRemovalPendingV1"
    static let usageKey = "codexDailyUsageApprovedV1"
    static let summaryKey = "codexAccountSummaryApprovedV1"
    private var usage = CodexUsageSnapshot()
    private var lastUsageAttempt: Date?
    private let defaults: UserDefaults
    private let factory: () -> CodexQuotaWire
    private let erase: () -> Bool
    private let now: () -> Date
    private var wire: CodexQuotaWire?
    private var pending: [Int: Request] = [:]
    private var deadlines: [Int: DispatchWorkItem] = [:]
    private var nextID = 0
    private var generation = 0
    private var initialized = false
    private var authenticated = false
    private var wantsLogin = false
    private var loginID: String?
    private var loginDeadline: DispatchWorkItem?
    private var poll: Timer?
    private var lastAttempt: Date?
    private var disconnecting = false
    private var erasing = false
    private(set) var latest = CodexQuotaSnapshot()
    var onUpdate: ((CodexQuotaSnapshot) -> Void)?
    /// The one-time device code is delivered directly to the login UI. It is
    /// neither stored in defaults nor included in snapshots/accessibility tips.
    var onDeviceLogin: ((URL, String) -> Void)?
    var onCredentialRemovalFailure: (() -> Void)?

    init(defaults: UserDefaults = .standard, factory: @escaping () -> CodexQuotaWire = { CodexInstalledQuotaWire() },
         erase: @escaping () -> Bool = { CodexAccountStore.clearCredential() }, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.factory = factory; self.erase = erase; self.now = now
    }

    func startSavedConnection() {
        if defaults.bool(forKey: Self.removalKey) { finishDisconnect(); return }
        guard defaults.bool(forKey: Self.enabledKey) else { return }
        connect(login: false)
    }

    /// Only the explicit in-app permission review calls this method.
    func connectApproved() {
        guard !disconnecting else { return }
        if defaults.bool(forKey: Self.removalKey) { finishDisconnect(); return }
        defaults.set(true, forKey: Self.enabledKey)
        connect(login: true)
    }

    private func connect(login: Bool) {
        wantsLogin = login
        if wire != nil, initialized { request(.account, ["refreshToken": false]); return }
        stop()
        wantsLogin = login
        publish(CodexQuotaSnapshot(connection: .connecting))
        let revision = generation
        let candidate = factory()
        wire = candidate
        guard candidate.start(message: { [weak self] data in
            guard let self, self.generation == revision else { return }; self.receive(data)
        }, exited: { [weak self] in
            guard let self, self.generation == revision else { return }; self.fail()
        }) else { stop(); publish(CodexQuotaSnapshot(connection: .helperMissing)); return }
        request(.initialize, ["clientInfo": ["name": "mac_thermal_quota", "title": "Mac Thermal",
                                             "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"]])
    }

    func setUsageApproved(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.usageKey)
        usage = CodexUsageSnapshot(state: enabled ? .loading : .disabled)
        if !enabled {
            defaults.set(false, forKey: Self.summaryKey)
            for id in pending.filter({ $0.value == .usage }).map(\.key) {
                pending.removeValue(forKey: id); deadlines.removeValue(forKey: id)?.cancel()
            }
        }
        publish(latest)
        if enabled { requestUsage(manual: true) }
    }

    func setSummaryApproved(_ enabled: Bool) {
        guard !enabled || defaults.bool(forKey: Self.usageKey) else { return }
        defaults.set(enabled, forKey: Self.summaryKey)
        usage.summaryEnabled = enabled
        usage.summary = CodexAccountSummary()
        publish(latest)
        if enabled { requestUsage(manual: true) }
    }

    func refresh(manual: Bool = true) {
        guard defaults.bool(forKey: Self.enabledKey), initialized, authenticated,
              lastAttempt.map({ now().timeIntervalSince($0) >= 15 }) ?? true else { return }
        requestLimits()
        requestUsage(manual: manual)
    }

    func tick() {
        guard latest.connection == .connected,
              !latest.isFresh(at: now()) || latest.windows.contains(where: { $0.resetsAt.map { $0 <= now() } == true }) else { return }
        refresh(manual: false)
    }

    func disconnect() {
        guard !disconnecting else { return }
        disconnecting = true
        defaults.set(false, forKey: Self.enabledKey)
        defaults.set(false, forKey: Self.usageKey)
        defaults.set(false, forKey: Self.summaryKey)
        usage = CodexUsageSnapshot()
        defaults.set(true, forKey: Self.removalKey)
        wantsLogin = false
        loginDeadline?.cancel(); loginDeadline = nil
        if let loginID { request(.cancel, ["loginId": loginID]) }
        self.loginID = nil
        if initialized { request(.logout) }
        else { finishDisconnect() }
        if disconnecting { publish(CodexQuotaSnapshot(connection: .disconnecting)) }
    }

    func suspend() {
        if disconnecting { finishDisconnect(); return }
        let enabled = defaults.bool(forKey: Self.enabledKey)
        stop()
        if enabled { publish(CodexQuotaSnapshot(connection: .unavailable)) }
    }

    func stop(afterClose: (() -> Void)? = nil) {
        generation += 1
        poll?.invalidate(); poll = nil
        loginDeadline?.cancel(); loginDeadline = nil; loginID = nil
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll(); pending.removeAll()
        initialized = false; authenticated = false; lastAttempt = nil; lastUsageAttempt = nil
        usage = CodexUsageSnapshot(state: defaults.bool(forKey: Self.usageKey) ? .unavailable : .disabled)
        let old = wire; wire = nil
        if let old { old.close(completion: afterClose ?? {}) } else { afterClose?() }
    }

    private func publish(_ snapshot: CodexQuotaSnapshot) {
        var value = snapshot
        value.usage = defaults.bool(forKey: Self.usageKey) ? usage : CodexUsageSnapshot()
        value.usage.summaryEnabled = defaults.bool(forKey: Self.usageKey) && defaults.bool(forKey: Self.summaryKey)
        latest = value; onUpdate?(value)
    }

    private func fail() {
        if !defaults.bool(forKey: Self.enabledKey) { finishDisconnect(); return }
        stop(); publish(CodexQuotaSnapshot(connection: .unavailable))
    }

    private func finishDisconnect() {
        guard !erasing else { return }
        erasing = true; disconnecting = true
        stop { [weak self] in
            guard let self else { return }
            if self.erase() { self.defaults.removeObject(forKey: Self.removalKey) }
            else { self.onCredentialRemovalFailure?() }
            self.erasing = false; self.disconnecting = false
            self.publish(CodexQuotaSnapshot())
        }
    }

    private func request(_ kind: Request, _ params: [String: Any] = [:]) {
        guard let wire, !pending.values.contains(kind), pending.count < 8 else { return }
        nextID += 1; let id = nextID
        pending[id] = kind
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.pending[id] != nil else { return }
            if kind == .usage {
                self.pending.removeValue(forKey: id); self.deadlines.removeValue(forKey: id)
                self.usage = CodexUsageSnapshot(state: .unavailable); self.publish(self.latest)
            } else if kind == .logout { self.finishDisconnect() } else { self.fail() }
        }
        deadlines[id] = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: deadline)
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": kind.method, "params": params]), wire.send(data) else { fail(); return }
    }

    private func requestLimits() {
        guard authenticated else { return }
        lastAttempt = now()
        request(.limits)
    }

    private func requestUsage(manual: Bool = false) {
        guard authenticated, defaults.bool(forKey: Self.usageKey), !pending.values.contains(.usage),
              lastUsageAttempt.map({ now().timeIntervalSince($0) >= (manual ? 15 : 300) }) ?? true else { return }
        lastUsageAttempt = now()
        if usage.state != .ready { usage = CodexUsageSnapshot(state: .loading); publish(latest) }
        request(.usage)
    }

    private func armPoll() {
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh(manual: false) }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common); poll = timer
    }

    private func beginLogin() {
        guard wantsLogin else { publish(CodexQuotaSnapshot(connection: .needsLogin)); return }
        wantsLogin = false
        // Codex owns the OAuth exchange/refresh. The monitor never accepts an
        // API key, a copied desktop token or the internal external-token mode.
        request(.login, ["type": "chatgptDeviceCode"])
    }

    private func receive(_ data: Data) {
        guard data.count <= 131_072, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { fail(); return }
        if let method = value["method"] as? String {
            if let id = value["id"], (id is String || CodexQuotaSnapshot.number(id) != nil), let wire {
                if let reply = try? JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": -32601, "message": "Unsupported request"]]) { _ = wire.send(reply) }
                return
            }
            guard defaults.bool(forKey: Self.enabledKey) else { return }
            let params = value["params"] as? [String: Any] ?? [:]
            if method == "account/login/completed", let loginID, params["loginId"] as? String == loginID {
                self.loginID = nil; loginDeadline?.cancel(); loginDeadline = nil
                guard params["success"] as? Bool == true else { fail(); return }
                request(.account, ["refreshToken": false])
            } else if method == "account/rateLimits/updated", authenticated {
                publish(CodexQuotaSnapshot.parse(params, now: now()))
            } else if method == "account/updated", params["authMode"] is NSNull {
                authenticated = false
                usage = CodexUsageSnapshot(state: defaults.bool(forKey: Self.usageKey) ? .unavailable : .disabled)
                publish(CodexQuotaSnapshot(connection: .needsLogin))
            }
            return
        }
        guard let number = CodexQuotaSnapshot.number(value["id"]), number.rounded() == number,
              number > 0, number <= Double(Int32.max), let kind = pending.removeValue(forKey: Int(number)) else { return }
        deadlines.removeValue(forKey: Int(number))?.cancel()
        guard kind == .logout || kind == .cancel || defaults.bool(forKey: Self.enabledKey) else { return }
        if value["error"] != nil {
            if kind == .usage { usage = CodexUsageSnapshot(state: .unavailable); publish(latest) }
            else if kind == .logout { finishDisconnect() }
            else { fail() }
            return
        }
        guard let result = value["result"] as? [String: Any] else {
            if kind == .usage { usage = CodexUsageSnapshot(state: .unavailable); publish(latest) } else { fail() }
            return
        }
        switch kind {
        case .initialize:
            initialized = true
            guard let wire, let initialized = try? JSONSerialization.data(withJSONObject: ["method": "initialized"]), wire.send(initialized) else { fail(); return }
            request(.account, ["refreshToken": false])
        case .account:
            if let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" {
                authenticated = true; armPoll(); requestLimits(); requestUsage()
            } else { authenticated = false; beginLogin() }
        case .login:
            guard result["type"] as? String == "chatgptDeviceCode",
                  let id = result["loginId"] as? String, UUID(uuidString: id) != nil,
                  let code = result["userCode"] as? String,
                  code.range(of: "^[A-Za-z0-9-]{4,32}$", options: .regularExpression) != nil,
                  let raw = result["verificationUrl"] as? String,
                  let url = URL(string: raw), url.scheme == "https", url.host == "auth.openai.com",
                  url.port == nil, url.user == nil, url.password == nil,
                  url.path == "/codex/device", url.query == nil, url.fragment == nil else { fail(); return }
            loginID = id
            publish(CodexQuotaSnapshot(connection: .authorizing))
            let deadline = DispatchWorkItem { [weak self] in self?.disconnect() }
            loginDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: deadline)
            onDeviceLogin?(url, code)
        case .limits:
            publish(CodexQuotaSnapshot.parse(result, now: now()))
        case .usage:
            guard defaults.bool(forKey: Self.usageKey) else { return }
            usage = CodexUsageSnapshot.parse(result, now: now(), includeSummary: defaults.bool(forKey: Self.summaryKey)); publish(latest)
        case .cancel: break
        case .logout: finishDisconnect()
        }
    }
}
