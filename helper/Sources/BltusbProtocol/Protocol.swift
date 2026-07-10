// BltusbProtocol — the XPC contract between the unprivileged client and the
// root `bltusb-helperd`.
//
// SRAA §3 invariant: the helper exposes EXACTLY FOUR operations and NOTHING
// else. There is no passthrough of arbitrary `anylinuxfs` subcommands, options,
// env, paths, rootfs or config. The request enum below is the *entire* attack
// surface the root daemon accepts.
//
//   list-external     — enumerate external partitions
//   probe-external    — classify one partition (fstype/label/locked)
//   mount-external    — mount one external partition read-only (default)
//   unmount-external  — unmount one bltusb mountpoint
//
// The passphrase for `mount-external` is NEVER part of this Codable request —
// it travels as a separate, zeroable byte buffer over the XPC message (see
// `MountSecret`), so it can never land in a Codable that might be logged,
// encoded to JSON, or retained. SRAA §6.5: never in argv/env/logs/temp.

import Foundation

// MARK: - Operation allowlist (the ONLY 4 operations)

public enum HelperOp: String, Codable, Sendable, CaseIterable {
    case listExternal   = "list-external"
    case probeExternal  = "probe-external"
    case mountExternal  = "mount-external"
    case unmountExternal = "unmount-external"
}

// MARK: - Filesystem allowlist

/// Filesystems `anylinuxfs` may be asked to mount. Mirrors the bash
/// `fs_is_mountable`: bitlocker|luks|ntfs|exfat|ext|fat. Anything else is a
/// hard reject server-side (fail closed) — never "mount anyway".
public enum FSType: String, Codable, Sendable, CaseIterable {
    case bitlocker
    case luks
    case ntfs
    case exfat
    case ext
    case fat

    /// Encrypted filesystems require a passphrase to unlock.
    public var isEncrypted: Bool {
        switch self {
        case .bitlocker, .luks: return true
        default: return false
        }
    }
}

// MARK: - Mount mode

/// Read-only is the default and the ONLY value the auto path ever uses.
/// Read-write is a deliberate, policy-gated request (SRAA §6.6). The helper
/// treats `.rw` as disabled unless enterprise policy explicitly enables it.
public enum MountMode: String, Codable, Sendable {
    case ro
    case rw
}

// MARK: - Requests

public struct ProbeRequest: Codable, Sendable {
    public let deviceID: String   // must match ^disk\d+s\d+$
    public init(deviceID: String) { self.deviceID = deviceID }
}

public struct MountRequest: Codable, Sendable {
    public let deviceID: String      // ^disk\d+s\d+$
    public let fsType: FSType        // allowlist
    public let mountpoint: String    // must be under /Volumes/
    public let mode: MountMode       // .ro default
    // NOTE: no passphrase field here by design. The secret is a sibling
    // zeroable buffer in the XPC message, not part of this Codable.
    public init(deviceID: String, fsType: FSType, mountpoint: String, mode: MountMode = .ro) {
        self.deviceID = deviceID
        self.fsType = fsType
        self.mountpoint = mountpoint
        self.mode = mode
    }
}

public struct UnmountRequest: Codable, Sendable {
    public let mountpoint: String    // must be under /Volumes/
    public init(mountpoint: String) { self.mountpoint = mountpoint }
}

// MARK: - Replies

public struct ExternalPartition: Codable, Sendable {
    public let deviceID: String
    public let sizeText: String
    public let typeText: String
    public init(deviceID: String, sizeText: String, typeText: String) {
        self.deviceID = deviceID
        self.sizeText = sizeText
        self.typeText = typeText
    }
}

public struct ProbeResult: Codable, Sendable {
    public let deviceID: String
    public let fsType: FSType?     // nil == unknown/unmountable (fail closed)
    public let label: String?
    public let locked: Bool        // encrypted & needs a passphrase
    public init(deviceID: String, fsType: FSType?, label: String?, locked: Bool) {
        self.deviceID = deviceID
        self.fsType = fsType
        self.label = label
        self.locked = locked
    }
}

public struct MountResult: Codable, Sendable {
    public let mountpoint: String
    public init(mountpoint: String) { self.mountpoint = mountpoint }
}

/// Every server-side rejection maps to one of these — never a raw string that
/// might echo attacker-controlled input. os_log records the code, never the
/// device bytes or the passphrase.
public enum HelperError: String, Codable, Sendable, Error {
    case notAuthorized          // peer failed audit_token / code-sign requirement
    case invalidDeviceID        // regex failed
    case invalidFSType          // not in the allowlist
    case invalidMountpoint      // not under /Volumes/, traversal, symlink, etc.
    case notExternalPartition   // guard: not an enumerated external partition
    case isEFI                  // guard: EFI system partition
    case isWholeDiskOrInternal  // guard: whole disk / internal / rdisk
    case weakDeviceIdentity     // guard: no strong (UUID / boot-sector) identity
    case identityChanged        // TOCTOU: strong identity changed across the op
    case unknownFilesystem      // fail closed on unrecognized fs
    case rwNotPermitted         // rw requested but policy disables it
    case alreadyMounted         // host-mounted / another bltusb mount live
    case missingPassphrase      // encrypted fs but no secret provided
    case backendFailure         // anylinuxfs exited non-zero
    case internalError
}
