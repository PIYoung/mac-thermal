import Foundation

@main
enum FanBoostProbe {
    static func main() {
        var session = FanBoostSession()
        precondition(session.start(at: 100) == nil && session.restore() == nil)
        precondition(session.phase == .unconfigured && !session.ownsLease)
        session.reportExternalControl(at: 100)
        precondition(session.start(at: 101) == nil && session.restore() == nil)
        session.confirmAutomatic(at: 110)
        precondition(session.start(at: 117) == nil, "Stale automatic evidence must not enable a boost")
        session.confirmAutomatic(at: 120)
        guard case .boostToHardwareMaximum(let id) = session.start(at: 120) else { fatalError("Expected one lease") }
        precondition(session.start(at: 121) == nil && session.deadline == 720)
        precondition(session.confirmBoost(lease: UUID(), at: 121) == nil && session.phase == .starting)
        precondition(session.confirmBoost(lease: id, at: 121) == nil && session.phase == .boosting)
        for time in stride(from: 122.0, through: 718.0, by: 2) {
            precondition(session.heartbeat(lease: id, at: time) == nil)
            precondition(session.start(at: time) == nil)
            precondition(session.deadline == 720, "Heartbeats and repeat clicks cannot renew the lease")
        }
        precondition(session.remaining(at: 718) == 2)
        precondition(session.heartbeat(lease: id, at: 720) == .restoreAppleAutomatic(id))
        precondition(session.phase == .restoring && session.ownsLease && session.remaining(at: 720) == nil)
        session.restorationFailed(lease: id)
        precondition(session.phase == .recoveryFailed && session.ownsLease)
        session.confirmAutomatic(at: 721, lease: UUID())
        precondition(session.phase == .recoveryFailed, "Wrong acknowledgements cannot report recovery")
        precondition(session.confirmBoost(lease: id, at: 721) == .restoreAppleAutomatic(id))
        session.confirmAutomatic(at: 722, lease: id)
        precondition(session.phase == .automatic && !session.ownsLease)

        for reason in ["cancel", "sleep", "app exit", "connection loss", "hardware error"] {
            var fixture = FanBoostSession()
            fixture.confirmAutomatic(at: 10)
            guard case .boostToHardwareMaximum(let lease) = fixture.start(at: 10) else { fatalError(reason) }
            precondition(fixture.restore() == .restoreAppleAutomatic(lease), reason)
            precondition(fixture.confirmBoost(lease: lease, at: 11) == .restoreAppleAutomatic(lease), "Late startup after \(reason)")
            precondition(fixture.phase == .restoring && fixture.start(at: 12) == nil)
        }
        for invalidTime in [Double.nan, .infinity, -1, 9, 16.01] {
            var fixture = FanBoostSession()
            fixture.confirmAutomatic(at: 10)
            guard case .boostToHardwareMaximum(let lease) = fixture.start(at: 10) else { fatalError() }
            precondition(fixture.heartbeat(lease: lease, at: invalidTime) == .restoreAppleAutomatic(lease), "Invalid clock or expired heartbeat must restore")
        }
        var pending = FanBoostSession()
        pending.confirmAutomatic(at: 10)
        guard case .boostToHardwareMaximum(let pendingID) = pending.start(at: 10) else { fatalError() }
        precondition(pending.heartbeat(lease: pendingID, at: 16) == nil)
        precondition(pending.confirmBoost(lease: pendingID, at: 18) == .restoreAppleAutomatic(pendingID), "Startup timeout")
        print("PASS fan boost policy (synthetic): fixed 600s lease, fresh auto evidence, external-owner refusal, heartbeat/start timeout, cancel/sleep/disconnect intents, stale replies, confirmed recovery. No hardware writes or crash-recovery proof.")
    }
}
