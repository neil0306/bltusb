# bltusb Phase‑2 — Signed Privileged Helper (`bltusb-helperd`) Execution Plan

> Status: **Design + compiling skeleton** · Target: SRAA §3 production posture (zero‑sudo, MDM‑deployable) · Basis: `SRAA-ASSESSMENT.md` §3/§5/§6/§7/§11/§13 and `AUTO-UNLOCK-RISK.md`.
>
> **This plan and the accompanying `helper/` SwiftPM skeleton are engineering
> scaffolding, not an authorization.** The end‑to‑end signed+notarized+MDM
> deployment is **blocked** on an Apple Developer Program membership, Xcode, and
> an MDM — none of which are available in the build environment. Every such
> dependency is called out below and marked `// TODO(signing/deploy)` in the code.
> Nothing in here overrides the §8 pivotal go/no‑go decision or the anylinuxfs
> supply‑chain hardening gate; those still gate any real rollout.

---

## 0. 中文速览

Phase‑2 = 用一个**签名的原生 XPC helper**(`bltusb-helperd`,root,SMAppService 部署)替换现在的 `sudo anylinuxfs` bash 路径,让普通用户**零 sudo、零交互授权**就能只读挂载外接加密盘。helper 只暴露**四个操作**(list / probe / mount / unmount),**服务端**重新校验一切、重跑所有设备守卫(外接分区 / 非 EFI / 非整盘 / 强身份 / TOCTOU 复核),只用**固定参数向量**调用一个 root 拥有、MDM 安装、哈希校验的 anylinuxfs,密码走**可清零缓冲区**、用完立即清零。调用者身份用 **XPC audit_token + 代码签名要求(Team ID)** 验证——**不是 UID,不是 SO_PEERCRED(那是 Linux)**。审计走 **Unified Logging + EndpointSecurity**(不是已废弃的 OpenBSM)。**能现在编译验证的**:整个协议、校验器、设备守卫逻辑、XPC 服务器/客户端骨架、SMAppService 注册代码(`swift build` 干净通过,33 个单元测试全过)。**必须由维护者用 Apple 开发者账号 / Xcode / MDM 才能做完的**:Developer ID 签名 + 公证 + Hardened Runtime、真正的 SMAppService 上线、PPPC(完全磁盘访问 + 自动化)描述文件、EndpointSecurity entitlement、以及 anylinuxfs 供应链加固。

---

## 1. Component layout

Three‑layer privilege separation (SRAA §3). Only the daemon is root; everything
the user touches is unprivileged.

```
================= TRUST BOUNDARY (root) =====================
  bltusb-helperd            signed native daemon, SMAppService LaunchDaemon,
                            MDM-deployed, Full Disk Access via PPPC
    · XPC listener          validates peer audit_token + code-signing requirement
    · request validator     4-op allowlist; regex/allowlist/realpath on every input
    · device guards         re-run server-side: external / !EFI / !whole-disk /
                            strong-identity / TOCTOU reverify / fail-closed fs
    · operation executor    FIXED anylinuxfs mount/unmount argv only
    · audit                 os_log (public metadata) + EndpointSecurity → SIEM
============================================================
                         ^  authenticated local XPC
                         |  (passphrase as zeroable data, never argv/env/log)
------------------- UNPRIVILEGED (user) --------------------
  bltusb (bash CLI)         bltusb-agent (per-user LaunchAgent)
    · Keychain / dialogs      · DiskArbitration insert events
    · shells bltusb-client    · native password dialog (osascript)
  BltusbClientLib (Swift)   per-user Keychain (…WhenUnlockedThisDeviceOnly)
============================================================
```

**Where the code lives (this repo):** a self‑contained SwiftPM package at
`helper/` (does **not** touch the existing bash `bltusb`, tests, or release
machinery). Targets:

