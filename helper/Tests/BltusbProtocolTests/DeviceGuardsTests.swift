import Testing
@testable import BltusbProtocol

// A fully in-memory SystemProbe so the guard DECISION logic is tested with no
// root, no diskutil, no hardware. Mirrors the bash guards' branch coverage:
// external-partition / EFI / whole-disk-rejection / strong-identity /
// fail-closed-fs / TOCTOU reverify.
final class FakeProbe: SystemProbe, @unchecked Sendable {
    var externalIDs: [String] = []
    var rows: [ExternalPartition] = []
    var infos: [String: (String?, String?, String?, UInt64?)] = [:]
    var sectors: [String: [UInt8]] = [:]
    var hostMounted: Set<String> = []
    var anyLive = false

    func externalPartitionIDs() -> [String] { externalIDs }
    func externalPartitionRows() -> [ExternalPartition] { rows }
    func diskInfo(deviceID: String) -> (partitionUUID: String?, volumeUUID: String?, label: String?, bytes: UInt64?) {
        let t = infos[deviceID] ?? (nil, nil, nil, nil)
        return (t.0, t.1, t.2, t.3)
    }
    func rawBootSector(deviceID: String, count: Int) -> [UInt8]? {
        guard let s = sectors[deviceID] else { return nil }
        return Array(s.prefix(count))
    }
    func isHostMounted(deviceID: String) -> Bool { hostMounted.contains(deviceID) }
    func isAnyMountLive() -> Bool { anyLive }
}

private func sector(bytes: [Int: [UInt8]]) -> [UInt8] {
    var d = [UInt8](repeating: 0, count: 1082)
    for (o, v) in bytes { for (i, b) in v.enumerated() where o+i < d.count { d[o+i] = b } }
    return d
}

@Suite struct DeviceGuardsTests {

    @Test func externalPartitionGuard() {
        let p = FakeProbe(); p.externalIDs = ["disk4s1"]
        let g = DeviceGuards(probe: p)
        #expect(g.isExternalPartition("disk4s1"))
        #expect(!g.isExternalPartition("disk0s2"))  // internal — rejected
    }

    @Test func efiGuard() {
        let p = FakeProbe()
        p.rows = [ExternalPartition(deviceID: "disk4s1", sizeText: "200 MB", typeText: "EFI EFI System Partition"),
                  ExternalPartition(deviceID: "disk4s2", sizeText: "64 GB", typeText: "Microsoft Basic Data")]
        let g = DeviceGuards(probe: p)
        #expect(g.isEFI("disk4s1"))
        #expect(!g.isEFI("disk4s2"))
    }

    @Test func strongIdentityFromUUID() {
        let p = FakeProbe()
        p.infos["disk4s1"] = (nil, "ABC-UUID", "Backup", 64_000_000)
        let g = DeviceGuards(probe: p)
        #expect(g.strongDeviceIdentity("disk4s1") == "ABC-UUID|Backup|64000000")
    }

    @Test func strongIdentityFallsBackToFingerprint() {
        let p = FakeProbe()
        p.infos["disk4s1"] = (nil, nil, "NoUUID", 100)      // no UUID at all
        p.sectors["disk4s1"] = sector(bytes: [3: Array("NTFS    ".utf8)])
        let g = DeviceGuards(probe: p)
        let id = g.strongDeviceIdentity("disk4s1")
        #expect(id != nil)
        #expect(id?.hasPrefix("fp:") == true)   // boot-sector fingerprint anchor
    }

    @Test func weakIdentityRejected() {
        let p = FakeProbe()
        p.infos["disk4s1"] = (nil, nil, nil, nil)           // no uuid, no sector
        let g = DeviceGuards(probe: p)
        #expect(g.strongDeviceIdentity("disk4s1") == nil)
    }

