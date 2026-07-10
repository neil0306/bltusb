import Testing
@testable import BltusbProtocol

// Verifies the native re-implementation of the bash `fstype()` boot-sector
// signature match, using synthetic sectors — no root, no hardware.
@Suite struct BootSectorTests {

    private func sector(bytes: [Int: [UInt8]], size: Int = 1082) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: size)
        for (off, val) in bytes {
            for (i, b) in val.enumerated() where off + i < size { data[off + i] = b }
        }
        return data
    }

    @Test func bitlocker() {
        #expect(BootSector.classify(sector(bytes: [3: Array("-FVE-FS-".utf8)])) == .bitlocker)
    }
    @Test func ntfs() {
        #expect(BootSector.classify(sector(bytes: [3: Array("NTFS    ".utf8)])) == .ntfs)
    }
    @Test func exfat() {
        #expect(BootSector.classify(sector(bytes: [3: Array("EXFAT   ".utf8)])) == .exfat)
    }
    @Test func luks() {
        #expect(BootSector.classify(sector(bytes: [0: Array("LUKS".utf8)])) == .luks)
    }
    @Test func fat32() {
        #expect(BootSector.classify(sector(bytes: [82: Array("FAT32   ".utf8)])) == .fat)
    }
    @Test func fat16() {
        #expect(BootSector.classify(sector(bytes: [54: Array("FAT16   ".utf8)])) == .fat)
    }
    @Test func ext() {
        // ext s_magic 0xEF53 (LE bytes 0x53 0xEF) at offset 1080
        #expect(BootSector.classify(sector(bytes: [1080: [0x53, 0xEF]])) == .ext)
    }
    @Test func apfsIsUnknown() {
        // APFS "NXSB" at offset 32 -> not mountable by us -> nil (fail closed)
        #expect(BootSector.classify(sector(bytes: [32: Array("NXSB".utf8)])) == nil)
    }
    @Test func emptyIsUnknown() {
        #expect(BootSector.classify([UInt8](repeating: 0, count: 1082)) == nil)
    }
    @Test func shortBufferDoesNotCrash() {
        #expect(BootSector.classify([0x01, 0x02, 0x03]) == nil)
    }
}