| Path | Target | Kind | Privilege |
|---|---|---|---|
| `helper/Sources/BltusbProtocol/` | `BltusbProtocol` | library | pure (no caps) — the 4‑op contract + validators + `BootSector` classifier + `DeviceGuards`/`SystemProbe` |
| `helper/Sources/CXPCShim/` | `CXPCShim` | C target | vends the `xpc_connection_get_audit_token` SPI (not in the public Swift `XPC` module) |
| `helper/Sources/bltusb-helperd/` | `bltusb-helperd` | executable | **root** — XPC server, `RealSystemProbe`, `AnylinuxfsRunner`, `PeerAuth`, `AuditLog`, `ServiceManagement` |
| `helper/Sources/BltusbClientLib/` | `BltusbClientLib` | library | user — `HelperClient` |
| `helper/Sources/bltusb-client/` | `bltusb-client` | executable | user — thin CLI the bash tool shells out to |
| `helper/Tests/BltusbProtocolTests/` | tests | swift‑testing | validators + guards + classifier |

The **per‑user insert‑trigger agent** stays the existing bash LaunchAgent
(`bltusb autounlock`) in the near term, re‑pointed to call `bltusb-client mount`
instead of `sudo anylinuxfs mount`; it can later be re‑implemented natively as a
DiskArbitration agent, but that is not required for Phase‑2 correctness.

---

## 2. The XPC protocol — EXACTLY four operations

`BltusbProtocol` defines the entire attack surface. There is **no** passthrough
of arbitrary anylinuxfs subcommands, options, env, paths, rootfs, or config.

| op | validated inputs | reply | mirrors bash |
|---|---|---|---|
| `list-external` | — | `[ExternalPartition]` | `list_partition_rows` |
| `probe-external` | `device_id` `^disk\d+s\d+$` | `ProbeResult{fsType?,label,locked}` | `fstype` + `device_identity` |
| `mount-external` | `device_id`, `fs_type ∈ {bitlocker,luks,ntfs,exfat,ext,fat}`, `mountpoint ∈ /Volumes/…`, `mode ∈ {ro(default),rw}`, **passphrase as zeroable data** | `MountResult{mountpoint}` | `perform_mount` / `run_mount` |
| `unmount-external` | `mountpoint ∈ /Volumes/…` | ok/err | `cmd_umount` |

Input validation (all server‑side, in `Validators`):
- **device id** — a hand‑rolled `^disk\d+s\d+$` matcher; rejects whole disks
  (`diskN`), raw aliases (`rdiskNsM`), `/dev/` prefixes, and any trailing garbage
  or shell metacharacters. `canonicalDeviceID` first strips an accidental
  `/dev/`+`r` (mirrors bash `canonical_device`) then re‑validates.
- **fs_type** — enum allowlist; the client‑claimed type only **selects the option
  vector** and is then **required to equal what the daemon itself classified**
  from the raw boot sector (never trusted).
- **mountpoint** — must be `/Volumes/<single component>`; rejects `..`, nested
  paths, NUL, control/ANSI‑escape bytes; then `realpath`‑resolved and re‑checked
  against the `/Volumes/` prefix (symlink defence, `MountpointGuard`).
- **mode** — `ro` default; `rw` is policy‑gated (`isModePermitted(_,policyAllowsRW:)`)
  and **disabled by default** (SRAA §6.6). The client cannot enable it.

### "The helper must NEVER" — hard invariants (verbatim from SRAA §3)

Encoded as structural properties of the code, not runtime hopes:

1. **Never forward arbitrary anylinuxfs subcommands.** Only `HelperOp`'s four
   cases exist; the executor builds argv **only** via `Validators.anylinuxfs{Mount,Unmount}Argv`.
2. **Never invoke `anylinuxfs shell`/exec/format**, or accept any arg containing
   `shell`/`exec`/`-c`. There is no code path that constructs those tokens — the
   only verbs emitted are the literals `"mount"` and `"unmount"`.
3. **Never touch internal/system disks, EFI, whole disks, or `/dev/rdisk*`.**
   `DeviceGuards.admit` rejects `notExternalPartition`, `isEFI`,
   `weakDeviceIdentity`; the device‑id regex rejects whole‑disk/raw forms.
4. **Never put the passphrase in argv/env/logs/temp.** It arrives as XPC `data`
   (not a Codable string), is wrapped in a zeroable `Secret`, scoped to a single
   child's environment for the one mount, and zeroed immediately after. os_log
   records op/device/error **codes** only.
