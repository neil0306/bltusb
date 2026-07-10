// RealSystemProbe — the ONE place the daemon touches the real system.
//
// Everything here needs root (raw device reads) and/or Full Disk Access (PPPC),
// which is why it is isolated behind the `SystemProbe` protocol: the guard
// *logic* is tested with a fake; only this file has real capabilities and it is
// exercised end-to-end only on a signed, MDM-deployed daemon.
//
// The `// TODO(signing/deploy)` markers below are the parts that cannot run in
// this CLT-only environment (no root, no FDA). They are written as real code
// that compiles; they simply won't succeed without the deploy-time grants.

import Foundation
import BltusbProtocol

struct RealSystemProbe: SystemProbe {

    // MARK: diskutil enumeration (needs FDA via PPPC at deploy time)

    func externalPartitionIDs() -> [String] {
        // diskutil list external physical | grep -oE 'disk[0-9]+s[0-9]+'
        let out = Shell.capture("/usr/sbin/diskutil", ["list", "external", "physical"]) ?? ""
        var ids = Set<String>()
        for token in out.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let s = String(token)
            if Validators.isValidDeviceID(s) { ids.insert(s) }
        }
        return ids.sorted()
    }

    func externalPartitionRows() -> [ExternalPartition] {
        // Parse `diskutil list external physical` rows. The bash uses awk to pull
        // (type, size, id) from the fixed columnar layout; we do the same shape.
        let out = Shell.capture("/usr/sbin/diskutil", ["list", "external", "physical"]) ?? ""
        var rows: [ExternalPartition] = []
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let last = cols.last, Validators.isValidDeviceID(last), cols.count >= 4 else { continue }
            // TYPE is columns [1 ..< count-3]; SIZE is the two before the id.
            let size = "\(cols[cols.count-3]) \(cols[cols.count-2])"
            let type = cols[1..<(cols.count-3)].joined(separator: " ")
            rows.append(ExternalPartition(deviceID: last, sizeText: size, typeText: type))
        }
        return rows
    }

    func diskInfo(deviceID: String) -> (partitionUUID: String?, volumeUUID: String?, label: String?, bytes: UInt64?) {
        let out = Shell.capture("/usr/sbin/diskutil", ["info", "/dev/\(deviceID)"]) ?? ""
        func field(_ key: String) -> String? {
            for line in out.split(separator: "\n") {
                guard let r = line.range(of: key + ":") else { continue }
                let v = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            return nil
        }
        var bytes: UInt64?
        if let disk = field("Disk Size") ?? field("Volume Used Space"),
           let paren = disk.range(of: "("),
           let end = disk[paren.upperBound...].range(of: " Bytes") {
            bytes = UInt64(disk[paren.upperBound..<end.lowerBound].filter(\.isNumber))
        }
        return (field("Partition UUID"), field("Volume UUID"), field("Volume Name"), bytes)
    }

    func rawBootSector(deviceID: String, count: Int) -> [UInt8]? {
        // TODO(signing/deploy): reading /dev/rdiskNsM requires root + FDA. In the
        // signed, MDM-deployed daemon this open() succeeds; under the CLT-only
        // build it returns nil (fail closed), which is the correct safe default.
        let path = "/dev/r\(deviceID)"
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: count), data.count == count else { return nil }
        return [UInt8](data)
    }

    func isHostMounted(deviceID: String) -> Bool {
        // Exact field compare against `mount` output, never a regex (a device
        // string is data, not a pattern) — mirrors the bash `host_mounted` awk.
        let out = Shell.capture("/sbin/mount", []) ?? ""
        let dev = "/dev/\(deviceID)"
        for line in out.split(separator: "\n") {
            if line.split(separator: " ").first.map(String.init) == dev { return true }
        }
        return false
    }

    func isAnyMountLive() -> Bool {
        // `anylinuxfs status` reports live mounts. Read-only status query; safe.
        let out = Shell.capture(AnylinuxfsRunner.binaryPath, ["status"]) ?? ""
        return out.contains("/Volumes/")
    }
}

// Minimal process-capture helper. NEVER used to run client-supplied strings —
// only fixed binaries with fixed, validated argument vectors.
enum Shell {
    static func capture(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
