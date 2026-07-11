# bltusb Phase-2 helper — Deployment Modes (A vs B)

> The Phase-2 privileged helper (`bltusb-helperd`) can be deployed two ways. Both
> give the unprivileged user **zero-sudo at runtime**; they differ in the trust
> anchor for caller-authentication and in whether the artifact is distributable.
>
> Read alongside: [`PHASE2-HELPER-PLAN.md`](PHASE2-HELPER-PLAN.md) (architecture),
> [`AUTO-UNLOCK-RISK.md`](AUTO-UNLOCK-RISK.md) (residual risks), and
> [`SRAA-ASSESSMENT.md`](SRAA-ASSESSMENT.md) (full assessment, §3/§5/§8).

## 中文速览

同一个 root XPC helper,两种部署方式,运行期都**零 sudo**:
- **Mode A(有付费 Apple 开发者账号)**:Developer-ID 签名 + 公证 + Hardened Runtime,用 **Team ID** 钉住调用者身份,SMAppService/MDM 上线。产物**可分发、过 Gatekeeper、可 MDM 批量部署**。这是生产形态,但需要账号 + Xcode + MDM,**本机无法测**。
- **Mode B(个人自托管,无开发者账号)**:像 `cloudflared service install`。一次性 `sudo` 安装器把 helper 装成 **root 系统 LaunchDaemon**,之后普通用户零 sudo 调用。因为 ad-hoc 签名**没有 Team ID**,改用**客户端 cdhash 钉定**做调用者认证;pin 写在一个 **root 拥有、非世界可写**的 `peer-requirement.txt` 里,daemon 只在文件确实 root 拥有且不可被普通用户改写时才采信(否则 fail closed)。**关键不变量**:装进去的 helper 二进制和 plist 都是 **root 拥有、普通用户不可写**——这正是它**不是**被删掉的 `--nopasswd` 后门的原因。仅限个人机。

---

## 1. The two modes at a glance

| | **Mode A — Developer account** | **Mode B — personal self-hosted** |
|---|---|---|
| Analogy | signed, notarized, MDM-pushed product | `cloudflared service install` |
| Needs | Apple Developer Program (paid), full Xcode, MDM | just `sudo` on the machine once |
| Signing | Developer-ID Application + **notarized** + Hardened Runtime | **ad-hoc** (`codesign -s -`), Hardened Runtime |
| Caller-auth anchor | **Team ID** (`certificate leaf[subject.OU]`) | **client cdhash pin** (ad-hoc has no Team ID) |
| Requirement source | `kPeerCodeSigningRequirement` (real Team ID baked in) | root-owned `peer-requirement.txt` (`identifier … and cdhash H"…"`) |
| Daemon lifecycle | `SMAppService` LaunchDaemon (MDM auto-approve) | system LaunchDaemon via `launchctl bootstrap system` |
| Backend (`anylinuxfs`) | hardened, root-owned, MDM-installed, sig+hash verified | user-installed Homebrew `/opt/homebrew/bin/anylinuxfs` (fixed path) |
| Distributable? | **Yes** — Gatekeeper-happy, MDM-deployable, multi-machine | **No** — personal-machine-only (cdhash is per-build/per-machine) |
| Compile flag | none (default build) | `-D BLTUSB_SELFHOSTED` |
| Install script | `scripts/setup-devaccount.sh` (scaffold) | `scripts/install-selfhosted.sh` |
| Runtime sudo | **zero** | **zero** (only the one-time install needs sudo) |
| Testable here | **No** (needs account/Xcode/MDM) | **Yes** (build+sign now; sudo install by maintainer) |

Both modes share the *entire* security core: the 4-op allowlist, full server-side
input revalidation, the device guards (external / !EFI / !whole-disk / strong-id /
TOCTOU reverify / fail-closed fs), ro-by-default policy, fixed anylinuxfs argv, and
the zeroable passphrase scoped to one child. Only the **caller-auth trust anchor**
and the **backend path/verification** differ.

---

## 2. Mode B security invariants (and why it is NOT the `--nopasswd` backdoor)

The removed `--nopasswd` sudoers path was a local-privilege-escalation **backdoor**
for one specific reason: it granted passwordless root to a **user-writable binary
path** — any process that could overwrite that path got root. Mode B is the
opposite by construction. Its invariants (all established by
`install-selfhosted.sh`, enforced at runtime by the daemon):

1. **Root-owned, non-user-writable binaries.** Daemon **and** client are installed
   `root:wheel`, mode `0755`, under `/Library/Application Support/bltusb/bin/` — a
   directory an unprivileged user cannot write. An attacker cannot swap the
   privileged binary, so there is no writable-path escalation. **This is the
   critical invariant.** (Contrast: `--nopasswd` pinned root to a *user-writable*
   path.)