5. **Never trust the caller's UID claim.** `PeerAuth` validates the connection's
   **audit_token** + **code‑signing requirement** (see §3). `SO_PEERCRED` is
   Linux‑only and is not used.
6. **Never load or `dlopen` a client‑supplied path.** The backend path is a fixed
   root‑owned constant; no client value ever reaches a path/dlopen.
7. **Never trust client‑side checks or UI state.** The daemon owns all policy and
   re‑runs every guard server‑side; the client's validation is a courtesy only.

---

## 3. Caller authentication (macOS‑correct)

**Validate the XPC connection's `audit_token` + code‑signing requirement — NOT
UID, NOT `SO_PEERCRED`** (SRAA §3, §13.1 M‑03: `SO_PEERCRED` is Linux). Two layers:

1. **Kernel‑enforced, pre‑delivery:** `xpc_connection_set_peer_code_signing_requirement(peer, req)`
   — the kernel refuses to deliver a message from a peer whose signature does not
   satisfy `req` (the pinned Team ID + designated requirement). (`XPCServer.configureAndAccept`.)
2. **Defence in depth, per message:** copy the peer's audit token
   (`xpc_connection_get_audit_token`, via `CXPCShim`), build a `SecCode` bound to
   exactly that audited process (`SecCodeCopyGuestWithAttributes` with
   `kSecGuestAttributeAudit` — audit‑token‑bound, so not pid‑reuse spoofable),
   then `SecCodeCheckValidity(code, SecRequirement)` against the same requirement.
   (`PeerAuth.isAuthorized`.)

**Fail closed:** until the requirement string has a real Team ID
(`kPeerCodeSigningRequirement` still contains `<TEAMID>`), `XPCServer` **refuses
every caller** rather than accept an unauthenticated peer.

> `// TODO(signing/deploy)`: the Team ID + client designated requirement can only
> be finalised once the client is signed with an enrolled Developer ID. Blocked
> on Apple Developer Program membership.

---

## 4. Passphrase handling — and the known env constraint

**Delivery:** the passphrase travels as XPC **`data`** (`xpc_dictionary_set_data`),
never as a Codable field or a string in the request struct, so it can never be
JSON‑encoded or logged. The daemon wraps it in a `Secret` (a zeroable `[UInt8]`),
and **both** the client (after send) and the daemon (in a `defer`) overwrite the
buffer with zeros. os_log never sees it.

**Known constraint (documented, not hidden — SRAA §6.5 residual):** anylinuxfs
today accepts the secret **only** via the `ALFS_PASSPHRASE` environment variable
— it exposes **no stdin/fd channel**. So even done perfectly:

