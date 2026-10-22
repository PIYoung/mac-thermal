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
    private var submittedAt: Double?
    private var restoringSince: Double?
    private var automaticSince: Double?
    private var lastRestoreWrite: Double?
    private var automaticSamples = 0
    private var lastAutomaticObservation: Double?
    static let automaticSettlement: Double = 10
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
        submittedAt = now
        guard hardware.start(rpm: selected) else { issue = .unsupported; restore(); return }
        issue = .none // Acknowledges queued writes, not verified cooling.
    }

    func tick() {
        guard policy.ownsLease else { return }
        if inhibited || sleeping { restore(); return }
        if policy.phase == .restoring || policy.phase == .recoveryFailed { restore(); return }
        guard let now = clock() else { issue = .unavailable; restore(); return }
        if policy.tick(at: now) != nil { restore(); return }
        let state = hardware.read()
        guard state.safeToCool, state.fans.count == record?.fanCount else {
            issue = .thermal; restore(); return
        }
        let matching = !state.automatic && state.targets.count == state.fans.count &&
            rpm.map { target in state.targets.allSatisfy { $0.isFinite && abs($0 - Double(target)) <= 1 } } == true
        if policy.phase == .starting {
            // A same-call read can still show the mode from before a queued write.
            if matching, let submittedAt, now > submittedAt, let lease = record?.lease {
                if policy.confirmBoost(lease: lease, at: now) != nil { restore() }
            }
            return // The policy enforces the independent eight-second deadline.
        }
        if !matching { issue = .thermal; restore() }
    }

    private func restore() {
        guard let record else { return }
        _ = policy.restore()
        guard let now = clock() else {
            // Best effort restoration still runs when the clock is unavailable.
            if mayHaveWritten { _ = hardware.restore(count: record.fanCount) }
            issue = .recovery; policy.restorationFailed(lease: record.lease); return
        }
        if restoringSince == nil { restoringSince = now }
        if mayHaveWritten, lastRestoreWrite == nil || now - lastRestoreWrite! >= 2 {
            // Always enqueue automatic, including when the initial read says auto:
            // an earlier mode write may not have appeared yet.
            let restored = hardware.restore(count: record.fanCount)
            lastRestoreWrite = now
            if !restored { automaticSince = nil; automaticSamples = 0; lastAutomaticObservation = nil }
        }
        let state = hardware.read()
        guard state.supported, state.automatic, state.fans.count == record.fanCount else {
            automaticSince = nil; automaticSamples = 0; lastAutomaticObservation = nil
            if now - (restoringSince ?? now) >= Self.automaticSettlement {
                issue = .recovery; policy.restorationFailed(lease: record.lease)
            }
            return
        }
        if automaticSince == nil {
            automaticSince = now; automaticSamples = 1; lastAutomaticObservation = now
        } else if let lastAutomaticObservation, now - lastAutomaticObservation >= 1 {
            automaticSamples += 1; self.lastAutomaticObservation = now
        }
        // Retain the durable journal across delayed write/read visibility and
        // repeat observations on independent ticks before reporting success.
        guard !mayHaveWritten || (automaticSamples >= 6 && now - automaticSince! >= Self.automaticSettlement &&
              now - restoringSince! >= Self.automaticSettlement) else { return }
        do { try storage.clear() }
        catch { issue = .recovery; policy.restorationFailed(lease: record.lease); return }
        policy.confirmAutomatic(at: now, lease: record.lease)
        guard !policy.ownsLease else { issue = .recovery; return }
        self.record = nil; owner = nil; rpm = nil; mayHaveWritten = false
        submittedAt = nil; restoringSince = nil; automaticSince = nil; lastRestoreWrite = nil
        automaticSamples = 0; lastAutomaticObservation = nil
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
            else if owner != peer { visibleState = .external }
            else { visibleState = policy.phase == .starting ? .starting : .active }
        } else if !state.supported || fans.isEmpty { visibleState = .unavailable }
        else { visibleState = state.automatic ? .automatic : .external }
        let remaining = clock().flatMap { policy.remaining(at: $0) }
        return FanControlWire.Reply(serviceID: serviceID, revision: revision, state: visibleState,
            issue: overriding ?? (inhibited ? .maintenance : issue), fans: fans,
            lease: owner == peer ? record?.lease : nil, rpm: owner == peer ? rpm : nil, remaining: remaining)
    }
}
