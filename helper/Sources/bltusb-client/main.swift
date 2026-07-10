// bltusb-client — a thin CLI over BltusbClientLib, demonstrating the 4 ops.
//
// How the existing bash `bltusb` could call the helper: instead of
// `sudo anylinuxfs mount ...`, the bash tool shells out to this client, e.g.
//
//     mp="$(bltusb-client mount disk4s1 bitlocker /Volumes/Backup)"
//
// with the passphrase piped on stdin (never argv). This replaces the whole
// `run_mount`/`sudo` path — no sudo, no ALFS_PASSPHRASE in the bash env — while
// keeping the existing bash UX (Keychain, dialogs, wizard) unchanged. The
// client validates, the ROOT daemon re-validates and re-runs every guard.
//
// TODO(signing/deploy): connecting to the live daemon needs the daemon to be
// registered (SMAppService) and both sides signed with the pinned Team ID.
// Under the CLT-only build the Mach service is absent, so a real send blocks/
// errors — the parsing/validation path still compiles and runs.

import Foundation
import BltusbProtocol
import BltusbClientLib

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      bltusb-client list
      bltusb-client probe <diskNsM>
      bltusb-client mount <diskNsM> <fs_type> <mountpoint> [ro|rw]   # passphrase on stdin
      bltusb-client unmount <mountpoint>
    """.utf8))
    exit(2)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { usage() }

#if canImport(XPC)
let client = HelperClient()

do {
    switch cmd {
    case "list":
        for p in try client.listExternal() {
            print("\(p.deviceID)\t\(p.sizeText)\t\(p.typeText)")
        }

    case "probe":
        guard argv.count == 2 else { usage() }
        let r = try client.probe(deviceID: argv[1])
        print("device=\(r.deviceID) fs=\(r.fsType?.rawValue ?? "unknown") locked=\(r.locked) label=\(r.label ?? "")")

    case "mount":
        guard argv.count >= 4, let fs = FSType(rawValue: argv[2]) else { usage() }
        let mode: MountMode = (argv.count >= 5 && argv[4] == "rw") ? .rw : .ro
        // Read the passphrase from stdin (never argv), as raw bytes we can zero.
        var pass: [UInt8] = []
        if fs.isEncrypted {
            let line = FileHandle.standardInput.availableData
            pass = [UInt8](line).filter { $0 != 0x0a }   // drop trailing newline
        }
        let mp = try client.mount(deviceID: argv[1], fsType: fs, mountpoint: argv[3], mode: mode, passphrase: &pass)
        print(mp)

    case "unmount":
        guard argv.count == 2 else { usage() }
        try client.unmount(mountpoint: argv[1])
        print("unmounted \(argv[1])")

    default:
        usage()
    }
} catch let ClientError.helper(e) {
    FileHandle.standardError.write(Data("helper error: \(e.rawValue)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
#else
FileHandle.standardError.write(Data("XPC unavailable on this platform\n".utf8))
exit(1)
#endif
