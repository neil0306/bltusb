// PeerAuth — validate a connecting peer by its AUDIT TOKEN + code-signing
// requirement. This is the macOS-correct caller authentication (SRAA §3, §13.1
// M-03): NOT UID, NOT SO_PEERCRED (Linux-only).
//
// Flow:
//   1. xpc_connection_copy_audit_token(peer)  -> the caller's audit_token_t
//   2. SecCodeCopyGuestWithAttributes([kSecGuestAttributeAudit: token])
//      -> a SecCode for exactly that process (audit token binds to the pid+
//         generation, so it is not pid-reuse spoofable like a bare pid)
//   3. SecCodeCheckValidity(code, requirement) against the pinned designated
//      requirement (Team ID + identifier).
//
// This is defence-in-depth behind xpc_connection_set_peer_code_signing_
// requirement() (which the kernel already enforces pre-delivery).

import Foundation
import Security
import CXPCShim
#if canImport(XPC)
@preconcurrency import XPC
#endif

enum PeerAuth {

    #if canImport(XPC)
    static func isAuthorized(_ peer: xpc_connection_t) -> Bool {
        // 1. Audit token of the peer.
        var token = audit_token_t()
        // Fill the peer's audit_token via the C shim over the xpc SPI.
        cxpc_connection_copy_audit_token(peer, &token)

        // 2. Build a SecCode for exactly that audited process.
        let tokenData = withUnsafeBytes(of: token) { Data($0) } as CFData
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let peerCode = code else {
            return false
        }

        // 3. Check it satisfies the pinned requirement.
        //    In production this is exactly `kPeerCodeSigningRequirement` (the
        //    Team-ID requirement). In a dev build it may be the locally-pinned
        //    dev requirement — but `effectiveRequirement` returns the production
        //    Team-ID string the instant a real Team ID is compiled in, so a
        //    Team-ID build is authenticated against the Team ID only. If we have
        //    no requirement at all, fail closed.
        guard let reqString = XPCServer.effectiveRequirement else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(reqString as CFString, [], &req) == errSecSuccess,
              let requirement = req else {
            return false
        }
        let status = SecCodeCheckValidity(peerCode, [], requirement)
        return status == errSecSuccess
    }
    #endif
}

// MARK: - XPC dictionary decoding helpers

#if canImport(XPC)
enum XPCCodec {
    static func string(_ dict: xpc_object_t, _ key: String) -> String? {
        guard let c = xpc_dictionary_get_string(dict, key) else { return nil }
        return String(cString: c)
    }
    /// Read a raw byte buffer (used for the passphrase, which is delivered as
    /// data, never as a Codable string, so it can be zeroed).
    static func data(_ dict: xpc_object_t, _ key: String) -> [UInt8]? {
        var len = 0
        guard let ptr = xpc_dictionary_get_data(dict, key, &len), len > 0 else { return nil }
        let buf = UnsafeRawBufferPointer(start: ptr, count: len)
        return [UInt8](buf)
    }
}
#endif
