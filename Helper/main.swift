import Foundation
import XPC
import Darwin

private enum FanHelperClock {
    static let scale: Double? = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return nil }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    static func seconds() -> Double? {
        guard let scale else { return nil }
        let result = Double(mach_continuous_time()) * scale
        return result.isFinite && result >= 0 ? result : nil
    }
}
private struct FanHelperConfiguration: Codable {
    let version: Int
    let clientCDHash: String
    let allowedUID: UInt32
    var valid: Bool {
        version == 1 && allowedUID >= 501 &&
        (clientCDHash.count == 40 || clientCDHash.count == 64) &&
        clientCDHash.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }
}
private final class LiveFanHardware: FanServiceHardware {
    func read() -> FanHardwareState {
        let r = mtfc_read()
        let count = Int(r.count)
        guard (1...8).contains(count), r.valid_mask == (1 << count) - 1, r.gate <= 0 else {
            return FanHardwareState(fans: [], automatic: false, supported: false, cpuTemperature: nil, thermalPressureSafe: false, targets: [])
        }
        let actual = withUnsafeBytes(of: r.actual) { Array($0.bindMemory(to: Double.self).prefix(count)) }
        let low = withUnsafeBytes(of: r.minimum) { Array($0.bindMemory(to: Double.self).prefix(count)) }
        let high = withUnsafeBytes(of: r.maximum) { Array($0.bindMemory(to: Double.self).prefix(count)) }
        let targets = withUnsafeBytes(of: r.target) { Array($0.bindMemory(to: Double.self).prefix(count)) }
        let modes = withUnsafeBytes(of: r.mode) { Array($0.bindMemory(to: Int32.self).prefix(count)) }
        let temperature = mtfc_cpu_temperature()
        let pressure = ProcessInfo.processInfo.thermalState
        return FanHardwareState(fans: (0..<count).map { FanControlWire.Fan(actual: actual[$0], minimum: low[$0], maximum: high[$0]) },
            automatic: modes.allSatisfy { $0 == 0 }, supported: true,
            cpuTemperature: temperature > 0 ? temperature : nil,
            thermalPressureSafe: pressure == .nominal || pressure == .fair, targets: targets)
    }
    func start(rpm: Int) -> Bool { mtfc_start(Int32(rpm)) == 1 }
    func restore(count: Int) -> Bool { mtfc_restore(Int32(count)) == 1 }
}

private final class FanHelperDaemon {
    let config: FanHelperConfiguration
    let core = FanServiceCore(hardware: LiveFanHardware(), storage: FanRootRecoveryStore(), clock: FanHelperClock.seconds)
    var listener: xpc_connection_t?
    var timer: DispatchSourceTimer?
    private var timerArmed = false
    var signals: [DispatchSourceSignal] = []
    init(config: FanHelperConfiguration) { self.config = config }

    func start() throws {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard mtfc_watch_power({ context, sleeping in
            guard let context else { return }
            let daemon = Unmanaged<FanHelperDaemon>.fromOpaque(context).takeUnretainedValue()
            if sleeping == 1 { daemon.core.sleep() }
            else { mtfc_reset_connection(); daemon.core.wake() }
            daemon.updateWatchdog()
        }, pointer) == 1 else { throw CocoaError(.featureUnsupported) }
        let listener = xpc_connection_create_mach_service(FanControlWire.service, .main, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        self.listener = listener
        xpc_connection_set_event_handler(listener) { [weak self] event in
            guard let self, xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            let peer = event
            self.accept(peer)
        }
        xpc_connection_resume(listener)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in
            self?.refreshMaintenance(); self?.core.tick(); self?.updateWatchdog()
        }
        self.timer = timer; timer.resume(); updateWatchdog()
        for code in [SIGTERM, SIGINT] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler { [weak self] in
                if self?.core.prepareTermination() == true { exit(0) }
                self?.updateWatchdog()
            }
            signals.append(source); source.resume()
        }
    }
    private func updateWatchdog() {
        guard let timer, timerArmed != core.hasOwnedLease else { return }
        timerArmed = core.hasOwnedLease
        if timerArmed { timer.schedule(deadline: .now() + 2, repeating: .seconds(2), leeway: .milliseconds(100)) }
        else { timer.schedule(deadline: .distantFuture) }
    }
    private func refreshMaintenance() {
        // Only root can create/remove this sentinel in the verified parent.
        do { core.inhibited = try FanRootFiles.read(FanRootFiles.maintenance, missingOK: true) != nil }
        catch { core.inhibited = true }
    }
    private func accept(_ peer: xpc_connection_t) {
        let requirement = "cdhash H\"\(config.clientCDHash)\""
        guard xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0 else { xpc_connection_cancel(peer); return }
        let identity = UUID()
        xpc_connection_set_event_handler(peer) { [weak self] event in
            guard let self else { return }
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
                self.core.disconnected(identity)
                self.updateWatchdog()
                xpc_connection_set_event_handler(peer) { _ in }
                xpc_connection_cancel(peer)
                return
            }
            guard xpc_connection_get_euid(peer) == self.config.allowedUID,
                  xpc_dictionary_get_count(event) == 1 else { xpc_connection_cancel(peer); return }
            var length = 0
            guard let bytes = xpc_dictionary_get_data(event, "payload", &length),
                  length > 0, length <= FanControlWire.maxPayload,
                  let request = try? JSONDecoder().decode(FanControlWire.Request.self, from: Data(bytes: bytes, count: length)),
                  request.valid else { xpc_connection_cancel(peer); return }
            self.refreshMaintenance()
            let result = self.core.handle(request, peer: identity)
            self.updateWatchdog()
            guard let reply = xpc_dictionary_create_reply(event), let encoded = try? JSONEncoder().encode(result) else { return }
            encoded.withUnsafeBytes { buffer in xpc_dictionary_set_data(reply, "payload", buffer.baseAddress!, buffer.count) }
            xpc_connection_send_message(peer, reply)
        }
        xpc_connection_resume(peer)
    }
}

guard getuid() == 0, geteuid() == 0 else { fputs("Fan helper requires its reviewed root installation.\n", stderr); exit(77) }
do {
    // Read-only CLI used by the root uninstaller AFTER inhibiting new requests.
    if CommandLine.arguments == [CommandLine.arguments[0], "--verify-auto"] {
        let state = LiveFanHardware().read()
        exit(state.supported && state.automatic ? 0 : 1)
    }
    guard CommandLine.arguments.count == 1,
          let data = try FanRootFiles.read(FanRootFiles.config),
          let config = try? JSONDecoder().decode(FanHelperConfiguration.self, from: data), config.valid else { throw CocoaError(.fileReadCorruptFile) }
    let daemon = FanHelperDaemon(config: config)
    try daemon.start()
    withExtendedLifetime(daemon) { CFRunLoopRun() }
} catch {
    fputs("Fan helper unavailable; verify reviewed installation and recovery state.\n", stderr)
    exit(78)
}
