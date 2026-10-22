import Foundation

private final class Events { var values: [String] = [] }
private final class MemoryRecovery: FanRecoveryStore {
    var record: FanRecoveryRecord?
    var failSave = false, failClear = false, corrupt = false
    let events: Events
    init(_ events: Events) { self.events = events }
    func load() throws -> FanRecoveryRecord? { if corrupt { throw CocoaError(.fileReadCorruptFile) }; return record }
    func save(_ record: FanRecoveryRecord) throws {
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        self.record = record; events.values.append("persist")
    }
    func clear() throws {
        if failClear { throw CocoaError(.fileWriteNoPermission) }
        events.values.append("clear"); record = nil
    }
}
private final class SimulatedHardware: FanServiceHardware {
    var state = FanHardwareState(fans: [.init(actual: 1540, minimum: 1000, maximum: 4900)], automatic: true,
        supported: true, cpuTemperature: 75, thermalPressureSafe: true, targets: [1540])
    var failStart = false, failRestore = false, delayStart = false, delayRestore = false
    var starts = 0, restores = 0
    let events: Events
    init(_ events: Events) { self.events = events }
    func read() -> FanHardwareState { state }
    func start(rpm: Int) -> Bool {
        starts += 1; events.values.append("write")
        if !delayStart { state.automatic = false; state.targets = [Double(rpm)] }
        return !failStart
    }
    func restore(count: Int) -> Bool {
        restores += 1; events.values.append("restore")
        if failRestore { return false }
        if !delayRestore { state.automatic = true }
        return state.automatic && count == state.fans.count
    }
}
private final class Fixture {
    let events = Events()
    lazy var hardware = SimulatedHardware(events)
    lazy var storage = MemoryRecovery(events)
    var now: Double? = 100
    lazy var core = FanServiceCore(hardware: hardware, storage: storage, clock: { [weak self] in self?.now })
    let peer = UUID()
    func request(_ op: FanControlWire.Operation, rpm: Int? = nil, lease: UUID? = nil, peer: UUID? = nil) -> FanControlWire.Reply {
        core.handle(.init(operation: op, rpm: rpm, lease: lease), peer: peer ?? self.peer)
    }
    @discardableResult func start() -> FanControlWire.Reply {
        let pending = request(.boost, rpm: 3000)
        precondition(pending.state == .starting && pending.lease != nil)
        now = 101
        let active = request(.heartbeat, lease: pending.lease)
        precondition(active.state == .active)
        return active
    }
    func settle() {
        let start = now!
        for offset in stride(from: 2.0, through: 12.0, by: 2) { now = start + offset; core.tick() }
        precondition(storage.record == nil && hardware.state.automatic)
    }
}

