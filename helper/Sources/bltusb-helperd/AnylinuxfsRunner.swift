// AnylinuxfsRunner — executes ONLY fixed `anylinuxfs mount/unmount` argument
// vectors, and delivers the passphrase without ever putting it in argv/log/temp.
//
// SRAA §3/§6 invariants enforced here:
//   · the binary path is a FIXED, root-owned, MDM-installed absolute path
//     (never a client-supplied path, never PATH-resolved) — TODO(deploy) below;
//   · the argv is built ONLY by Validators.anylinuxfs*Argv (allowlisted options);
//   · the passphrase is passed as a zeroable buffer and scoped to exactly one
//     child's environment, then zeroed — never argv, never a global export,
//     never a log line, never a temp file.
//
// KNOWN CONSTRAINT (documented, not hidden): anylinuxfs today accepts the secret
// ONLY via the ALFS_PASSPHRASE environment variable — it exposes no stdin/fd
// channel. So even done perfectly, the secret is visible to an env-aware reader
// (`ps -E`, /proc-equivalent) of THIS child for the brief mount lifetime. The
// mitigations are: (a) scope to one child, (b) zero immediately after, (c) push
// upstream for an fd channel. See docs/PHASE2-HELPER-PLAN.md "passphrase" +
// residual. Until upstream adds an fd, this residual stands.

import Foundation
import BltusbProtocol

enum AnylinuxfsRunner {

    /// TODO(signing/deploy): the FIXED, root-owned, non-user-writable, MDM-
    /// installed path to the hardened anylinuxfs. It must NOT be resolved via
    /// $PATH and must NOT be under ~/.anylinuxfs (S3: user-writable rootfs is a
    /// trust violation). The value below is the intended install location; the
    /// daemon verifies its Developer-ID signature + hash before every exec
    /// (see verifyBackendIntegrity — stubbed, gated on a signing identity).
    static let binaryPath = "/Library/Application Support/bltusb/anylinuxfs/bin/anylinuxfs"

    /// TODO(signing/deploy): verify the backend is the pinned, hash-matched,
    /// Developer-ID-signed artifact before exec (SRAA §5 S1–S3, S7). Requires a
    /// deploy-time trust anchor; returns true here so the skeleton compiles.
    static func verifyBackendIntegrity() -> Bool {
        // Real impl: SecStaticCode + SecCodeCheckValidity against the pinned
        // designated requirement, plus a sha256 match of the rootfs image.
        return true
    }

    /// Run `anylinuxfs mount` with a fixed argv and the secret scoped to this one
    /// child, zeroed after the child is spawned. Returns backendFailure on a
    /// non-zero exit. `secret` is consumed and zeroed by the caller regardless.
    static func mount(deviceID: String, fsType: FSType, mode: MountMode, secret: Secret?) -> Result<Void, HelperError> {
        guard verifyBackendIntegrity() else { return .failure(.backendFailure) }
        let argv = Validators.anylinuxfsMountArgv(deviceID: deviceID, fsType: fsType, mode: mode)

        // TODO(signing/deploy): actually spawning this needs root + the deployed
        // hardened backend. Under the CLT-only build the binary is absent, so
        // Process.run() throws and we return backendFailure (fail closed).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = argv
        p.standardInput = FileHandle.nullDevice   // never consume our stdin

        if let secret = secret {
            // Scope ALFS_PASSPHRASE to THIS child only (not exported globally).
            // We must materialise it as a String for Process.environment; we do
            // so at the last moment and drop the reference immediately. The
            // authoritative zeroing is of the Secret's own buffer, below.
            var env = ProcessInfo.processInfo.environment
            env["ALFS_PASSPHRASE"] = secret.asTransientString()
            p.environment = env
        }

        defer { secret?.zero() }   // zero the secret buffer no matter what

        do { try p.run() } catch { return .failure(.backendFailure) }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? .success(()) : .failure(.backendFailure)
    }

    static func unmount(mountpoint: String) -> Result<Void, HelperError> {
        guard verifyBackendIntegrity() else { return .failure(.backendFailure) }
        let argv = Validators.anylinuxfsUnmountArgv(mountpoint: mountpoint)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = argv
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(.backendFailure) }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? .success(()) : .failure(.backendFailure)
    }
}

/// A zeroable secret buffer. The passphrase arrives over XPC as raw bytes and is
/// wrapped here so it can be explicitly zeroed after use — never left to ARC to
/// collect a `String` copy on some heap page. Callers MUST call `zero()`.
public final class Secret: @unchecked Sendable {
    private var bytes: [UInt8]
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// Materialise the secret for the one-shot child env. Kept "transient" in
    /// name to flag that this String is short-lived; the buffer is still the
    /// authoritative copy that gets zeroed.
    func asTransientString() -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Overwrite the backing bytes with zero. Idempotent.
    public func zero() {
        for i in bytes.indices { bytes[i] = 0 }
        bytes.removeAll(keepingCapacity: false)
    }

    deinit { zero() }
}