- We scope `ALFS_PASSPHRASE` to **exactly one child process** (never an exported
  global, never the daemon's own environment).
- We zero our own buffer immediately after spawning.
- **Residual:** for the brief lifetime of that one mount child, an env‑aware
  reader on the same machine (`ps -E`, reading the child's `environ`) can observe
  it. This is the same residual the bash tool documents.

**The real fix is upstream:** push anylinuxfs to accept the passphrase over an fd
(e.g. `--passphrase-fd N` or stdin), then the helper passes a pipe fd and the
secret never enters any process environment. Until then, the env‑scoped‑to‑one‑child
approach is the wrapper, and the residual is accepted and recorded. (`AnylinuxfsRunner.mount`.)

---

## 5. Supply‑chain hardening the helper OWNS (SRAA §5/§6)

The helper only calls anylinuxfs; it does not build it. But Phase‑2 makes the
**helper responsible** for these being true before it will exec the backend:

- **Root‑owned, non‑user‑writable, MDM‑installed backend** at a **fixed absolute
  path** — `AnylinuxfsRunner.binaryPath` = `/Library/Application Support/bltusb/anylinuxfs/bin/anylinuxfs`
  (never `$PATH`‑resolved, never `~/.anylinuxfs`). This directly fixes **S3** (the
  current user‑writable `~/.anylinuxfs` rootfs — a root helper booting from a
  user‑writable path is a trust violation).
- **Pinned Alpine digest + hashed dependencies + read‑only rootfs** (S1, S2, S7):
  the image is `alpine@sha256:<digest>` from an internal registry; libkrunfw /
  gvproxy / vmnet‑helper are pinned‑hash, vendored artifacts; the rootfs is a
  fixed‑SHA squashfs mounted read‑only with a tmpfs overlay.
- **Integrity verified before every exec** — `AnylinuxfsRunner.verifyBackendIntegrity`
  is the hook: `SecStaticCode` + `SecCodeCheckValidity` against the backend's
  pinned designated requirement, plus a sha256 match of the rootfs image.
- **Blocked guest egress** — offline apk pre‑seed + PF/host‑only vmnet so the
  guest has no outbound network in production.
- **Arbitrary‑root‑exec subcommand unreachable** — `anylinuxfs shell`/exec is
  never constructed (invariant #2, §2).

> **Current reality (must move before authorization):** as shipped via Homebrew,
> anylinuxfs is **ad‑hoc signed** (no stable Team Identifier to pin) and its
> rootfs lives in **user‑writable `~/.anylinuxfs`**. Both are **blockers** —
> `verifyBackendIntegrity` and `binaryPath` are written as the target state, but
> they only become real after the **self‑built, signed, root‑owned rootfs
> (Alt‑A)** work in SRAA §5/§9. `// TODO(signing/deploy)`.

---

## 6. Auditing

Unified Logging (`os_log`) + an **EndpointSecurity** client — **NOT** OpenBSM/auditd
(deprecated on current macOS; SRAA §11, §13.1 M‑02).

- `AuditLog` (os_log, subsystem `co.carryai.bltusb.helperd`): mount/unmount events
  and every rejection, as **public metadata only** (op, device id, fs, mode,
  mountpoint, error code) — **never** the passphrase, never raw media bytes/labels.
- `EndpointSecurityClient` subscribes to `ES_EVENT_TYPE_NOTIFY_MOUNT` /
  `…_UNMOUNT` and forwards to SIEM.

> `// TODO(signing/deploy)`: a real ES client needs the
> `com.apple.developer.endpoint-security.client` entitlement (Apple‑approved) +
> a signed, notarized, root binary. It cannot even `es_new_client()` without the
> entitlement, so it is stubbed; the os_log sink is the compiling audit path.

---

## 7. Deployment

- **SMAppService LaunchDaemon** registration (`DaemonRegistration`,
  `SMAppService.daemon(plistName:)` register/unregister/status). No manual
  `/Library/LaunchDaemons` plist, no `sudo launchctl`. **No kext** (anylinuxfs is
  a microVM + NFS design — removes the single largest SRAA scheduling variable).
- **MDM PPPC** profile grants the daemon **Full Disk Access** (raw device reads)
  and the agent **Automation** (osascript dialog) non‑interactively.
- **`com.apple.servicemanagement`** MDM profile (TeamIdentifier rule)
  auto‑approves the background items → **zero user action, zero sudo**.

> `// TODO(signing/deploy)`: `SMAppService.register()` succeeds **only** when the
> daemon is inside a Developer‑ID‑signed, notarized app bundle with a matching
> `Contents/Library/LaunchDaemons/*.plist`, and the servicemanagement/PPPC
> profiles are pushed by MDM. Under the CLT‑only build there is no bundle and no
> signing identity; `register()` returns `requiresApproval`/throws and we surface
> that honestly (observed: `--status` → `status=3` = notRegistered).

---

## 8. Build / sign / test reality + BLOCKERS

**Compiles and is verified NOW** (Swift 6.3.3 CLT, no Xcode, no signing):

- `BltusbProtocol` — the 4‑op contract, all input validators, the `BootSector`
  filesystem classifier (native re‑impl of bash `fstype`), and `DeviceGuards` +
  the `SystemProbe` abstraction.
- `bltusb-helperd` — the XPC listener, peer auth wiring (audit_token + SecCode),
  `RealSystemProbe`, `AnylinuxfsRunner` (fixed argv + zeroable secret),
  `AuditLog`, `ServiceManagement`. Runs read‑only via `--self-check`.
- `BltusbClientLib` + `bltusb-client` — connect / send a validated request /
  handle the typed reply; passphrase on stdin, never argv.
- **33 unit tests** (swift‑testing) covering device‑id regex, fs‑type allowlist,
  mountpoint validation, mode policy, fixed‑argv construction, boot‑sector
  classification, and all device‑guard branches (external / EFI / whole‑disk /
  strong‑identity / fail‑closed‑fs / TOCTOU device‑swap).

**Observed (this environment):**

```
$ swift build          # from a clean .build
Build complete! (0 warnings)

$ swift test  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
              -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
              -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
✔ Test run with 33 tests in 3 suites passed after 0.009 seconds.
```

> **Test note:** the CLT‑only toolchain ships `Testing.framework` but does **not**
> ship `XCTest`, and `swift test` does not auto‑wire the Testing framework's
> runtime search paths. The three `-Xswiftc/-Xlinker` flags above supply the
> framework search path + rpaths so the test bundle loads. On a machine with full
> Xcode, a bare `swift test` works. These flags are **not** baked into
> `Package.swift` (hardcoding CLT‑absolute paths would break on an Xcode host).

**BLOCKED on the maintainer providing (cannot be done here):**

| Blocker | Needs | Gates |
|---|---|---|
| Developer ID signing + notarization + Hardened Runtime | Apple Developer Program membership + Xcode notarytool | §3 requirement finalisation; §7 SMAppService; §5 backend signature |
| Real `SMAppService` registration | signed+notarized app bundle + MDM `com.apple.servicemanagement` profile | zero‑sudo deployment |
| PPPC (Full Disk Access + Automation) | MDM PPPC profile | non‑interactive raw device access |
| EndpointSecurity audit | `com.apple.developer.endpoint-security.client` entitlement (Apple approval) | §6 SIEM audit |
| Hardened/self‑built anylinuxfs (Alt‑A) | rootfs build + internal registry + signing | §5 S1‑S3/S7; `verifyBackendIntegrity` |

Every one of these is marked `// TODO(signing/deploy)` in the code and is
written so the surrounding code still compiles without it.

---

## 9. Phasing (build order)

1. **Contract + validators + guards** *(done, compiles + tested here).* The pure,
   security‑critical logic — the part worth reviewing first and hardest.
2. **XPC server + client wiring** *(skeleton compiles here).* Full peer‑auth and
   fixed‑argv executor, still fail‑closed without a Team ID.
3. **Signing bring‑up** *(blocked on Developer ID/Xcode).* Finalise the code‑sign
   requirement, notarize, produce the app bundle, wire `SMAppService.register()`.
4. **MDM profiles** *(blocked on MDM).* PPPC (FDA + Automation) + servicemanagement
   auto‑approve.
5. **anylinuxfs hardening (Alt‑A)** *(SRAA §5/§9 gate).* Self‑built signed root‑owned
   read‑only rootfs; wire `verifyBackendIntegrity`; block guest egress.
6. **EndpointSecurity + SIEM** *(blocked on entitlement).*
7. **Pilot + rollout** *(SRAA §10 Phase 3).*

> **Gates that dominate everything above:** the **SRAA §8 pivotal go/no‑go**
> ("is a third‑party root microVM with a custom unaudited kernel acceptable in
> principle, given R1–R4?") must be answered **before** the signing/MDM investment,
> and the **anylinuxfs supply‑chain hardening** (§5) must land before the helper
> is allowed to exec the backend in production. Steps 3–7 are wasted effort if §8
> is answered "no".

---

## 10. Not in scope for this deliverable

- No changes to the existing bash `bltusb`, its tests, or `scripts/release.sh`.
- No commit. No signing. No live SMAppService registration. No MDM profiles.
- The residual risks R1–R4 (SRAA §7) are **unchanged** by this work — a signed
  helper improves the *front door* (auth, validation, no‑sudo), not the
  microVM/kernel/parser residuals, which still require the §8 written acceptance.
