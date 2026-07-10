import Testing
@testable import BltusbProtocol

// Uses swift-testing (the `Testing` framework), which ships with the Command
// Line Tools; XCTest does not ship with CLT-only, so we avoid it.

@Suite struct ValidatorsTests {

    // MARK: device id regex  ^disk\d+s\d+$

    @Test func validDeviceIDs() {
        #expect(Validators.isValidDeviceID("disk4s1"))
        #expect(Validators.isValidDeviceID("disk0s2"))
        #expect(Validators.isValidDeviceID("disk12s34"))
    }

    @Test func rejectsWholeDiskAndRawAndPrefixes() {
        #expect(!Validators.isValidDeviceID("disk4"))        // whole disk
        #expect(!Validators.isValidDeviceID("rdisk4s1"))     // raw alias
        #expect(!Validators.isValidDeviceID("/dev/disk4s1")) // prefixed
        #expect(!Validators.isValidDeviceID("disk4s"))       // no part num
        #expect(!Validators.isValidDeviceID("disks1"))       // no disk num
        #expect(!Validators.isValidDeviceID("disk4s1 "))     // trailing space
        #expect(!Validators.isValidDeviceID("disk4s1;rm"))   // injection
        #expect(!Validators.isValidDeviceID(""))             // empty
        #expect(!Validators.isValidDeviceID("xdisk4s1"))     // wrong prefix
    }

    @Test func canonicalDeviceID() {
        #expect(Validators.canonicalDeviceID("/dev/disk4s1") == "disk4s1")
        #expect(Validators.canonicalDeviceID("/dev/rdisk4s1") == "disk4s1")
        #expect(Validators.canonicalDeviceID("disk4s1") == "disk4s1")
        #expect(Validators.canonicalDeviceID("/dev/disk4") == nil)     // whole disk
        #expect(Validators.canonicalDeviceID("../../etc/passwd") == nil)
    }

    // MARK: fs type allowlist

    @Test func fsTypeAllowlist() {
        for ok in ["bitlocker", "luks", "ntfs", "exfat", "ext", "fat"] {
            #expect(Validators.fsType(from: ok) != nil, "\(ok) should be allowed")
        }
        for bad in ["apfs", "hfs", "vfat", "shell", "", "ntfs-3g"] {
            #expect(Validators.fsType(from: bad) == nil, "\(bad) should be rejected")
        }
    }

    @Test func encryptedClassification() {
        #expect(FSType.bitlocker.isEncrypted)
        #expect(FSType.luks.isEncrypted)
        #expect(!FSType.ntfs.isEncrypted)
        #expect(!FSType.exfat.isEncrypted)
        #expect(!FSType.ext.isEncrypted)
        #expect(!FSType.fat.isEncrypted)
    }

    // MARK: mountpoint

    @Test func validMountpoints() {
        #expect(Validators.isValidMountpoint("/Volumes/Backup"))
        #expect(Validators.isValidMountpoint("/Volumes/My Disk"))
        #expect(Validators.isValidMountpoint("/Volumes/备份"))
    }

    @Test func rejectsBadMountpoints() {
        #expect(!Validators.isValidMountpoint("/etc/passwd"))
        #expect(!Validators.isValidMountpoint("/Volumes/"))
        #expect(!Validators.isValidMountpoint("/Volumes/../etc"))
        #expect(!Validators.isValidMountpoint("/Volumes/a/b"))     // nested
        #expect(!Validators.isValidMountpoint("/Volumes/.."))
        #expect(!Validators.isValidMountpoint("/Volumes/x\u{0}y")) // NUL
        #expect(!Validators.isValidMountpoint("/Volumes/x\u{1b}[2J")) // ANSI esc
        #expect(!Validators.isValidMountpoint("relative"))
    }

    // MARK: mode policy

    @Test func modePolicy() {
        #expect(Validators.isModePermitted(.ro, policyAllowsRW: false))
        #expect(Validators.isModePermitted(.ro, policyAllowsRW: true))
        #expect(!Validators.isModePermitted(.rw, policyAllowsRW: false)) // default: no rw
        #expect(Validators.isModePermitted(.rw, policyAllowsRW: true))
    }

    // MARK: fixed argv (no arbitrary args)

    @Test func mountArgvIsFixedAndAllowlisted() {
        #expect(Validators.anylinuxfsMountArgv(deviceID: "disk4s1", fsType: .bitlocker, mode: .ro)
                == ["mount", "-w", "false", "-o", "ro", "/dev/disk4s1"])
        // ext gets ro,norecovery (no journal-replay writes on a "ro" mount)
        #expect(Validators.anylinuxfsMountArgv(deviceID: "disk9s3", fsType: .ext, mode: .ro)
                == ["mount", "-w", "false", "-o", "ro,norecovery", "/dev/disk9s3"])
        // rw drops the ro option (only reachable when policy allows)
        #expect(Validators.anylinuxfsMountArgv(deviceID: "disk4s1", fsType: .ntfs, mode: .rw)
                == ["mount", "-w", "false", "/dev/disk4s1"])
    }

    @Test func unmountArgvIsScoped() {
        // -w waits for flush; mountpoint scopes teardown to this volume only
        #expect(Validators.anylinuxfsUnmountArgv(mountpoint: "/Volumes/Backup")
                == ["unmount", "-w", "/Volumes/Backup"])
    }
}
