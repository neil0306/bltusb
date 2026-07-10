// Validators — pure, side-effect-free input validation.
//
// SRAA §3 invariant: the helper validates EVERY input server-side and never
// trusts the client. These functions run inside the root daemon *before* any
// device is touched. They are pure so they are exhaustively unit-tested with
// `swift test` (no root, no hardware) — see Tests/BltusbProtocolTests.
//
// This file also re-implements, natively, the bash device *classification*
// guard `fs_is_mountable` and the raw boot-sector `fstype` signature match.
// The stateful guards that need `diskutil`/raw reads (external-partition,
// EFI, strong-identity) live in the daemon's DeviceGuards.swift because they
// query the system — but their *decision logic* is expressed here as pure
// predicates that the daemon feeds real data into, so the branching is testable.

import Foundation

public enum Validators {

    // MARK: device id  — ^disk\d+s\d+$  (a partition, never a whole disk /rdisk)

    /// Accepts ONLY `diskNsM` (external partition form). Rejects whole disks
    /// (`diskN`), raw aliases (`rdiskNsM`), `/dev/...` prefixes, and anything
    /// with extra characters. Mirrors the bash `^/dev/disk[0-9]+s[0-9]+$`
    /// canonical form after `canonical_device` strips `/dev/` and a leading `r`.
    public static func isValidDeviceID(_ s: String) -> Bool {
        // Must be exactly disk<digits>s<digits>, nothing else.
        guard !s.isEmpty else { return false }
        let scalars = Array(s.unicodeScalars)
        func digits(_ i: inout Int) -> Bool {
            let start = i
            while i < scalars.count, scalars[i] >= "0", scalars[i] <= "9" { i += 1 }
            return i > start
        }
        var i = 0
        let prefix = Array("disk".unicodeScalars)
        guard scalars.count > prefix.count else { return false }
        for p in prefix { guard scalars[i] == p else { return false }; i += 1 }
        guard digits(&i) else { return false }
        guard i < scalars.count, scalars[i] == "s" else { return false }
        i += 1
        guard digits(&i) else { return false }
        return i == scalars.count   // no trailing garbage
    }

    /// Strip an accidental `/dev/` prefix and a raw-device `r`, then validate.
    /// Returns the canonical `diskNsM` or nil. (Canonicalisation matches the
    /// bash `canonical_device`; validation is still applied afterwards.)
    public static func canonicalDeviceID(_ raw: String) -> String? {
        var d = raw
        if d.hasPrefix("/dev/") { d.removeFirst("/dev/".count) }
        if d.hasPrefix("r") { d.removeFirst() }
        return isValidDeviceID(d) ? d : nil
    }

    // MARK: fs type

    public static func fsType(from raw: String) -> FSType? {
        FSType(rawValue: raw)
    }

    // MARK: mountpoint  — must be a literal path under /Volumes/, no traversal

    /// Accepts ONLY `/Volumes/<name>` with a single path component after
    /// `/Volumes/`. Rejects `..`, embedded NUL, empty component, nested paths,
    /// and control characters. NOTE: this is the *syntactic* gate; the daemon
    /// additionally `realpath`-resolves and re-checks the prefix to defeat
    /// symlink tricks (see DeviceGuards.resolvedMountpointUnderVolumes).
    public static func isValidMountpoint(_ s: String) -> Bool {
        let prefix = "/Volumes/"
        guard s.hasPrefix(prefix) else { return false }
        let rest = String(s.dropFirst(prefix.count))
        guard !rest.isEmpty else { return false }
        // exactly one component
        guard !rest.contains("/") else { return false }
        guard rest != "." && rest != ".." else { return false }
        for u in rest.unicodeScalars {
            if u == "\u{0}" { return false }
            if u.value < 0x20 || u.value == 0x7F { return false }  // control/DEL
        }
        return true
    }

    // MARK: mode policy

    /// rw is a policy-gated, deliberate decision. Default deployment posture is
    /// ro-only (SRAA §6.6). `policyAllowsRW` is supplied by the daemon from an
    /// MDM-managed config, not by the client.
    public static func isModePermitted(_ mode: MountMode, policyAllowsRW: Bool) -> Bool {
        switch mode {
        case .ro: return true
        case .rw: return policyAllowsRW
        }
    }

