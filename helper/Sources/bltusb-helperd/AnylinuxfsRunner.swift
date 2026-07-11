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

    /// The FIXED absolute path to the anylinuxfs backend. NEVER $PATH-resolved,
    /// NEVER client-supplied, NEVER under ~/.anylinuxfs.
    ///
    /// Two builds, one invariant (fixed absolute path):
    ///
    ///   · Mode A (production, default): the hardened, root-owned, non-user-
    ///     writable, MDM-installed backend. `verifiedBackendPath` verifies its
    ///     Developer-ID signature + rootfs hash before every exec (S1–S3, S7).
    ///
    ///   · Mode B (`-D BLTUSB_SELFHOSTED`, personal self-hosted): the user-
    ///     installed Homebrew backend at a FIXED absolute path
    ///     `/opt/homebrew/bin/anylinuxfs`. This is the *user-installed* backend,
    ///     NOT the hardened MDM one — its residuals (ad-hoc signed, user-writable
    ///     ~/.anylinuxfs rootfs: R-supply / S3) are accepted for a personal
    ///     machine and documented in AUTO-UNLOCK-RISK.md §4 and DEPLOY-MODES.md.
    ///     It is still resolved from a FIXED constant (not $PATH), the argv is
    ///     still Validators-allowlisted, and the passphrase is still scoped +
    ///     zeroed. Mode A is byte-for-byte unaffected by this branch.
    #if BLTUSB_SELFHOSTED
    static let binaryPath = "/opt/homebrew/bin/anylinuxfs"
    #else
    static let binaryPath = "/Library/Application Support/bltusb/anylinuxfs/bin/anylinuxfs"
    #endif

    /// Verify the backend is the artifact we expect before exec.
    ///
    /// Mode A (default): TODO(signing/deploy) — SecStaticCode + SecCodeCheckValidity
    /// against the pinned Developer-ID designated requirement, plus a sha256 match
    /// of the rootfs image (SRAA §5 S1–S3, S7). Stubbed true so the skeleton
    /// compiles until a deploy-time trust anchor exists.
    ///
    /// Mode B (self-hosted): the daemon runs as ROOT and EXECUTES this backend, so
    /// if any non-root user can replace it — or reach it through a user-writable
    /// parent directory or symlink — that is a local ROOT ESCALATION (the same
    /// primitive as the removed --nopasswd path: unprivileged user controls
    /// executable bytes -> authenticated op -> runs as root). Therefore we require
    /// the resolved backend AND every ancestor directory to be owned by uid 0 and
    /// not group/other-writable. FAIL CLOSED otherwise.
    ///
    /// A stock Homebrew backend is user-owned (Cellar) and its rootfs
    /// (~/.anylinuxfs) is user-writable, so this check FAILS and Mode B `mount`
    /// does not run until the FULL backend trust chain (binary + rootfs + deps) is
    /// staged root-owned and verified — the Phase-2 supply-chain work (SRAA §5
    /// S1–S3; DEPLOY-MODES.md). Metadata ops (list/probe) never exec the backend,
    /// so they are unaffected. NOTE: a fully TOCTOU-safe design must exec the
    /// verified root-owned file by descriptor; that hardening is Phase-2.
    /// Returns the CANONICAL, verified path the caller must exec — or nil if the
    /// backend fails integrity (fail closed). The caller MUST exec exactly this
    /// returned path, NOT `binaryPath`: `binaryPath` may be a user-controlled
    /// symlink, and execing it would let a user point it at a root-owned file
    /// during verification, then re-point it at attacker code before exec (TOCTOU).
    /// We resolve the symlink ONCE, verify the canonical file + every ancestor is
    /// root-owned & non-writable, and hand back the canonical path. Because that
    /// chain is root-owned, a non-root user cannot alter it between here and exec.
    static func verifiedBackendPath() -> String? {
        #if BLTUSB_SELFHOSTED
        let canonical = (binaryPath as NSString).resolvingSymlinksInPath
        return backendChainIsRootOwned(canonical) ? canonical : nil
        #else
        // Real impl: SecStaticCode + SecCodeCheckValidity against the pinned
        // designated requirement, plus a sha256 match of the rootfs image; then
        // return the canonical verified path (ideally exec by descriptor).
        return binaryPath
        #endif
    }

    #if BLTUSB_SELFHOSTED
    /// True iff the symlink-resolved `path` and every ancestor directory up to `/`
    /// are owned by uid 0 and not group/other-writable — so no non-root user can
    /// substitute the executable or reach it via a writable parent.
    static func backendChainIsRootOwned(_ path: String) -> Bool {
        let fm = FileManager.default
        // Resolve symlinks first: a user-owned symlink (e.g. Homebrew's) must not
        // let a user redirect what we exec; we check the real target + real parents.
        var p = (path as NSString).resolvingSymlinksInPath
        while true {
            guard let a = try? fm.attributesOfItem(atPath: p) else { return false }
            guard let owner = (a[.ownerAccountID] as? NSNumber)?.uint32Value, owner == 0 else {
                return false   // not root-owned (or missing) -> fail closed
            }
            // Fail closed if the mode is missing/unparseable OR group/other-writable.
            guard let perms = (a[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
            if (perms & 0o022) != 0 {
                return false   // group/other-writable -> a non-root user could swap it
            }
            // POSIX mode + uid are not enough: a macOS ACL can grant a non-root
            // user write/delete/add even under uid-0 + no 022 bits. A backend
            // staged root-owned by our installer carries NO extended ACL, so we
            // conservatively FAIL CLOSED if any component has one.
            if hasExtendedACL(p) { return false }
            if p == "/" { return true }
            let parent = (p as NSString).deletingLastPathComponent
            p = parent.isEmpty ? "/" : parent
        }
    }

    /// Returns true if `path` has an extended ACL **or if ACL inspection could not
    /// conclusively prove there is none** — i.e. it means "not provably ACL-free",
    /// so the caller fails closed. Any ACL entry could grant a non-root principal
    /// mutation rights (write_data/append/add_file/add_subdirectory/delete/
    /// delete_child) that uid+mode checks miss; and an inconclusive inspection must
    /// never be read as "safe". Only a definitively absent/empty ACL returns false.
    static func hasExtendedACL(_ path: String) -> Bool {
        errno = 0
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
            // NULL is an ERROR, not "no ACL". Only ENOENT means "no extended ACL";
            // any other errno is inconclusive -> fail closed (treat as present).
            return errno != ENOENT
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry = acl_entry_t?.none
        // acl_get_entry: 0 = an entry exists (ACL present); 1 = no more entries
        // (empty ACL, safe); -1 = error (inconclusive -> fail closed). Only 1 is OK.
        return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 1
    }
    #endif

    /// Run `anylinuxfs mount` with a fixed argv and the secret scoped to this one
    /// child, zeroed after the child is spawned. Returns backendFailure on a
    /// non-zero exit. `secret` is consumed and zeroed by the caller regardless.
    static func mount(deviceID: String, fsType: FSType, mode: MountMode, secret: Secret?) -> Result<Void, HelperError> {
        // Exec ONLY the canonical, verified path — never `binaryPath` (a possibly
        // user-controlled symlink) — to close the verify-vs-exec TOCTOU.
        guard let exe = verifiedBackendPath() else { return .failure(.backendFailure) }
        let argv = Validators.anylinuxfsMountArgv(deviceID: deviceID, fsType: fsType, mode: mode)

        // TODO(signing/deploy): actually spawning this needs root + the deployed
        // hardened backend. Under the CLT-only build the binary is absent, so
        // Process.run() throws and we return backendFailure (fail closed).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
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
        guard let exe = verifiedBackendPath() else { return .failure(.backendFailure) }
        let argv = Validators.anylinuxfsUnmountArgv(mountpoint: mountpoint)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
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
