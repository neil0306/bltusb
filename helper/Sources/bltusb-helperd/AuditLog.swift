// AuditLog — Unified Logging (os_log) + an EndpointSecurity mount/unmount client.
//
// SRAA §6/§11 + §13.1 M-02: audit via Unified Logging + EndpointSecurity, NOT
// OpenBSM/auditd (deprecated on current macOS). Metadata only; NEVER the
// passphrase, and device identifiers are logged at .public but raw media bytes
// / labels are never logged.

import Foundation
import os

enum AuditLog {
    static let log = Logger(subsystem: "co.carryai.bltusb.helperd", category: "audit")

    static func mount(deviceID: String, fsType: String, mode: String, mountpoint: String) {
        log.notice("MOUNT dev=\(deviceID, privacy: .public) fs=\(fsType, privacy: .public) mode=\(mode, privacy: .public) mp=\(mountpoint, privacy: .public)")
    }
    static func unmount(mountpoint: String) {
        log.notice("UNMOUNT mp=\(mountpoint, privacy: .public)")
    }
    static func rejected(op: String, reason: String) {
        log.error("REJECT op=\(op, privacy: .public) reason=\(reason, privacy: .public)")
    }
}

// TODO(signing/deploy): a real EndpointSecurity client requires the
// `com.apple.developer.endpoint-security.client` entitlement (approved by
// Apple) + a signed, notarized binary run as root. It subscribes to
// ES_EVENT_TYPE_NOTIFY_MOUNT / ES_EVENT_TYPE_NOTIFY_UNMOUNT and forwards to
// SIEM. It is intentionally NOT wired here (it cannot even es_new_client()
// without the entitlement), so the skeleton compiles CLT-only. The os_log
// path above is the compiling audit sink; ES is the deploy-time addition.
enum EndpointSecurityClient {
    /// Placeholder marking where the ES client is initialised at deploy time.
    static func startIfEntitled() {
        // Real impl: es_new_client { ... } then es_subscribe(client,
        // [ES_EVENT_TYPE_NOTIFY_MOUNT, ES_EVENT_TYPE_NOTIFY_UNMOUNT], 2)
        AuditLog.log.debug("EndpointSecurity client not started (needs entitlement + signing)")
    }
}