@main
enum FanServiceProbe {
    static func main() {
        let validFan = FanControlWire.Fan(actual: 1540, minimum: 1000, maximum: 4900)
        precondition(FanControlWire.range([validFan]) == 1600...4900)
        precondition(FanControlWire.range([]) == nil)
        for bad in [Double.nan, .infinity, -1, 30101] {
            precondition(FanControlWire.range([.init(actual: bad, minimum: 1000, maximum: 4900)]) == nil)
        }
        let fixture = Fixture()
        precondition(fixture.request(.status).state == .automatic)
        for invalid in [0, 1000, 1500, 1550, 5000, 30001] {
            _ = fixture.request(.boost, rpm: invalid)
            precondition(fixture.hardware.starts == 0 && fixture.storage.record == nil)
        }
        let started = fixture.request(.boost, rpm: 3000)
        precondition(started.valid && started.state == .starting && started.remaining == 600)
        precondition(fixture.events.values.prefix(2).elementsEqual(["persist", "write"]))
        let lease = started.lease!
        fixture.now = 101
        precondition(fixture.request(.heartbeat, lease: lease).state == .active)
        _ = fixture.request(.restore, lease: lease, peer: UUID())
        _ = fixture.request(.heartbeat, lease: lease, peer: UUID())
        precondition(!fixture.hardware.state.automatic)
        for value in stride(from: 102.0, through: 698.0, by: 2) {
            fixture.now = value
            let report = fixture.request(.heartbeat, lease: lease)
            precondition(report.state == .active && report.remaining == 700 - value)
            _ = fixture.request(.boost, rpm: 4000)
            precondition(fixture.hardware.starts == 1)
        }
        fixture.now = 700
        precondition(fixture.request(.heartbeat, lease: lease).state == .restoring)
        precondition(fixture.storage.record != nil, "An immediate automatic read cannot clear recovery")
        fixture.settle()
        precondition(fixture.request(.status).state == .automatic)

        let failedJournal = Fixture(); failedJournal.storage.failSave = true
        _ = failedJournal.request(.boost, rpm: 3000)
        precondition(failedJournal.hardware.starts == 0 && failedJournal.hardware.restores == 0)

        let partialWrite = Fixture(); partialWrite.hardware.failStart = true
        precondition(partialWrite.request(.boost, rpm: 3000).state == .restoring)
        precondition(partialWrite.storage.record != nil)
        partialWrite.settle()

        // Regression for actual hardware: an initial auto read is stale, and the
        // preceding manual write becomes visible after restoration was requested.
        let delayed = Fixture(); delayed.hardware.delayStart = true
        let pending = delayed.request(.boost, rpm: 3000)
        precondition(pending.state == .starting && delayed.storage.record != nil)
        delayed.now = 102
        precondition(delayed.request(.heartbeat, lease: pending.lease).state == .starting)
        _ = delayed.request(.restore, lease: pending.lease)
        precondition(delayed.storage.record != nil && delayed.hardware.restores > 0)
        delayed.hardware.state.automatic = false; delayed.hardware.state.targets = [3000]
        delayed.hardware.delayRestore = true
        delayed.now = 104; delayed.core.tick()
        precondition(delayed.storage.record != nil)
        delayed.now = 106; delayed.hardware.delayRestore = false; delayed.core.tick()
        for value in [108.0, 110, 112, 114] { delayed.now = value; delayed.core.tick() }
        precondition(delayed.storage.record != nil, "Stable interval restarts after late manual visibility")
        delayed.now = 116; delayed.core.tick()
        precondition(delayed.storage.record == nil)

        let startupTimeout = Fixture(); startupTimeout.hardware.delayStart = true
        let wait = startupTimeout.request(.boost, rpm: 3000)
        for value in [102.0, 104, 106, 108] {
            startupTimeout.now = value; _ = startupTimeout.request(.heartbeat, lease: wait.lease)
        }
        precondition(startupTimeout.request(.status).state == .restoring && startupTimeout.storage.record != nil)
        startupTimeout.settle()

        let failedRestore = Fixture(); let active = failedRestore.start()
        failedRestore.hardware.failRestore = true
        _ = failedRestore.request(.restore, lease: active.lease)
        failedRestore.now = 113; failedRestore.core.tick()
        precondition(failedRestore.request(.status).state == .failed)
        precondition(failedRestore.storage.record != nil && !failedRestore.core.prepareTermination())
        failedRestore.hardware.failRestore = false; failedRestore.now = 115; failedRestore.core.tick()
        failedRestore.settle()

        for reason in ["sleep", "disconnect", "heartbeat", "thermal", "missing temperature", "pressure", "maintenance"] {
            let f = Fixture(); _ = f.start()
            switch reason {
            case "sleep": f.core.sleep()
            case "disconnect": f.core.disconnected(f.peer)
            case "heartbeat": f.now = 108; f.core.tick()
            case "thermal": f.hardware.state.cpuTemperature = 100; f.core.tick()
            case "missing temperature": f.hardware.state.cpuTemperature = nil; f.core.tick()
            case "pressure": f.hardware.state.thermalPressureSafe = false; f.core.tick()
            default: f.core.inhibited = true; f.core.tick()
            }
            precondition(f.storage.record != nil, reason + " must retain journal during settlement")
            f.settle()
        }
        let crash = Fixture(); _ = crash.start()
        var restartClock = 105.0
        let restarted = FanServiceCore(hardware: crash.hardware, storage: crash.storage, clock: { restartClock })
        precondition(crash.hardware.state.automatic && crash.storage.record != nil)
        precondition(restarted.handle(.init(operation: .status), peer: UUID()).state == .restoring)
        for value in [107.0, 109, 111, 113, 115] { restartClock = value; restarted.tick() }
        precondition(crash.storage.record == nil)

        let external = Fixture(); external.hardware.state.automatic = false
        precondition(external.request(.boost, rpm: 3000).state == .external)
        precondition(external.hardware.starts == 0 && external.hardware.restores == 0)
        let corrupt = Fixture(); corrupt.storage.corrupt = true
        precondition(corrupt.request(.boost, rpm: 3000).state == .failed && corrupt.hardware.starts == 0)
        print("PASS fan service: async startup confirmation, delayed manual/auto readback regression, ten-second stable recovery with durable journal, bounded startup/600s deadline, ownership, failures, sleep/disconnect/thermal and simulated restart; no live hardware")
    }
}
