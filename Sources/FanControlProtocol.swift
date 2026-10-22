import Foundation

enum FanControlWire {
    static let service = "local.mac-thermal.fan-helper"
    static let version = 1
    static let maxPayload = 8_192
    enum Operation: String, Codable { case status, boost, heartbeat, restore }
    enum State: String, Codable { case setup, connecting, automatic, external, starting, active, restoring, failed, unavailable, disconnected }
    enum Issue: String, Codable {
        case none, unsupported, busy, invalidRPM, thermal, unavailable, restoring, recovery, maintenance, protocolError, connection
    }
    struct Request: Codable {
        var version = FanControlWire.version
        let operation: Operation
        var rpm: Int? = nil
        var lease: UUID? = nil
        var valid: Bool {
            guard version == FanControlWire.version else { return false }
            switch operation {
            case .status: return rpm == nil && lease == nil
            case .boost: return rpm.map { (100...30_000).contains($0) && $0 % 100 == 0 } == true && lease == nil
            case .heartbeat, .restore: return rpm == nil && lease != nil
            }
        }
    }
    struct Fan: Codable, Equatable {
        let actual: Double
        let minimum: Double
        let maximum: Double
        var valid: Bool {
            actual.isFinite && minimum.isFinite && maximum.isFinite &&
            (0...30_000).contains(actual) && minimum >= 100 && maximum <= 30_000 && minimum < maximum && actual <= maximum + 100
        }
    }
    struct Reply: Codable {
        var version = FanControlWire.version
        let serviceID: UUID
        let revision: UInt64
        let state: State
        let issue: Issue
        let fans: [Fan]
        var lease: UUID? = nil
        var rpm: Int? = nil
        var remaining: Double? = nil
        var valid: Bool {
            version == FanControlWire.version && fans.count <= 8 && fans.allSatisfy(\.valid) &&
            (rpm.map { (100...30_000).contains($0) } ?? true) &&
            (remaining.map { $0.isFinite && (0...600).contains($0) } ?? true) &&
            (![State.active, .starting].contains(state) || (lease != nil && rpm != nil && remaining != nil && !fans.isEmpty))
        }
    }
    static func range(_ fans: [Fan]) -> ClosedRange<Int>? {
        guard !fans.isEmpty, fans.count <= 8, fans.allSatisfy(\.valid) else { return nil }
        let floor = Int(ceil(fans.map { max($0.minimum, $0.actual) }.max()! / 100)) * 100
        let ceiling = Int(floorValue(fans.map(\.maximum).min()! / 100)) * 100
        guard floor <= ceiling else { return nil }
        return floor...ceiling
    }
    private static func floorValue(_ value: Double) -> Double { floor(value) }
}
