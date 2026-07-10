// HelperClient — the unprivileged client's view of the helper.
//
// This is what the bltusb CLI / the per-user insert-trigger agent link against.
// It connects to the root daemon's Mach service, sends ONE of the 4 validated
// requests, and returns a typed reply. It performs client-side validation too
// (so bad input never leaves the process) — but the SERVER is authoritative;
// the client's checks are a courtesy, never the security boundary.

import Foundation
import BltusbProtocol
#if canImport(XPC)
@preconcurrency import XPC
#endif

public let kHelperMachServiceName = "co.carryai.bltusb.helperd"

public enum ClientError: Error {
    case connectionFailed
    case helper(HelperError)
    case malformedReply
    case xpcUnavailable
}

public final class HelperClient: @unchecked Sendable {

    #if canImport(XPC)
    private let conn: xpc_connection_t

    public init() {
        conn = xpc_connection_create_mach_service(kHelperMachServiceName, nil, 0)
        // The client pins the DAEMON's code-signing requirement too, so it will
        // not talk to an impostor Mach service. TODO(signing/deploy): set the
        // real Team ID; symmetrical to the server-side requirement.
        // xpc_connection_set_peer_code_signing_requirement(conn, kDaemonRequirement)
        xpc_connection_set_event_handler(conn) { _ in }
        xpc_connection_resume(conn)
    }

    // MARK: list-external

    public func listExternal() throws -> [ExternalPartition] {
        let req = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(req, "op", HelperOp.listExternal.rawValue)
        let reply = xpc_connection_send_message_with_reply_sync(conn, req)
        if let e = Self.errorField(reply) { throw ClientError.helper(e) }
        guard let arr = xpc_dictionary_get_array(reply, "partitions") else {
            throw ClientError.malformedReply
        }
        var out: [ExternalPartition] = []
        xpc_array_apply(arr) { _, item in
            if let id = xpc_dictionary_get_string(item, "device_id"),
               let sz = xpc_dictionary_get_string(item, "size"),
               let ty = xpc_dictionary_get_string(item, "type") {
                out.append(ExternalPartition(deviceID: String(cString: id),
                                             sizeText: String(cString: sz),
                                             typeText: String(cString: ty)))
            }
            return true
        }
        return out
    }

    // MARK: probe-external

    public func probe(deviceID: String) throws -> ProbeResult {
        guard Validators.isValidDeviceID(deviceID) else { throw ClientError.helper(.invalidDeviceID) }
        let req = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(req, "op", HelperOp.probeExternal.rawValue)
        xpc_dictionary_set_string(req, "device_id", deviceID)
        let reply = xpc_connection_send_message_with_reply_sync(conn, req)
        if let e = Self.errorField(reply) { throw ClientError.helper(e) }
        guard let idC = xpc_dictionary_get_string(reply, "device_id") else { throw ClientError.malformedReply }
        let fsRaw = xpc_dictionary_get_string(reply, "fs_type").map { String(cString: $0) } ?? ""
        let label = xpc_dictionary_get_string(reply, "label").map { String(cString: $0) }
        let locked = xpc_dictionary_get_bool(reply, "locked")
        return ProbeResult(deviceID: String(cString: idC),
                           fsType: FSType(rawValue: fsRaw),
                           label: (label?.isEmpty ?? true) ? nil : label,
                           locked: locked)
    }

    // MARK: mount-external

    /// `passphrase` is the raw secret bytes; the client hands it straight to XPC
    /// as `data` (never a Codable string) and zeroes its own copy after send.
    public func mount(deviceID: String, fsType: FSType, mountpoint: String,
                      mode: MountMode = .ro, passphrase: inout [UInt8]) throws -> String {
        guard Validators.isValidDeviceID(deviceID) else { throw ClientError.helper(.invalidDeviceID) }
        guard Validators.isValidMountpoint(mountpoint) else { throw ClientError.helper(.invalidMountpoint) }
        let req = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(req, "op", HelperOp.mountExternal.rawValue)
        xpc_dictionary_set_string(req, "device_id", deviceID)
        xpc_dictionary_set_string(req, "fs_type", fsType.rawValue)
        xpc_dictionary_set_string(req, "mountpoint", mountpoint)
        xpc_dictionary_set_string(req, "mode", mode.rawValue)
        if !passphrase.isEmpty {
            passphrase.withUnsafeBytes { xpc_dictionary_set_data(req, "passphrase", $0.baseAddress, $0.count) }
        }
        let reply = xpc_connection_send_message_with_reply_sync(conn, req)
        // Zero our copy of the secret immediately after the message is sent.
        for i in passphrase.indices { passphrase[i] = 0 }
        passphrase.removeAll(keepingCapacity: false)

        if let e = Self.errorField(reply) { throw ClientError.helper(e) }
        guard let mp = xpc_dictionary_get_string(reply, "mountpoint") else { throw ClientError.malformedReply }
        return String(cString: mp)
    }

    // MARK: unmount-external

    public func unmount(mountpoint: String) throws {
        guard Validators.isValidMountpoint(mountpoint) else { throw ClientError.helper(.invalidMountpoint) }
        let req = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(req, "op", HelperOp.unmountExternal.rawValue)
        xpc_dictionary_set_string(req, "mountpoint", mountpoint)
        let reply = xpc_connection_send_message_with_reply_sync(conn, req)
        if let e = Self.errorField(reply) { throw ClientError.helper(e) }
    }

    private static func errorField(_ reply: xpc_object_t) -> HelperError? {
        if xpc_get_type(reply) == XPC_TYPE_ERROR {
            // A connection-level error means the peer code-signing requirement
            // rejected us pre-delivery (kernel-enforced layer 1: the daemon's
            // xpc_connection_set_peer_code_signing_requirement refused this
            // client's signature), so the connection was torn down before any
            // reply. Surface that as notAuthorized rather than a backend fault —
            // it is the caller-authentication boundary firing.
            if xpc_equal(reply, XPC_ERROR_CONNECTION_INVALID) ||
               xpc_equal(reply, XPC_ERROR_CONNECTION_INTERRUPTED) {
                return .notAuthorized
            }
            return .backendFailure
        }
        guard let c = xpc_dictionary_get_string(reply, "error") else { return nil }
        return HelperError(rawValue: String(cString: c)) ?? .internalError
    }
    #else
    public init() throws { throw ClientError.xpcUnavailable }
    #endif
}
