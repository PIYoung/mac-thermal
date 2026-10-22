import Foundation

struct FanHardwareState {
    var fans: [FanControlWire.Fan]
    var automatic: Bool
    var supported: Bool
    var cpuTemperature: Double?
    var thermalPressureSafe: Bool
    var targets: [Double]
    var safeToCool: Bool {
        guard supported, !fans.isEmpty, fans.allSatisfy(\.valid), thermalPressureSafe,
              let cpuTemperature, cpuTemperature.isFinite else { return false }
        return (1..<100).contains(cpuTemperature)
    }
}
protocol FanServiceHardware {
    func read() -> FanHardwareState
    func start(rpm: Int) -> Bool
    func restore(count: Int) -> Bool
}
struct FanRecoveryRecord: Codable {
    let version: Int
    let lease: UUID
    let fanCount: Int
    var valid: Bool { version == 1 && (1...8).contains(fanCount) }
}
protocol FanRecoveryStore {
    func load() throws -> FanRecoveryRecord?
    func save(_ record: FanRecoveryRecord) throws
    func clear() throws
}

/// A serial, injectable service engine. No root privileges, IPC or hardware
/// operations are built into the policy itself. Production adapters are separate.
final class FanServiceCore {
    private let hardware: FanServiceHardware
    private let storage: FanRecoveryStore
    private let clock: () -> Double?
    private var policy = FanBoostSession()
    private var owner: UUID?
    private var record: FanRecoveryRecord?
    private var rpm: Int?
    private var mayHaveWritten = false
    private var corruptRecovery = false
    private var issue: FanControlWire.Issue = .none
    private var sleeping = false
    var inhibited = false
    var hasOwnedLease: Bool { policy.ownsLease }
    private let serviceID = UUID()
    private var revision: UInt64 = 0

    init(hardware: FanServiceHardware, storage: FanRecoveryStore, clock: @escaping () -> Double?) {
        self.hardware = hardware; self.storage = storage; self.clock = clock
        do {
            if let previous = try storage.load() {
                guard previous.valid else { throw CocoaError(.fileReadCorruptFile) }
                record = previous; mayHaveWritten = true
                policy.recoverOwnedLease(previous.lease)
                restore()
            }
        } catch { corruptRecovery = true; issue = .recovery }
    }

    func handle(_ request: FanControlWire.Request, peer: UUID) -> FanControlWire.Reply {
        guard request.valid else { return reply(peer: peer, overriding: .protocolError) }
        switch request.operation {
        case .status:
            if !policy.ownsLease && !corruptRecovery {
                let state = hardware.read()
                if state.automatic && state.safeToCool { issue = .none }
            }
        case .boost: begin(rpm: request.rpm!, peer: peer)
        case .heartbeat:
            if peer == owner, request.lease == record?.lease, let now = clock(), let lease = request.lease,
               policy.heartbeat(lease: lease, at: now) != nil { restore() }
        case .restore:
            if peer == owner, request.lease == record?.lease { restore() }
        }
        tick()
        return reply(peer: peer)
    }

    private func begin(rpm selected: Int, peer: UUID) {
        guard !corruptRecovery, !policy.ownsLease else { issue = .busy; return }
        guard !inhibited, !sleeping else { issue = .maintenance; return }
        let state = hardware.read()
        guard state.supported, !state.fans.isEmpty else { issue = .unsupported; return }
        guard state.automatic else { issue = .busy; return }
        guard state.safeToCool else { issue = .thermal; return }
        guard let range = FanControlWire.range(state.fans), range.contains(selected), let now = clock() else { issue = .invalidRPM; return }
        policy.confirmAutomatic(at: now)
        guard case .beginCooling(let lease) = policy.start(at: now) else { issue = .unavailable; return }
        record = FanRecoveryRecord(version: 1, lease: lease, fanCount: state.fans.count)
        owner = peer; rpm = selected
        do { try storage.save(record!) }
        catch { issue = .recovery; policy.restorationFailed(lease: lease); return }
        mayHaveWritten = true // Journal is durable before the first possible write.
        guard hardware.start(rpm: selected), let confirmedAt = clock() else { issue = .unsupported; restore(); return }
        if policy.confirmBoost(lease: lease, at: confirmedAt) != nil { restore(); return }
        issue = .none
    }

    func tick() {
        guard policy.ownsLease else { return }
        if inhibited || sleeping { restore(); return }
        if policy.phase == .restoring || policy.phase == .recoveryFailed { restore(); return }
        guard let now = clock() else { issue = .unavailable; restore(); return }
        if policy.tick(at: now) != nil { restore(); return }
        let state = hardware.read()
        guard state.safeToCool, !state.automatic, state.fans.count == record?.fanCount,
              let rpm, state.targets.count == state.fans.count,
              state.targets.allSatisfy({ $0.isFinite && abs($0 - Double(rpm)) <= 1 }) else {
            issue = .thermal; restore(); return
        }
    }

    private func restore() {
        guard let record else { return }
        _ = policy.restore()
        let restored = mayHaveWritten ? hardware.restore(count: record.fanCount) : hardware.read().automatic
        guard restored else { issue = .recovery; policy.restorationFailed(lease: record.lease); return }
        do { try storage.clear() }
        catch { issue = .recovery; policy.restorationFailed(lease: record.lease); return }
        // Keep a failed clock from falsely reporting that a lease was cleared.
        guard let now = clock() else { issue = .recovery; policy.restorationFailed(lease: record.lease); return }
        policy.confirmAutomatic(at: now, lease: record.lease)
        guard !policy.ownsLease else { issue = .recovery; return }
        self.record = nil; owner = nil; rpm = nil; mayHaveWritten = false
    }

    func disconnected(_ peer: UUID) { if peer == owner { restore(); owner = nil } }
    func sleep() { sleeping = true; restore() }
    func wake() { sleeping = false; if policy.ownsLease { restore() } }
    func prepareTermination() -> Bool {
        inhibited = true; restore()
        return !policy.ownsLease && !corruptRecovery
    }

    private func reply(peer: UUID, overriding: FanControlWire.Issue? = nil) -> FanControlWire.Reply {
        revision &+= 1
        let state = hardware.read()
        let fans = state.fans.count <= 8 && state.fans.allSatisfy(\.valid) ? state.fans : []
        let visibleState: FanControlWire.State
        if corruptRecovery { visibleState = .failed }
        else if policy.ownsLease {
            if policy.phase == .recoveryFailed { visibleState = .failed }
            else if policy.phase == .restoring { visibleState = .restoring }
            else { visibleState = owner == peer ? .active : .external }
        } else if !state.supported || fans.isEmpty { visibleState = .unavailable }
        else { visibleState = state.automatic ? .automatic : .external }
        let remaining = clock().flatMap { policy.remaining(at: $0) }
        return FanControlWire.Reply(serviceID: serviceID, revision: revision, state: visibleState,
            issue: overriding ?? (inhibited ? .maintenance : issue), fans: fans,
            lease: owner == peer ? record?.lease : nil, rpm: owner == peer ? rpm : nil, remaining: remaining)
    }
}
