// DeviceGuards — the server-side, fail-closed device guards.
//
// SRAA §3: the helper re-runs EVERY guard natively, server-side. The client's
// claims are never trusted. These mirror the bash guards one-for-one:
//
//   device_is_external_partition   -> isExternalPartition
//   device_is_efi                  -> isEFI
//   canonical_device / whole-disk  -> Validators.canonicalDeviceID
//   strong_device_identity         -> strongDeviceIdentity
//   fstype / fs_is_mountable       -> BootSector.classify (in BltusbProtocol)
//   _autounlock_reverify (TOCTOU)  -> reverify()
//
// The pieces that query the system (`diskutil`, raw sector reads) are isolated
// behind a `SystemProbe` protocol so:
//   (a) the pure decision logic is testable with a fake probe, and
//   (b) the real, root-only probe is one clearly-marked implementation.

import Foundation

/// Everything the guards need from the host. The real implementation shells
/// `diskutil` and reads raw sectors as root; a fake implementation drives the
/// unit tests. This is the whole "requires root / real device" boundary.
public protocol SystemProbe: Sendable {
    /// External physical partitions (diskNsM ids only). Mirrors
    /// `diskutil list external physical | grep -oE 'disk[0-9]+s[0-9]+'`.
    func externalPartitionIDs() -> [String]
    /// One row per external partition (id, size text, type text). Mirrors
    /// `list_partition_rows`. `type` "EFI…" marks an EFI system partition.
    func externalPartitionRows() -> [ExternalPartition]
    /// `diskutil info` fields we anchor identity on: (partitionUUID, volumeUUID,
    /// volumeName, byteCount). Any may be nil.
    func diskInfo(deviceID: String) -> (partitionUUID: String?, volumeUUID: String?, label: String?, bytes: UInt64?)
    /// First `count` raw bytes of `/dev/rdisk<deviceID>` (root-only). Returns
    /// nil on a failed/short read — the caller treats nil as "unknown".
    func rawBootSector(deviceID: String, count: Int) -> [UInt8]?
    /// Is the device currently mounted by macOS itself?
    func isHostMounted(deviceID: String) -> Bool
    /// Is ANY bltusb/anylinuxfs mount already live?
    func isAnyMountLive() -> Bool
}

public struct DeviceGuards: Sendable {
    public let probe: SystemProbe
    public init(probe: SystemProbe) { self.probe = probe }

    // device_is_external_partition
    public func isExternalPartition(_ deviceID: String) -> Bool {
        probe.externalPartitionIDs().contains(deviceID)
    }

    // device_is_efi — positively typed EFI* row only
    public func isEFI(_ deviceID: String) -> Bool {
        for row in probe.externalPartitionRows() where row.deviceID == deviceID {
            return row.typeText.hasPrefix("EFI")
        }
        return false
    }

    // strong_device_identity — "uuid|label|bytes" or "fp:<hash>|..." ; nil if
    // neither a UUID nor a boot-sector fingerprint can be derived (weak id).
    public func strongDeviceIdentity(_ deviceID: String) -> String? {
        let info = probe.diskInfo(deviceID: deviceID)
        let uuid = info.volumeUUID ?? info.partitionUUID
        let label = info.label ?? ""
        let bytes = info.bytes.map(String.init) ?? ""
        if let uuid, !uuid.isEmpty {
            return "\(uuid)|\(label)|\(bytes)"
        }
        // No UUID — anchor to a boot-sector fingerprint (device_key fallback).
        if let puuid = info.partitionUUID, !puuid.isEmpty {
            return "puuid:\(puuid)|\(label)|\(bytes)"
        }
        if let sector = probe.rawBootSector(deviceID: deviceID, count: 512), sector.count == 512 {
            let fp = Fingerprint.sha256Hex(sector).prefix(32)
            return "fp:\(fp)||\(bytes)"
        }
        return nil
    }

    // fstype + fs_is_mountable, fail-closed: reads the raw sectors and classifies
    public func classifyFilesystem(_ deviceID: String) -> FSType? {
        guard let data = probe.rawBootSector(deviceID: deviceID, count: 1082) else { return nil }
        return BootSector.classify(data)
    }

    /// Full admission check for a mount/probe target. Returns the validated
    /// FSType on success, or a specific HelperError on the FIRST failing guard
    /// (fail closed). This is the single server-side gate every mount passes.
    public func admit(deviceID: String, requireMountable: Bool) -> Result<FSType?, HelperError> {
        // (device id already regex-validated by the caller)
        guard isExternalPartition(deviceID) else { return .failure(.notExternalPartition) }
        guard !isEFI(deviceID) else { return .failure(.isEFI) }
        guard strongDeviceIdentity(deviceID) != nil else { return .failure(.weakDeviceIdentity) }
        let fs = classifyFilesystem(deviceID)
        if requireMountable, fs == nil { return .failure(.unknownFilesystem) }
        return .success(fs)
    }

    /// TOCTOU re-verification (mirrors `_autounlock_reverify`): the captured
    /// strong identity must still match, the device must still be an external
    /// non-EFI partition, and not host-mounted. A blank/changed identity aborts.
    public func reverify(deviceID: String, capturedIdentity: String) -> HelperError? {
        guard !capturedIdentity.isEmpty else { return .identityChanged }
        guard let now = strongDeviceIdentity(deviceID), now == capturedIdentity else {
            return .identityChanged
        }
        guard isExternalPartition(deviceID) else { return .notExternalPartition }
        guard !isEFI(deviceID) else { return .isEFI }
        guard !probe.isHostMounted(deviceID: deviceID) else { return .alreadyMounted }
        return nil
    }
}

// Tiny SHA-256 hex over a byte buffer, via CryptoKit if present, else a
// dependency-free fallback so this compiles under the CLT toolchain without
// importing Xcode-only modules. (CryptoKit ships with the SDK, so the import
// path is taken; the fallback keeps the file honest if it ever isn't.)
enum Fingerprint {
    static func sha256Hex(_ bytes: [UInt8]) -> String {
        #if canImport(CryptoKit)
        return _cryptoKitHex(bytes)
        #else
        return _pureHex(bytes)
        #endif
    }
}

#if canImport(CryptoKit)
import CryptoKit
extension Fingerprint {
    static func _cryptoKitHex(_ bytes: [UInt8]) -> String {
        let d = SHA256.hash(data: Data(bytes))
        return d.map { String(format: "%02x", $0) }.joined()
    }
}
#endif

extension Fingerprint {
    // Minimal, self-contained SHA-256 (only used if CryptoKit is unavailable).
    static func _pureHex(_ message: [UInt8]) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        var msg = message
        let ml = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in stride(from: 56, through: 0, by: -8) { msg.append(UInt8((ml >> UInt64(i)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j+1]) << 16) | (UInt32(msg[j+2]) << 8) | UInt32(msg[j+3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i-15],7) ^ rotr(w[i-15],18) ^ (w[i-15] >> 3)
                let s1 = rotr(w[i-2],17) ^ rotr(w[i-2],19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
