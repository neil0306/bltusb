// ServiceManagement — register/unregister the daemon as an SMAppService
// LaunchDaemon (the Apple-recommended, SRAA-friendly form; no manual
// /Library/LaunchDaemons plist, no `sudo launchctl`).
//
// TODO(signing/deploy): SMAppService.daemon(...).register() SUCCEEDS ONLY when:
//   · the daemon binary is inside a Developer-ID-signed, notarized app bundle
//     at Contents/MacOS, and its LaunchDaemon plist is at Contents/Library/
//     LaunchDaemons/<name>.plist with a matching BundleProgram + MachServices;
//   · a `com.apple.servicemanagement` MDM profile (TeamIdentifier rule) auto-
//     approves the background item -> zero user action.
// Under the CLT-only build there is no bundle and no signing identity, so
// register() returns .requiresApproval / throws; we surface that honestly.

import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

enum DaemonRegistration {

    // Matches the LaunchDaemon plist name shipped in the app bundle.
    static let plistName = "co.carryai.bltusb.helperd.plist"

    /// Register the daemon so launchd starts it on demand for the Mach service.
    /// Returns a human-readable status. TODO(signing/deploy) applies.
    static func register() -> String {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: plistName)
            do {
                try service.register()
                return "registered: status=\(service.status.rawValue)"
            } catch {
                // Expected without a signed bundle + MDM approval.
                return "register() failed (expected without signing/MDM): \(error.localizedDescription)"
            }
        } else {
            return "SMAppService requires macOS 13+"
        }
        #else
        return "ServiceManagement unavailable in this build"
        #endif
    }

    static func unregister() -> String {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: plistName)
            do { try service.unregister(); return "unregistered" }
            catch { return "unregister() failed: \(error.localizedDescription)" }
        } else {
            return "SMAppService requires macOS 13+"
        }
        #else
        return "ServiceManagement unavailable in this build"
        #endif
    }

    static func status() -> String {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            return "status=\(SMAppService.daemon(plistName: plistName).status.rawValue)"
        }
        #endif
        return "unknown"
    }
}
