// XPCServer — the root daemon's authenticated IPC listener.
//
// SRAA §3 caller authentication: we validate the connecting peer's AUDIT TOKEN
// and its CODE-SIGNING REQUIREMENT (Team Identifier + designated requirement) —
// NOT its UID, and NOT SO_PEERCRED (which is Linux and does not exist on macOS).
//
// Two layers:
//   1. xpc_connection_set_peer_code_signing_requirement() — the kernel rejects a
//      peer whose code signature does not satisfy the requirement string, before
//      any message is delivered (the modern, preferred gate; macOS 12+/13+).
//   2. Defence in depth: on each message we also copy the peer's audit_token and
//      run SecCodeCheckValidity against the same requirement, so a bug in (1) or
//      an older OS still fails closed.
//
// Uses the C libxpc API (available under the CLT toolchain) rather than the
// NSXPCConnection/Foundation object graph, so the audit_token path is explicit.

import Foundation
import BltusbProtocol
import os
#if canImport(XPC)
@preconcurrency import XPC
#endif

// The Mach service name the client connects to (matches the LaunchDaemon plist
// / SMAppService registration in ServiceManagement.swift).
public let kHelperMachServiceName = "co.carryai.bltusb.helperd"

// The deploy-time code-signing requirement the peer MUST satisfy.
// TODO(signing/deploy): replace <TEAMID> with the real Apple Developer Team ID
// and pin the client's designated requirement. Without an enrolled Developer ID
// this string cannot be finalised; the daemon refuses ALL peers until it is set
// (fail closed) — see `requirementIsConfigured`.
public let kPeerCodeSigningRequirement =
    "anchor apple generic and identifier \"co.carryai.bltusb\" " +
    "and certificate leaf[subject.OU] = \"<TEAMID>\""

private let log = Logger(subsystem: "co.carryai.bltusb.helperd", category: "xpc")

public final class XPCServer: @unchecked Sendable {
    private let guards: DeviceGuards
    private let policyAllowsRW: Bool

    public init(probe: SystemProbe, policyAllowsRW: Bool = false) {
        self.guards = DeviceGuards(probe: probe)
        self.policyAllowsRW = policyAllowsRW
    }

    /// True only once the requirement has been filled in with a real Team ID.
    /// Until then we refuse every caller (fail closed) rather than accept an
    /// unauthenticated peer.
    static var requirementIsConfigured: Bool {
        !kPeerCodeSigningRequirement.contains("<TEAMID>")
    }

    /// Start listening on the Mach service. This is the process entry point of
    /// the root daemon.
    public func run() {
        #if canImport(XPC)
        let listener = xpc_connection_create_mach_service(
            kHelperMachServiceName, nil,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))

