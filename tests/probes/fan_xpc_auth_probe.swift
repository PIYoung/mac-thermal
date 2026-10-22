import Foundation
import Security
import XPC

@main
enum FanXPCAuthProbe {
    static func main() {
        var code: SecCode?
        precondition(SecCodeCopySelf([], &code) == errSecSuccess)
        var staticCode: SecStaticCode?
        precondition(SecCodeCopyStaticCode(code!, [], &staticCode) == errSecSuccess)
        var info: CFDictionary?
        precondition(SecCodeCopySigningInformation(staticCode!, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess)
        let data = (info! as NSDictionary)[kSecCodeInfoUnique] as! Data
        let hash = data.map { String(format: "%02x", $0) }.joined()
        let right = "cdhash H\"\(hash)\""
        let wrong = "cdhash H\"0000000000000000000000000000000000000000\""
        run(server: right, client: right, expected: true)
        run(server: wrong, client: right, expected: false)
        run(server: right, client: wrong, expected: false)
        let invalid = xpc_connection_create(nil, nil)
        precondition(xpc_connection_set_peer_code_signing_requirement(invalid, "invalid requirement ???") != 0)
        xpc_connection_set_event_handler(invalid) { _ in }
        xpc_connection_resume(invalid); xpc_connection_cancel(invalid)
        print("PASS XPC code-hash checks: matching peers communicate; wrong client/server hash and invalid requirements fail closed. Anonymous unprivileged local endpoints only; no root service or hardware.")
    }
    private static func run(server: String, client: String, expected: Bool) {
        let queue = DispatchQueue(label: "local.mac-thermal.fan-auth-fixture")
        let completed = DispatchSemaphore(value: 0)
        let listener = xpc_connection_create(nil, queue)
        var peers: [xpc_connection_t] = []
        var acceptedReply = false
        xpc_connection_set_event_handler(listener) { event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            let peer = event
            precondition(xpc_connection_set_peer_code_signing_requirement(peer, server) == 0)
            peers.append(peer)
            xpc_connection_set_event_handler(peer) { message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
                      let reply = xpc_dictionary_create_reply(message) else { return }
                xpc_dictionary_set_bool(reply, "ok", true)
                xpc_connection_send_message(peer, reply)
            }
            xpc_connection_resume(peer)
        }
        xpc_connection_resume(listener)
        let endpoint = xpc_endpoint_create(listener)
        let connection = xpc_connection_create_from_endpoint(endpoint)
        xpc_connection_set_target_queue(connection, queue)
        precondition(xpc_connection_set_peer_code_signing_requirement(connection, client) == 0)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(request, "test", true)
        xpc_connection_send_message_with_reply(connection, request, queue) { event in
            acceptedReply = xpc_get_type(event) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(event, "ok")
            completed.signal()
        }
        let result = completed.wait(timeout: .now() + 3)
        queue.sync {
            precondition(acceptedReply == expected)
            if expected { precondition(result == .success) }
            for peer in peers { xpc_connection_set_event_handler(peer) { _ in }; xpc_connection_cancel(peer) }
        }
        xpc_connection_cancel(connection); xpc_connection_cancel(listener)
    }
}