    @Test func admitHappyPath() {
        let p = FakeProbe()
        p.externalIDs = ["disk4s1"]
        p.rows = [ExternalPartition(deviceID: "disk4s1", sizeText: "64 GB", typeText: "Microsoft Basic Data")]
        p.infos["disk4s1"] = (nil, "UUID1", "Win", 64_000_000)
        p.sectors["disk4s1"] = sector(bytes: [3: Array("-FVE-FS-".utf8)])   // bitlocker
        let g = DeviceGuards(probe: p)
        guard case .success(let fs) = g.admit(deviceID: "disk4s1", requireMountable: true) else {
            Issue.record("expected success"); return
        }
        #expect(fs == .bitlocker)
    }

    @Test func admitRejectsInternal() {
        let g = DeviceGuards(probe: FakeProbe())   // not in externalIDs
        guard case .failure(let e) = g.admit(deviceID: "disk0s2", requireMountable: true) else {
            Issue.record("expected failure"); return
        }
        #expect(e == .notExternalPartition)
    }

    @Test func admitRejectsEFI() {
        let p = FakeProbe()
        p.externalIDs = ["disk4s1"]
        p.rows = [ExternalPartition(deviceID: "disk4s1", sizeText: "200 MB", typeText: "EFI System")]
        p.infos["disk4s1"] = (nil, "U", "EFI", 200)
        let g = DeviceGuards(probe: p)
        guard case .failure(let e) = g.admit(deviceID: "disk4s1", requireMountable: true) else {
            Issue.record("expected failure"); return
        }
        #expect(e == .isEFI)
    }

    @Test func admitFailsClosedOnUnknownFS() {
        let p = FakeProbe()
        p.externalIDs = ["disk4s1"]
        p.rows = [ExternalPartition(deviceID: "disk4s1", sizeText: "1 GB", typeText: "Apple APFS")]
        p.infos["disk4s1"] = (nil, "U", "Mac", 1)
        p.sectors["disk4s1"] = sector(bytes: [32: Array("NXSB".utf8)])   // apfs -> unknown
        let g = DeviceGuards(probe: p)
        guard case .failure(let e) = g.admit(deviceID: "disk4s1", requireMountable: true) else {
            Issue.record("expected failure"); return
        }
        #expect(e == .unknownFilesystem)
    }

    @Test func reverifyDetectsDeviceSwap() {
        let p = FakeProbe()
        p.externalIDs = ["disk4s1"]
        p.rows = [ExternalPartition(deviceID: "disk4s1", sizeText: "64 GB", typeText: "Basic Data")]
        p.infos["disk4s1"] = (nil, "UUID-ORIGINAL", "Win", 64)
        let g = DeviceGuards(probe: p)
        let captured = g.strongDeviceIdentity("disk4s1")!
        // Swap the device behind diskNsM during the "dialog".
        p.infos["disk4s1"] = (nil, "UUID-ATTACKER", "Evil", 64)
        #expect(g.reverify(deviceID: "disk4s1", capturedIdentity: captured) == .identityChanged)
    }

    @Test func reverifyRejectsBlankIdentity() {
        let g = DeviceGuards(probe: FakeProbe())
        #expect(g.reverify(deviceID: "disk4s1", capturedIdentity: "") == .identityChanged)
    }

    @Test func reverifyRejectsHostMounted() {
        let p = FakeProbe()
        p.externalIDs = ["disk4s1"]
        p.rows = [ExternalPartition(deviceID: "disk4s1", sizeText: "64 GB", typeText: "Basic Data")]
        p.infos["disk4s1"] = (nil, "UUID1", "Win", 64)
        p.hostMounted = ["disk4s1"]
        let g = DeviceGuards(probe: p)
        let captured = g.strongDeviceIdentity("disk4s1")!
        #expect(g.reverify(deviceID: "disk4s1", capturedIdentity: captured) == .alreadyMounted)
    }

    @Test func reverifyHappyPath() {
        let p = FakeProbe()
        p.externalIDs = ["disk4s1"]
        p.rows = [ExternalPartition(deviceID: "disk4s1", sizeText: "64 GB", typeText: "Basic Data")]
        p.infos["disk4s1"] = (nil, "UUID1", "Win", 64)
        let g = DeviceGuards(probe: p)
        let captured = g.strongDeviceIdentity("disk4s1")!
        #expect(g.reverify(deviceID: "disk4s1", capturedIdentity: captured) == nil)
    }
}
