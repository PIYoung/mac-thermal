import Foundation
import XPC
import Darwin

final class FanControlClient {
    var onChange: (() -> Void)?
    private(set) var latest = FanControlWire.Reply(serviceID: UUID(), revision: 0, state: .setup, issue: .none, fans: [])
    private var connection: xpc_connection_t?
    private var generation: UInt64 = 0
    private var queuedIntent: FanControlWire.Request?
    private var pendingSince: Double?
    private var lastReplyAt: Double?
    private var lastAttempt: Double?
    private var recoveryUnconfirmed = false
    private var serviceID: UUID?
    private var revision: UInt64 = 0

    var canStart: Bool {
        guard latest.state == .automatic, latest.issue == .none,
              FanControlWire.range(latest.fans) != nil,
              let now = SystemUptime.seconds(), let lastReplyAt else { return false }
        return now >= lastReplyAt && now - lastReplyAt <= FanBoostSession.heartbeatTimeout
    }

    func refresh() {
        guard connection != nil else { connect(); return }
        send(.init(operation: .status))
    }
    func start(rpm: Int) {
        guard canStart, FanControlWire.range(latest.fans)?.contains(rpm) == true else { refresh(); return }
        send(.init(operation: .boost, rpm: rpm))
    }
    func restore() {
        guard let lease = latest.lease else { refresh(); return }
        send(.init(operation: .restore, lease: lease))
    }
    /// Reuses the app's existing 2-second resource tick. No UI or polling timer.
    func tick(visible: Bool) {
        if let pendingSince, let now = SystemUptime.seconds(), now - pendingSince > 4 { disconnect(); return }
        if latest.state == .active, let lease = latest.lease { send(.init(operation: .heartbeat, lease: lease)) }
        else if visible || recoveryUnconfirmed { refresh() }
    }
    func suspend() {
        if latest.lease != nil { restore() }
        disconnect()
    }
    func close() {
        generation &+= 1
        if let connection { xpc_connection_cancel(connection) }
        connection = nil; pendingSince = nil; queuedIntent = nil
    }

    private func connect() {
        #if PANEL_UPDATES_PROBE
        return // Synthetic panel tests must never contact an installed root helper.
        #else
        let now = SystemUptime.seconds() ?? 0
        if let lastAttempt, now - lastAttempt < 5 { return }
        lastAttempt = now
        let path = "/Library/PrivilegedHelperTools/local.mac-thermal.fan-helper"
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0, info.st_nlink == 1, info.st_mode & 0o022 == 0,
              let url = Bundle.main.url(forResource: "FanHelper", withExtension: "cdhash"),
              let hash = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              (hash.count == 40 || hash.count == 64),
              hash.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }) else {
            if latest.state != .setup { publish(state: recoveryUnconfirmed ? .disconnected : .setup) }
            return
        }
        let peer = xpc_connection_create_mach_service(FanControlWire.service, .main, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        guard xpc_connection_set_peer_code_signing_requirement(peer, "cdhash H\"\(hash)\"") == 0 else {
            publish(state: .disconnected); return
        }
        generation &+= 1; let token = generation
        connection = peer
        xpc_connection_set_event_handler(peer) { [weak self] _ in
            guard let self, token == self.generation else { return }
            self.disconnect()
        }
        xpc_connection_resume(peer)
        publish(state: .connecting)
        send(.init(operation: .status))
        #endif
    }
    private func send(_ request: FanControlWire.Request) {
        if pendingSince != nil {
            if request.operation == .restore || (request.operation == .boost && queuedIntent?.operation != .restore) { queuedIntent = request }
            return
        }
        guard let peer = connection, let now = SystemUptime.seconds(),
              request.valid, let encoded = try? JSONEncoder().encode(request) else { return }
        let message = xpc_dictionary_create(nil, nil, 0)
        encoded.withUnsafeBytes { buffer in xpc_dictionary_set_data(message, "payload", buffer.baseAddress!, buffer.count) }
        pendingSince = now; let token = generation
        xpc_connection_send_message_with_reply(peer, message, .main) { [weak self] event in
            guard let self, token == self.generation else { return }
            self.pendingSince = nil
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY, xpc_connection_get_euid(peer) == 0 else { self.disconnect(); return }
            var length = 0
            guard let bytes = xpc_dictionary_get_data(event, "payload", &length), length > 0, length <= FanControlWire.maxPayload,
                  let reply = try? JSONDecoder().decode(FanControlWire.Reply.self, from: Data(bytes: bytes, count: length)), reply.valid else { self.disconnect(); return }
            if self.serviceID == reply.serviceID, reply.revision <= self.revision { return }
            self.serviceID = reply.serviceID; self.revision = reply.revision
            self.latest = reply; self.lastReplyAt = SystemUptime.seconds()
            self.recoveryUnconfirmed = [.active, .restoring, .failed].contains(reply.state)
            self.onChange?()
            if let intent = self.queuedIntent {
                self.queuedIntent = nil
                self.send(intent)
            }
        }
    }
    private func disconnect() {
        recoveryUnconfirmed = recoveryUnconfirmed || [.active, .restoring, .failed].contains(latest.state)
        close(); publish(state: .disconnected)
    }
    private func publish(state: FanControlWire.State) {
        latest = .init(serviceID: serviceID ?? UUID(), revision: revision, state: state, issue: state == .disconnected ? .connection : .none, fans: [])
        onChange?()
    }
}