2. **Root-owned LaunchDaemon plist.** `/Library/LaunchDaemons/co.carryai.bltusb.helperd.plist`
   is `root:wheel 0644` — a user cannot rewrite the daemon's `Program` or args.
   Logs go to `/dev/null` (no secret ever reaches a log).
3. **cdhash-pinned caller-auth, fail-closed.** The daemon accepts **only** the one
   installed client, pinned by `identifier "…" and cdhash H"…"`. The pin lives in
   a **root-owned, non-world-writable** `peer-requirement.txt`; the daemon
   (`SelfHostedRequirement.swift`) **ignores** that file unless it is owned by uid 0
   and not group/other-writable — so no unprivileged user can plant a permissive
   requirement. If the file is missing/mis-owned, the daemon has **no requirement**
   and **refuses every caller** (fail closed), exactly like an unconfigured Mode A.
4. **4-operation allowlist, unchanged.** Only `list / probe / mount / unmount`
   exist; no arbitrary-argv, no `anylinuxfs shell`/exec path is constructible.
5. **Read-only by default.** `policyAllowsRW=false`; `rw` is policy-gated and off.
6. **Passphrase hygiene, unchanged.** Delivered as zeroable XPC `data`, scoped to
   one child's `ALFS_PASSPHRASE`, zeroed after — never argv/log/temp/plist.
7. **Root-owned BACKEND, enforced fail-closed.** The daemon runs `anylinuxfs` **as
   root**, so root-owning our *own* binaries (invariant 1) is necessary but **not
   sufficient**: if the backend it executes is user-writable, an attacker swaps
   the backend and the legit client triggers a root exec of attacker bytes — the
   *same* escalation as `--nopasswd`. So `verifiedBackendPath()` requires the
   resolved backend **and every ancestor directory** to be uid-0-owned and not
   group/other-writable, and **fails closed** otherwise.

> ⚠️ **Mode B `mount` is not operational on a stock backend — by design.** A
> Homebrew `anylinuxfs` is **user-owned** (Cellar) and boots a **user-writable
> `~/.anylinuxfs` rootfs**, so `verifiedBackendPath()` **fails closed** and the
> daemon **refuses to mount**. This is deliberate: it is safer to refuse than to
> run a user-mutable backend as root. Making Mode B `mount` actually work
> **safely** requires staging the **entire** anylinuxfs trust chain (binary +
> rootfs + microVM deps) **root-owned and non-user-writable, verified before
> exec** — the Phase-2 supply-chain hardening (SRAA §5 S1–S3 / §9 Alt-A), **not
> yet automated**. Until then Mode B delivers the proven **zero-sudo IPC + caller
> auth** (`list`/`probe`), and `mount` is gated. Root-owning only our launcher/
> client while executing a user-writable backend would be a **local
> privilege-escalation boundary**, not merely a supply-chain residual — so we
> fail closed instead of shipping it.

So Mode B is a **standing root service with an authenticated front door and
root-owned code** — but its *mount* capability is deliberately **gated on a
fully root-owned backend chain**. The privilege is mediated by the 4-op allowlist
+ full server-side guards; the client cannot ask for anything the guards don't
independently re-authorize; and the daemon will not exec a backend it cannot
prove is root-owned.

### One-time Full Disk Access grant (required for MOUNTING)

Verified by running Mode B end-to-end: **install + the zero-sudo IPC + caller-auth
work immediately** (`list`/`probe` of metadata need no TCC). But **mounting needs
Full Disk Access granted to the daemon** — macOS TCC restricts raw disk-device
reads (`/dev/rdiskNsM`) even for a *root* LaunchDaemon. Without FDA the daemon
cannot read the boot sector, cannot derive a strong device identity, and **fails
closed** with `weakDeviceIdentity` (safe: it refuses to hand an unidentifiable
device to the parser). Grant it once:

```
System Settings ▸ Privacy & Security ▸ Full Disk Access ▸ [+]
  add:  /Library/Application Support/bltusb/bin/bltusb-helperd
then: sudo launchctl kickstart -k system/co.carryai.bltusb.helperd
```

This is the one manual step Mode B cannot script — a user-installed (non-MDM) PPPC
profile is **not** honored for TCC. **Mode A/MDM auto-grants FDA via a PPPC
profile** (`com.apple.TCC`), which is a large part of what the paid/managed path
buys you: zero manual TCC. Mode B trades that one click for $0.

### The cdhash re-pin-on-update requirement

