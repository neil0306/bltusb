// bltusb-helperd — entry point.
//
// Modes:
//   bltusb-helperd                 -> run the XPC listener (launchd invokes this)
//   bltusb-helperd --register      -> SMAppService register (TODO: needs signing)
//   bltusb-helperd --unregister    -> SMAppService unregister
//   bltusb-helperd --status        -> SMAppService status
//   bltusb-helperd --self-check    -> run guard logic against the live system
//                                     (safe, read-only; useful without signing)
//
// TODO(signing/deploy): in production launchd starts this as ROOT via the
// SMAppService-registered LaunchDaemon. Running it by hand here starts a
// listener that will refuse every peer (requirement not configured) — which is
// the correct fail-closed behaviour until a Team ID is pinned.

import Foundation
import BltusbProtocol

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "--register":
    print(DaemonRegistration.register())

case "--unregister":
    print(DaemonRegistration.unregister())

case "--status":
    print(DaemonRegistration.status())

case "--self-check":
    // Read-only exercise of the guard pipeline against the real system. No
    // mount is performed. Demonstrates the classification path compiles + runs.
    let probe = RealSystemProbe()
    let guards = DeviceGuards(probe: probe)
    let rows = probe.externalPartitionRows()
    print("external partitions: \(rows.count)")
    for r in rows {
        let dev = r.deviceID
        let admit = guards.admit(deviceID: dev, requireMountable: false)
        switch admit {
        case .success(let fs):
            print("  \(dev)  type=\(r.typeText)  fs=\(fs?.rawValue ?? "unknown")")
        case .failure(let e):
            print("  \(dev)  type=\(r.typeText)  rejected=\(e.rawValue)")
        }
    }
    if !XPCServer.requirementIsConfigured {
        print("NOTE: peer code-signing requirement not configured (<TEAMID>) — "
            + "the live listener would refuse ALL callers. TODO(signing/deploy).")
    }

default:
    // Default: run the listener (launchd path).
    EndpointSecurityClient.startIfEntitled()
    let server = XPCServer(probe: RealSystemProbe(), policyAllowsRW: false)
    server.run()   // dispatchMain(); never returns
}