    // MARK: fixed anylinuxfs argument vectors (NO arbitrary args ever)

    /// The mount option vector for a given fs/mode. This is the ONLY place mount
    /// options are constructed; the client cannot inject `-o` values. Mirrors
    /// the bash: ext -> "ro,norecovery" (no journal replay writes), else "ro";
    /// rw drops the ro option. Returns the option tokens only (device is
    /// appended by the caller as a fixed final arg).
    public static func mountOptionTokens(fsType: FSType, mode: MountMode) -> [String] {
        var opts = ["-w", "false"]
        switch mode {
        case .ro:
            if fsType == .ext {
                opts += ["-o", "ro,norecovery"]
            } else {
                opts += ["-o", "ro"]
            }
        case .rw:
            // rw: no read-only option. (Reachable only when policy permits.)
            break
        }
        return opts
    }

    /// The complete, fixed argv for `anylinuxfs mount`. Device id is validated
    /// by the caller BEFORE this is built. There is no way for a client value to
    /// become anything other than the device id and the option allowlist above.
    public static func anylinuxfsMountArgv(deviceID: String, fsType: FSType, mode: MountMode) -> [String] {
        // e.g. ["mount", "-w", "false", "-o", "ro", "/dev/disk4s1"]
        ["mount"] + mountOptionTokens(fsType: fsType, mode: mode) + ["/dev/\(deviceID)"]
    }

    /// The complete, fixed argv for `anylinuxfs unmount`. `-w` waits for the
    /// microVM to finish flushing; the mountpoint scopes the teardown to just
    /// this volume (never a bare `unmount` that tears down all mounts).
    public static func anylinuxfsUnmountArgv(mountpoint: String) -> [String] {
        ["unmount", "-w", mountpoint]
    }
}

// MARK: - Boot-sector filesystem classification (native re-impl of bash `fstype`)

/// Classify a partition's filesystem from its boot-sector bytes. This mirrors
/// the bash `fstype()` signature checks EXACTLY so the helper's fail-closed
/// selection is identical to the reviewed tool — but it runs natively inside
/// the root daemon rather than shelling `dd | tr`. The daemon reads the first
/// sectors of `/dev/rdiskNsM` (raw) itself and passes the bytes here; this
/// function performs no I/O, so it is unit-testable with synthetic sectors.
public enum BootSector {

    /// BitLocker volume signature "-FVE-FS-" at offset 3.
    static let bitlockerSig = Array("-FVE-FS-".utf8)

    /// Read `count` bytes at `offset` from `data`, trimming trailing NULs, as a
    /// Latin-1/ASCII string (mirrors the bash `_devbytes | tr -d '\000'`).
    static func asciiField(_ data: [UInt8], _ offset: Int, _ count: Int) -> String {
        guard offset >= 0, count > 0, offset + count <= data.count else { return "" }
        let slice = data[offset..<(offset + count)].filter { $0 != 0 }
        return String(decoding: slice, as: UTF8.self)
    }

    /// Returns the classified `FSType` (only the mountable ones) or nil for
    /// apfs / luks-not-supported / unknown — nil is the fail-closed "skip".
    ///
    /// `data` must contain at least the first ~1082 bytes of the partition.
    public static func classify(_ data: [UInt8]) -> FSType? {
        let oem = asciiField(data, 3, 8)
        if oem == "-FVE-FS-" { return .bitlocker }
        if oem.hasPrefix("NTFS") { return .ntfs }
        if oem.hasPrefix("EXFAT") { return .exfat }
        if asciiField(data, 0, 4) == "LUKS" { return .luks }
        if asciiField(data, 82, 8).hasPrefix("FAT32") { return .fat }
        let f16 = asciiField(data, 54, 8)
        if f16.hasPrefix("FAT12") || f16.hasPrefix("FAT16") { return .fat }
        // ext magic 0x53 0xEF at offset 1080 (little-endian s_magic = 0xEF53)
        if data.count >= 1082, data[1080] == 0x53, data[1081] == 0xEF { return .ext }
        // apfs "NXSB" at 32 and anything else -> unknown/unmountable (fail closed)
        return nil
    }
}
