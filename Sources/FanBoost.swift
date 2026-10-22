import Foundation

/// Safety policy for the proposed privileged service. This type performs no I/O.
/// A future service must enforce this policy independently of the UI process.
/// No permission is inferred from RPM. Installation and hardware tests require
/// their own explicit review.
struct FanBoostSession {
    enum Phase: Equatable {
        case unconfigured, automatic, externalControl
        case starting, boosting, restoring, recoveryFailed
    }
    enum Command: Equatable {
        case beginCooling(UUID)
        case restoreAppleAutomatic(UUID)
    }
    static let maximumDuration: TimeInterval = 600
    static let heartbeatTimeout: TimeInterval = 6
    private(set) var phase: Phase = .unconfigured
    private(set) var leaseID: UUID?
    private(set) var deadline: TimeInterval?
    private var lastHeartbeat: TimeInterval?
    private var lastTime: TimeInterval?
    private var startDeadline: TimeInterval?
    private var automaticConfirmedAt: TimeInterval?

    var ownsLease: Bool { leaseID != nil }

    mutating func recoverOwnedLease(_ id: UUID) {
        phase = .restoring; leaseID = id; deadline = nil
        lastHeartbeat = nil; startDeadline = nil; automaticConfirmedAt = nil
    }

    /// Call only after an authenticated service reports all fans in automatic
    /// mode and valid hardware limits. Unknown or partial data cannot enable it.
    mutating func confirmAutomatic(at now: TimeInterval, lease id: UUID? = nil) {
        guard valid(now), (leaseID == nil ? id == nil : id == leaseID) else { return }
        phase = .automatic; leaseID = nil; deadline = nil
        lastHeartbeat = nil; startDeadline = nil
        automaticConfirmedAt = now; lastTime = now
    }

    mutating func reportExternalControl(at now: TimeInterval) {
        guard valid(now), !ownsLease else { return }
        phase = .externalControl; automaticConfirmedAt = nil; lastTime = now
    }

    func canStart(at now: TimeInterval) -> Bool {
        guard phase == .automatic, !ownsLease, valid(now), let confirmed = automaticConfirmedAt else { return false }
        return now >= confirmed && now - confirmed <= Self.heartbeatTimeout
    }

    /// Hardware validates the separately selected RPM. Repeated requests cannot
    /// extend the lease. The deadline starts before the first hardware write.
    mutating func start(at now: TimeInterval) -> Command? {
        guard canStart(at: now) else { return nil }
        let id = UUID()
        leaseID = id; deadline = now + Self.maximumDuration
        startDeadline = now + 8; lastHeartbeat = now; lastTime = now
        phase = .starting; automaticConfirmedAt = nil
        return .beginCooling(id)
    }

    /// Only a matching lease may acknowledge startup. Late replies cannot
    /// resurrect a cancelled lease or extend its original deadline.
    mutating func confirmBoost(lease id: UUID, at now: TimeInterval) -> Command? {
        guard leaseID == id else { return nil }
        guard valid(now), let deadline, now < deadline,
              let startDeadline, now < startDeadline, phase == .starting else { return restore() }
        phase = .boosting; lastTime = now
        return nil
    }

    mutating func heartbeat(lease id: UUID, at now: TimeInterval) -> Command? {
        guard leaseID == id, phase == .starting || phase == .boosting else { return nil }
        // A late heartbeat cannot hide a gap or postpone the hard deadline.
        if let command = tick(at: now) { return command }
        lastHeartbeat = now
        return nil
    }

    mutating func tick(at now: TimeInterval) -> Command? {
        guard ownsLease else { return nil }
        guard valid(now), let deadline, now < deadline,
              let lastHeartbeat, now - lastHeartbeat <= Self.heartbeatTimeout,
              phase != .starting || (startDeadline.map { now < $0 } ?? false) else { return restore() }
        lastTime = now
        return nil
    }

    /// Use for cancel, sleep, app disconnect/exit or a hardware error. Calling
    /// this on an unowned session never changes another app's fan controls.
    mutating func restore() -> Command? {
        guard let leaseID else { return nil }
        phase = .restoring
        return .restoreAppleAutomatic(leaseID)
    }

    mutating func restorationFailed(lease id: UUID) {
        guard leaseID == id else { return }
        phase = .recoveryFailed // Keep ownership until readback confirms auto.
    }

    func remaining(at now: TimeInterval) -> TimeInterval? {
        guard phase == .starting || phase == .boosting, valid(now), let deadline else { return nil }
        return min(Self.maximumDuration, max(0, deadline - now))
    }

    private func valid(_ now: TimeInterval) -> Bool {
        now.isFinite && now >= 0 && (lastTime.map { now >= $0 } ?? true)
    }
}
