// SelfHostedRequirement — a PRODUCTION-suitable cdhash requirement source for
// Mode B ("personal self-hosted", no Apple Developer account).
//
// WHY THIS EXISTS (and how it differs from DevRequirement)
// --------------------------------------------------------
// DevRequirement.swift pins the caller by cdhash from a file owned by the
// *invoking user* (getuid()), for a per-user LaunchAgent dev harness. That is
// fine for a developer proving the boundary on their own account, but it is NOT
// safe for a real installed daemon: the Mode-B daemon runs as ROOT under a
// system LaunchDaemon, so the requirement file it trusts must be ROOT-owned and
// non-world-writable — otherwise any local user could plant a permissive
// requirement and be accepted as an authorized caller.
//
// This file is the Mode-B analogue: same cdhash-pinning idea, but the ownership
// check is for uid 0 (root), matching the install-selfhosted.sh layout where the
// installer writes a root:wheel 0644 peer-requirement.txt.
//
// SAFETY — why this can NEVER weaken a production (Mode A) build
// -------------------------------------------------------------
//  1. COMPILE-TIME OFF BY DEFAULT. The whole path is behind
//     `#if BLTUSB_SELFHOSTED`. A production Mode-A build does NOT pass
//     `-D BLTUSB_SELFHOSTED`, so `string` is a hard-coded `nil` and no file is
//     ever read.
//  2. RUNTIME-GATED even when compiled in. `XPCServer.effectiveRequirement`
//     consults this ONLY when `!requirementIsConfigured` — i.e. only while the
//     compiled `kPeerCodeSigningRequirement` still contains the `<TEAMID>`
//     placeholder (Mode B). The instant a real Team ID is baked in (Mode A),
//     `requirementIsConfigured` is true, this source is never read, and the
//     daemon authenticates against the Team ID and nothing else.
//  3. ROOT-OWNED FILE, fail-closed. The file must be owned by uid 0 and must not
//     be group/other-writable; otherwise it is ignored (returns nil → the daemon
//     falls back to fail-closed with no requirement). A non-root or
//     world-writable requirement file is treated as absent, never obeyed.
//
// Net effect: Mode-B production caller-auth pins exactly the one root-installed
// client's cdhash, and a Mode-A (Team-ID) daemon is byte-for-byte unaffected.

import Foundation

enum SelfHostedRequirement {

    #if BLTUSB_SELFHOSTED

    /// Path to the ROOT-owned file holding the pinned caller requirement string,
    /// written by `scripts/install-selfhosted.sh` as root:wheel 0644. Fixed,
    /// absolute, under the root-owned install tree — never a user path.
    static let path = "/Library/Application Support/bltusb/peer-requirement.txt"

    /// The pinned requirement string, or nil if the file is absent/empty or does
    /// not pass the ownership/permission checks (fail closed). Read per access;
    /// the daemon calls this rarely (per connection).
    static var string: String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        // Reject a group/other-writable file — another (non-root) account could
        // otherwise plant a permissive requirement and be accepted.
        if let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value,
           (perms & 0o022) != 0 {
            return nil
        }
        // Must be owned by ROOT (uid 0). The daemon runs as root under the system
        // LaunchDaemon; the requirement it trusts must be root-owned, so no
        // unprivileged user can rewrite it.
        if let owner = attrs[.ownerAccountID] as? NSNumber,
           owner.uint32Value != 0 {
            return nil
        }
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let req = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return req.isEmpty ? nil : req
    }

    #else

    /// Production Mode-A build (or any build without the self-hosted flag): the
    /// self-hosted override does not exist. Always nil; no file is ever read.
    static let string: String? = nil

    #endif
}