        xpc_connection_set_event_handler(listener) { [weak self] peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            self?.configureAndAccept(peer)
        }
        xpc_connection_resume(listener)
        log.info("bltusb-helperd listening on \(kHelperMachServiceName, privacy: .public)")
        dispatchMain()
        #else
        log.error("XPC unavailable on this platform")
        #endif
    }

    #if canImport(XPC)
    private func configureAndAccept(_ peer: xpc_connection_t) {
        // Layer 1: kernel-enforced peer code-signing requirement.
        // TODO(signing/deploy): this is a no-op guard until the requirement has a
        // real Team ID. We still install it; and we hard-refuse below if not.
        if XPCServer.requirementIsConfigured {
            _ = xpc_connection_set_peer_code_signing_requirement(peer, kPeerCodeSigningRequirement)
        }

        xpc_connection_set_event_handler(peer) { [weak self] msg in
            guard let self else { return }
            guard xpc_get_type(msg) == XPC_TYPE_DICTIONARY else { return }

            // Fail closed if we have no configured requirement to authenticate against.
            guard XPCServer.requirementIsConfigured else {
                self.reply(to: peer, message: msg, error: .notAuthorized)
                return
            }
            // Layer 2: audit_token + SecCodeCheckValidity defence in depth.
            guard PeerAuth.isAuthorized(peer) else {
                self.reply(to: peer, message: msg, error: .notAuthorized)
                return
            }
            self.handle(msg, on: peer)
        }
        xpc_connection_resume(peer)
    }

    private func handle(_ msg: xpc_object_t, on peer: xpc_connection_t) {
        guard let opRaw = XPCCodec.string(msg, "op"),
              let op = HelperOp(rawValue: opRaw) else {
            reply(to: peer, message: msg, error: .internalError); return
        }

        switch op {
        case .listExternal:
            let rows = guards.probe.externalPartitionRows()
            reply(to: peer, message: msg, partitions: rows)

        case .probeExternal:
            guard let raw = XPCCodec.string(msg, "device_id"),
                  let dev = Validators.canonicalDeviceID(raw) else {
                reply(to: peer, message: msg, error: .invalidDeviceID); return
            }
            switch guards.admit(deviceID: dev, requireMountable: false) {
            case .failure(let e): reply(to: peer, message: msg, error: e)
            case .success(let fs):
                let info = guards.probe.diskInfo(deviceID: dev)
                let result = ProbeResult(deviceID: dev, fsType: fs,
                                         label: info.label,
                                         locked: fs?.isEncrypted ?? false)
                reply(to: peer, message: msg, probe: result)
            }

        case .mountExternal:
            handleMount(msg, on: peer)

        case .unmountExternal:
            guard let mp = XPCCodec.string(msg, "mountpoint"),
                  Validators.isValidMountpoint(mp),
                  MountpointGuard.resolvedUnderVolumes(mp) else {
                reply(to: peer, message: msg, error: .invalidMountpoint); return
            }
            switch AnylinuxfsRunner.unmount(mountpoint: mp) {
            case .success: reply(to: peer, message: msg, mounted: mp)
            case .failure(let e): reply(to: peer, message: msg, error: e)
            }
        }
    }

    private func handleMount(_ msg: xpc_object_t, on peer: xpc_connection_t) {
        // 1. Validate every input server-side.
        guard let raw = XPCCodec.string(msg, "device_id"),
              let dev = Validators.canonicalDeviceID(raw) else {
            reply(to: peer, message: msg, error: .invalidDeviceID); return
        }
        guard let fsRaw = XPCCodec.string(msg, "fs_type"),
              let fs = Validators.fsType(from: fsRaw) else {
            reply(to: peer, message: msg, error: .invalidFSType); return
        }
        guard let mp = XPCCodec.string(msg, "mountpoint"),
              Validators.isValidMountpoint(mp),
              MountpointGuard.resolvedUnderVolumes(mp) else {
            reply(to: peer, message: msg, error: .invalidMountpoint); return
        }
        let mode: MountMode = (XPCCodec.string(msg, "mode") == "rw") ? .rw : .ro
        guard Validators.isModePermitted(mode, policyAllowsRW: policyAllowsRW) else {
            reply(to: peer, message: msg, error: .rwNotPermitted); return
        }

        // 2. Server-side device guards (external / not-EFI / strong id / fs).
        let admit = guards.admit(deviceID: dev, requireMountable: true)
        guard case .success(let classified) = admit else {
            if case .failure(let e) = admit { reply(to: peer, message: msg, error: e) }
            return
        }
        // The client-claimed fs_type must agree with what WE classified from the
        // raw sectors — never trust the claim (it only picks the option vector).
        guard let classified, classified == fs else {
            reply(to: peer, message: msg, error: .invalidFSType); return
        }

        // 3. Capture strong identity BEFORE any (slow) work, for TOCTOU reverify.
        guard let id0 = guards.strongDeviceIdentity(dev) else {
            reply(to: peer, message: msg, error: .weakDeviceIdentity); return
        }

        // 4. Extract the passphrase as a zeroable buffer (encrypted fs only).
        var secret: Secret?
        if fs.isEncrypted {
            guard let bytes = XPCCodec.data(msg, "passphrase"), !bytes.isEmpty else {
                reply(to: peer, message: msg, error: .missingPassphrase); return
            }
            secret = Secret(bytes)
        }

        // 5. Re-verify identity across the (possible) delay, then mount.
        if let e = guards.reverify(deviceID: dev, capturedIdentity: id0) {
            secret?.zero()
            reply(to: peer, message: msg, error: e); return
        }
        let result = AnylinuxfsRunner.mount(deviceID: dev, fsType: fs, mode: mode, secret: secret)
        // AnylinuxfsRunner zeroes the secret in its defer; ensure it regardless.
        secret?.zero()

        switch result {
        case .success: reply(to: peer, message: msg, mounted: mp)
        case .failure(let e): reply(to: peer, message: msg, error: e)
        }
    }

    // MARK: reply helpers

    private func reply(to peer: xpc_connection_t, message: xpc_object_t, error: HelperError) {
        log.error("op rejected: \(error.rawValue, privacy: .public)")  // code only, never inputs
        let r = xpc_dictionary_create_reply(message) ?? xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(r, "error", error.rawValue)
        xpc_connection_send_message(peer, r)
    }
    private func reply(to peer: xpc_connection_t, message: xpc_object_t, partitions: [ExternalPartition]) {
        let r = xpc_dictionary_create_reply(message) ?? xpc_dictionary_create(nil, nil, 0)
        let arr = xpc_array_create(nil, 0)
        for p in partitions {
            let d = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(d, "device_id", p.deviceID)
            xpc_dictionary_set_string(d, "size", p.sizeText)
            xpc_dictionary_set_string(d, "type", p.typeText)
            xpc_array_append_value(arr, d)
        }
        xpc_dictionary_set_value(r, "partitions", arr)
        xpc_connection_send_message(peer, r)
    }
    private func reply(to peer: xpc_connection_t, message: xpc_object_t, probe: ProbeResult) {
        let r = xpc_dictionary_create_reply(message) ?? xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(r, "device_id", probe.deviceID)
        xpc_dictionary_set_string(r, "fs_type", probe.fsType?.rawValue ?? "")
        xpc_dictionary_set_string(r, "label", probe.label ?? "")
        xpc_dictionary_set_bool(r, "locked", probe.locked)
        xpc_connection_send_message(peer, r)
    }
    private func reply(to peer: xpc_connection_t, message: xpc_object_t, mounted: String) {
        let r = xpc_dictionary_create_reply(message) ?? xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(r, "mountpoint", mounted)
        xpc_connection_send_message(peer, r)
    }
    #endif
}

// MARK: - mountpoint realpath guard (symlink defence)

enum MountpointGuard {
    /// After the syntactic check, resolve symlinks and re-assert the /Volumes/
    /// prefix, so a symlinked `/Volumes/x -> /etc` cannot redirect the mount.
    static func resolvedUnderVolumes(_ mountpoint: String) -> Bool {
        let resolved = URL(fileURLWithPath: mountpoint).resolvingSymlinksInPath().path
        // The mountpoint may not exist yet (mount target) — only reject if it
        // resolves to something OUTSIDE /Volumes/.
        return resolved == mountpoint || resolved.hasPrefix("/Volumes/")
    }
}