Because Mode B pins the client by **cdhash**, and a rebuild produces a **new**
cdhash, the pin is only valid for the exact installed binary. **Every time you
rebuild or update the client (or daemon), you MUST re-run `install-selfhosted.sh`**
so it re-signs the installed copy and re-writes `peer-requirement.txt` with the new
cdhash. If you replace the client binary without re-pinning, the daemon will
(correctly) reject it as `notAuthorized`. This is a feature: an unpinned binary is
never accepted. (Mode A does not have this problem — the Team ID is stable across
builds, so no re-pin is needed on update.)

---

## 3. How the two modes stay isolated in code (Mode A is never weakened)

The Mode-B path is gated so it is **unreachable** in a real Mode-A build:

- `XPCServer.effectiveRequirement` returns the production `kPeerCodeSigningRequirement`
  **whenever a real Team ID is baked in** (`requirementIsConfigured == true`). Only
  while the string still contains the `<TEAMID>` placeholder does it consult the
  overrides — first `DevRequirement` (dev flag, per-user file), then
  `SelfHostedRequirement` (Mode B, root-owned file). The instant a Team ID is
  present, **both overrides are dead code at runtime**, even if their compile flags
  were (mistakenly) on.
- `SelfHostedRequirement.string` is a hard-coded `nil` unless compiled with
  `-D BLTUSB_SELFHOSTED`; a default (Mode A) build reads no file.
- `AnylinuxfsRunner.binaryPath` is the Homebrew path **only** under
  `-D BLTUSB_SELFHOSTED`; the default build keeps the hardened MDM path and the
  (stubbed) Developer-ID `verifiedBackendPath()`.

Net: a Team-ID Mode-A daemon authenticates against the Team ID and execs the
hardened backend — byte-for-byte unaffected by the Mode-B additions.

---

## 4. What each mode needs (checklist)

**Mode B (personal):**
- macOS 13+, the Command Line Tools Swift toolchain (no Xcode needed).
- Homebrew `anylinuxfs` installed at `/opt/homebrew/bin/anylinuxfs`.
- One `sudo` to run `install-selfhosted.sh`. Nothing else for the zero-sudo IPC.
- ⚠️ **`mount` is fail-closed until you stage a root-owned backend.** `list`/`probe`
  work now, but the daemon **refuses to `mount`** with a stock Homebrew backend:
  `verifiedBackendPath()` resolves the symlink and requires the canonical backend
  **and every ancestor directory** to be uid-0-owned and not group/other-writable,
  execing **only** that verified canonical path (never the user-controlled symlink).
  A Homebrew `anylinuxfs` is **user-owned** (Cellar) with a **user-writable
  `~/.anylinuxfs` rootfs**, so it fails the check — running it as root would be a
  **local privilege-escalation boundary** (R-supply / S3), so we do not. Making
  Mode B `mount` work **safely** needs the **entire** anylinuxfs trust chain
  (binary + rootfs + microVM deps) staged **root-owned, non-user-writable, verified
  before exec** — the Phase-2 supply-chain hardening (SRAA §5 S1–S3 / §9 Alt-A),
  **not yet automated**. See §2 and [`AUTO-UNLOCK-RISK.md`](AUTO-UNLOCK-RISK.md) §4.

**Mode A (organization / distributable):**
- Apple Developer Program membership (paid), full Xcode (~15–40 GB), an MDM.
- Developer-ID signing + notarization + Hardened Runtime; real Team ID baked into
  `kPeerCodeSigningRequirement`.
- SMAppService registration + `com.apple.servicemanagement` and PPPC (Full Disk
  Access + Automation) MDM profiles.
- The hardened, self-built, root-owned, read-only anylinuxfs rootfs (SRAA §5/§9)
  before the daemon is allowed to exec the backend in production.
- Run `scripts/setup-devaccount.sh` for a guided pre-flight; it detects what is
  present and instructs on the rest (it never hard-fails on a bare machine).

---

## 5. Where this sits vs the SRAA gates

Neither mode overrides the **SRAA §8 pivotal go/no-go** (is a third-party root
microVM with a custom unaudited kernel acceptable in principle?) or the anylinuxfs
supply-chain hardening gate (§5). Both modes improve the *front door* (zero-sudo,
authenticated caller, full server-side validation, root-owned code); the residuals
R1–R4 / R-parse / R-kernel are **unchanged**. Mode A is the path toward closing the
supply-chain gate (hardened backend + notarized helper); Mode B explicitly accepts
the personal-machine residuals and is **not** authorized for organizational or
sensitive-data use — see [`AUTO-UNLOCK-RISK.md`](AUTO-UNLOCK-RISK.md) §6–§7.
