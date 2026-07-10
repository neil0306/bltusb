// DevRequirement — a LOCAL-DEV-ONLY code-signing requirement override.
//
// WHY THIS EXISTS
// ---------------
// The production caller-authentication (`kPeerCodeSigningRequirement`) pins the
// real Apple Developer Team ID, which cannot be produced without an enrolled
// Developer ID. To *prove the XPC + caller-authentication boundary works* on a
// developer machine — with ad-hoc code signing, no Apple account, no Xcode, no
// root — we need to be able to pin the daemon to a locally-signed client's
// cdhash instead of a Team ID.
//
// SAFETY (why this can NEVER weaken a production build)
// -----------------------------------------------------
//  1. COMPILE-TIME OFF BY DEFAULT. The entire dev path is behind
//     `#if BLTUSB_DEV_REQUIREMENT`. A normal `swift build` (production) does NOT
//     pass `-D BLTUSB_DEV_REQUIREMENT`, so `string` is a hard-coded `nil` and
//     there is literally no code that reads any file. The dev requirement does
//     not exist in a production binary.
//
//  2. RUNTIME-GATED even in a dev build. `DevRequirement.string` is consulted by
//     `XPCServer.effectiveRequirement` ONLY when `!requirementIsConfigured`,
//     i.e. only while the compiled `kPeerCodeSigningRequirement` still contains
//     the `<TEAMID>` placeholder. The instant a real Team ID is baked in,
//     `requirementIsConfigured` becomes true and the dev override is never even
//     read — a Team-ID build authenticates against the Team ID and nothing else,
//     even if it was (mistakenly) compiled with `-D BLTUSB_DEV_REQUIREMENT`.
//
//  3. AGENT-OWNED FILE, not an env var. The dev requirement is read from a file
//     the daemon's own user owns, NOT from an environment variable an attacker
//     could set on the daemon. The file is written by the dev harness and pins
//     the ad-hoc client's cdhash, so only that one locally-signed client is
//     accepted.
//
// Net effect: this is unmistakably dev-scoped, off by default, and cannot
// silently relax a real Team-ID (production) daemon.

import Foundation

enum DevRequirement {

    #if BLTUSB_DEV_REQUIREMENT

    /// Path to the agent-owned file holding the dev requirement string. It lives
    /// under the per-user LaunchAgent's support dir, written by the dev harness
    /// (`scripts/pin-dev-requirement.sh`). This path is used ONLY in dev builds.
    static let path: String =
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/bltusb-dev/peer-requirement.txt")

    /// The dev requirement string, or nil if the file is absent/empty. Read once
    /// per access; the daemon calls this rarely (per connection). We deliberately
    /// require the file to be owned by the current (agent) user and not
    /// world-writable, so another local user cannot plant a permissive
    /// requirement.
    static var string: String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        // Reject a group/other-writable file (would let another account relax us).
        if let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value,
           (perms & 0o022) != 0 {
            return nil
        }
        // Must be owned by us (the agent user).
        if let owner = attrs[.ownerAccountID] as? NSNumber,
           owner.uint32Value != getuid() {
            return nil
        }
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let req = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return req.isEmpty ? nil : req
    }

    #else

    /// Production build: the dev override does not exist. Always nil; no file is
    /// ever read. `effectiveRequirement` therefore returns the compiled
    /// production requirement unchanged.
    static let string: String? = nil

    #endif
}
