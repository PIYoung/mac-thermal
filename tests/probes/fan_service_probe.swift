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
    var failStart = false, failRestore = false
    var starts = 0, restores = 0
    let events: Events
    init(_ events: Events) { self.events = events }
    func read() -> FanHardwareState { state }
    func start(rpm: Int) -> Bool {
        starts += 1; events.values.append("write")
        state.automatic = false; state.targets = [Double(rpm)]
        return !failStart
    }
    func restore(count: Int) -> Bool {
        restores += 1; events.values.append("restore")
        if failRestore { return false }
        state.automatic = true; return count == state.fans.count
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
        precondition(started.valid && started.state == .active && started.rpm == 3000 && started.remaining == 600)
        precondition(fixture.events.values.prefix(2).elementsEqual(["persist", "write"]))
        let lease = started.lease!
        _ = fixture.request(.restore, lease: lease, peer: UUID())
        _ = fixture.request(.heartbeat, lease: lease, peer: UUID())
        precondition(!fixture.hardware.state.automatic, "Other connections cannot control an owned lease")
        for value in stride(from: 102.0, through: 698.0, by: 2) {
            fixture.now = value
            let report = fixture.request(.heartbeat, lease: lease)
            precondition(report.state == .active && report.remaining == 700 - value)
            _ = fixture.request(.boost, rpm: 4000)
            precondition(fixture.hardware.starts == 1)
        }
        fixture.now = 700
        precondition(fixture.request(.heartbeat, lease: lease).state == .automatic)
        precondition(fixture.storage.record == nil && fixture.hardware.restores == 1)
        precondition(fixture.events.values.suffix(2).elementsEqual(["restore", "clear"]))

        let failedJournal = Fixture(); failedJournal.storage.failSave = true
        _ = failedJournal.request(.boost, rpm: 3000)
        precondition(failedJournal.hardware.starts == 0 && failedJournal.hardware.restores == 0)

        let partialWrite = Fixture(); partialWrite.hardware.failStart = true
        _ = partialWrite.request(.boost, rpm: 3000)
        precondition(partialWrite.hardware.state.automatic && partialWrite.storage.record == nil)

        let failedRestore = Fixture()
        let active = failedRestore.request(.boost, rpm: 3000)
        failedRestore.hardware.failRestore = true
        precondition(failedRestore.request(.restore, lease: active.lease).state == .failed)
        precondition(failedRestore.storage.record != nil && !failedRestore.core.prepareTermination())
        failedRestore.hardware.failRestore = false; failedRestore.core.tick()
        precondition(failedRestore.storage.record == nil && failedRestore.hardware.state.automatic)

        for reason in ["sleep", "disconnect", "heartbeat", "thermal", "missing temperature", "pressure", "maintenance"] {
            let f = Fixture(); _ = f.request(.boost, rpm: 3000)
            switch reason {
            case "sleep": f.core.sleep()
            case "disconnect": f.core.disconnected(f.peer)
            case "heartbeat": f.now = 107; f.core.tick()
            case "thermal": f.hardware.state.cpuTemperature = 100; f.core.tick()
            case "missing temperature": f.hardware.state.cpuTemperature = nil; f.core.tick()
            case "pressure": f.hardware.state.thermalPressureSafe = false; f.core.tick()
            default: f.core.inhibited = true; f.core.tick()
            }
            precondition(f.hardware.state.automatic && f.storage.record == nil, reason)
        }
        let crash = Fixture(); _ = crash.request(.boost, rpm: 3000)
        let restarted = FanServiceCore(hardware: crash.hardware, storage: crash.storage, clock: { 105 })
        precondition(crash.hardware.state.automatic && crash.storage.record == nil)
        precondition(restarted.handle(.init(operation: .status), peer: UUID()).state == .automatic)

        let external = Fixture(); external.hardware.state.automatic = false
        precondition(external.request(.boost, rpm: 3000).state == .external)
        precondition(external.hardware.starts == 0 && external.hardware.restores == 0)
        let corrupt = Fixture(); corrupt.storage.corrupt = true
        precondition(corrupt.request(.boost, rpm: 3000).state == .failed && corrupt.hardware.starts == 0)
        print("PASS fan service: journal-before-write, custom RPM bounds, exact 600s lease, ownership, partial write/recovery failure, sleep/disconnect/heartbeat/thermal/maintenance, simulated restart; no hardware or root service execution")
    }
}
