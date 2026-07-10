# Auto-Unlock — Security Risk Disclosure

> **Scope of this document.** bltusb is public, open-source software. This file
> **discloses** the security risks of the optional **auto-unlock** feature and
> lists **what the project has already done** to reduce them. It does **not**
> make a deployment decision for you. Whether auto-unlock is acceptable — and in
> an organization, whether it clears your Security Risk Assessment & Authorization
> (SRAA) — is **the deployer's decision**, and some residual risks require an
> **explicit, signed risk acceptance** from whoever owns that decision (see
> [§6](#6-if-you-deploy-this-in-an-organization-what-must-be-signed-off)).
>
> Full architectural assessment: [`SRAA-ASSESSMENT.md`](SRAA-ASSESSMENT.md).

## 中文速览

`bltusb autounlock` 让插入的 BitLocker/ext 盘**自动只读挂载**。它方便,但把一个本就有风险的操作(**以 root 解析攻击者能控制字节的文件系统**)变成了**插入即自动触发**。本文诚实列出:①这个功能的风险;②**我们已经做了哪些防护**;③**我们做不到、必须由部署方/上游承担**的部分;④为什么用 microVM 这个选择在安全上是可辩护的(隔离优于 kext,且风险 R4 在所有替代方案里都存在);⑤**若在组织内部署,IT/安全团队必须就什么签字**。**用不用是使用者的决定,我们只负责说清风险和已做的保护。**

---

## 1. What auto-unlock does

`bltusb autounlock install` sets up a **per-user LaunchAgent** (or, on a Homebrew
install, a `brew services` agent) that watches `diskutil activity`. When you
insert a volume macOS **cannot** mount itself (BitLocker, LUKS, ext*), it:

1. asks for the volume password via a native dialog (or uses a saved Keychain password),
2. obtains root via a **GUI admin-password prompt** (`SUDO_ASKPASS`) or a cached `sudo` timestamp, and
3. mounts the volume **read-only** through [anylinuxfs](https://github.com/nohajc/anylinuxfs) (a libkrun microVM + Alpine guest, re-exported to macOS over loopback NFS — **no macFUSE, no kernel extension**).

Plain volumes macOS already handles (exFAT/FAT read-write, NTFS read-only) are
**skipped** — auto-unlock never touches them.

## 2. The risk model — what makes auto-mount risky

| # | Risk | Nature |
|---|---|---|
| **R-parse** | **Mounting a volume runs a filesystem parser over attacker-controllable bytes, with privilege.** BitLocker/NTFS/ext parsing is a classic memory-corruption surface. | **Irreducible** — inherent to "mount untrusted media." Present in *every* solution (macOS's own drivers, macFUSE+ntfs-3g, Microsoft's driver…), not unique to this tool. |
| **R-insert** | Auto-unlock changes this from a **deliberate** `mount` command to **automatic invocation on insertion**. A hostile USB is parsed the moment it's plugged in, with no explicit user action. | Introduced by *this feature*; mitigated (see §3), not eliminated. |
| **R-kernel** | anylinuxfs runs a **custom-forked Linux kernel** (libkrunfw) with no independent security audit. | Residual — requires acceptance or a self-built/audited kernel. |
| **R-supply** | anylinuxfs (by default) pulls a mutable `latest` Alpine image and downloads dependency binaries without published checksums, and keeps its rootfs in **user-writable** `~/.anylinuxfs`. | Partly the deployer's/upstream's to fix (see §4/§5). |
| **R-privilege** | Any mount needs **root**. bltusb obtains it interactively (GUI admin prompt / `sudo`). It does **not** install a standing root component. | By design; the "no-sudo, IT-installs-once" model is **not** v1.4 — see §7. |

## 3. What we have done (protections already in bltusb)

These are implemented and covered by the test suite + independent audits
(auto-unlock converged over 3 adversarial audit rounds; the Homebrew delegation
over 4):

- **Read-only, always.** Auto-unlock mounts `-o ro` (ext gets `ro,norecovery`). It **never** auto-mounts read-write — the higher-risk write path stays a deliberate manual `bltusb rw` command.
- **Fail-closed selection.** Only external physical partitions classified as a known mountable filesystem are considered. **EFI, internal disks, whole disks, already-mounted volumes, and unknown/unrecognized filesystems are silently skipped** — no "mount anyway?" coercion on the automatic path.
- **Device-identity revalidation (TOCTOU).** The device's strong identity (Partition UUID or boot-sector fingerprint) is captured before the password dialog and **re-verified immediately before the mount**; a device swapped during the dialog is rejected.
- **Terminal-injection hardening.** Every backend/media-derived string (volume labels, device names) is stripped of control/bidi codepoints and escaped before it reaches a terminal or an AppleScript dialog, so a crafted volume label cannot inject ANSI/OSC escapes or AppleScript.
- **Secret hygiene.** The volume password and the admin password never touch argv, a logged command, a temp file, the LaunchAgent plist, or the askpass helper. The volume password flows only through a single scoped `ALFS_PASSPHRASE` environment for one mount; the admin password flows osascript→stdout→`sudo` only. Plist logs to `/dev/null`.
- **No root persistence.** The agent is a **per-user LaunchAgent**, not a root `LaunchDaemon`. The unsafe passwordless-`sudoers` option that earlier existed was **removed** — a `NOPASSWD` rule pinned to a user-writable binary path is a local privilege-escalation backdoor and must not ship.
- **Single-daemon enforcement.** Install deactivates any other mechanism (self ↔ brew) and *verifies* it; it refuses to start two daemons.
- **No kernel extension.** anylinuxfs is a microVM + NFS design, so there is **no macFUSE/kext** to approve and no lowering of macOS system-integrity settings.
- **Backend version awareness.** bltusb records the anylinuxfs version it was security-reviewed against (`ANYLINUXFS_PINNED_VERSION`) and **warns on a drifted backend** at install, so a silently-updated backend is surfaced.

## 4. What we cannot do (the boundary — honestly)

bltusb is a thin wrapper; it **calls** anylinuxfs, it does not build it. The
following belong to **anylinuxfs (upstream) or the deployer**, and bltusb
**cannot** perform them itself — do not assume they are done:

- **Pin the guest image digest / vendor dependency hashes.** The Alpine image tag, the libkrunfw kernel, `gvproxy`, `vmnet-helper`, etc. are fetched and assembled by anylinuxfs's own build. Pinning them to immutable, checksum-verified artifacts is an **anylinuxfs/deployer** task. (bltusb pins only the anylinuxfs *version* it trusts.)
- **Make the rootfs root-owned and immutable.** anylinuxfs stores its rootfs in **user-writable** `~/.anylinuxfs`. A privileged mount booting from a user-writable path is a trust violation; moving it to a root-owned, MDM-installed, hash-verified location is a **deployment/upstream** change.
- **Verify a Developer-ID signature of the backend.** As shipped via Homebrew, `anylinuxfs` is **ad-hoc signed** (no stable Team Identifier), so there is no code-signing identity to pin or verify.
- **Remove the residual parser-exploitation risk (R-parse) or audit the forked kernel (R-kernel).** These are not "bugs to fix" — they are architectural residuals that require a **written risk-acceptance decision**.

## 5. Why the microVM choice is defensible (comparative context)

This is context for whoever weighs the risk — not a claim that the risk is zero:

- **R-parse exists in every option.** Any way of reading an encrypted/foreign USB on macOS runs an unaudited parser over hostile bytes with privilege: macOS's own NTFS/exFAT drivers, macFUSE + ntfs-3g/dislocker, or a vendor driver. Replacing anylinuxfs does **not** remove R-parse.
- **VM isolation is an advantage, not just a cost.** anylinuxfs parses the hostile filesystem **inside a throwaway microVM guest**, not in the macOS kernel. A parser exploit is contained in the guest — it does **not** land in the host kernel. Compare macFUSE, which is a **kernel extension running in the host kernel** (and on Apple Silicon additionally requires **reducing system security** to approve the kext). By that measure the microVM approach is *more* isolated for this inherently-risky operation, not less.
- **No kext, no reduced security posture, no reboot.**

## 6. If you deploy this in an organization: what must be signed off

Because these residuals cannot be engineered away, using auto-unlock on managed
or sensitive systems requires an **explicit, signed risk-acceptance** from the
owner of your security process (DITSO / CISO / equivalent). The document to sign
should record acceptance of, at minimum:

1. **R-parse** — a privileged filesystem parser processes attacker-controllable bytes on insertion (mitigated by read-only + VM isolation + fail-closed selection, **not** eliminated).
2. **R-kernel** — dependence on a third-party, non-independently-audited forked Linux kernel (unless self-built/audited).
3. **R-supply** — acceptance of, or a plan to remediate, the anylinuxfs supply chain: pinned image digest, vendored+hashed dependencies, root-owned immutable rootfs, an SBOM + CVE process (see §4 and `SRAA-ASSESSMENT.md §5`).
4. **The backend as a privileged dependency** — that a third-party root-capable microVM is acceptable as the privileged component for this use case.
5. **The read-only vs read-write policy** — read-write on the auto path is **not** provided by this tool and would be a separate, deliberate policy decision.

**Important:** if your users are **not local administrators** and must operate
with **zero `sudo`** (the "IT installs once, then fully automatic" model), that
is **not** what v1.4 auto-unlock provides — v1.4 still needs an admin to
authorize each session's root access. The zero-`sudo`, unprivileged-user model
requires a **signed, MDM-deployed privileged helper** — tracked as the Phase-2
design (v1.5) in `SRAA-ASSESSMENT.md §3`, and itself gated on the decision in
`SRAA-ASSESSMENT.md §8`.

## 7. Bottom line

- **For a personal machine where you are an admin:** auto-unlock is a convenience; the risks above are yours to accept, and this document is your informed-consent basis.
- **For an organization / non-admin users / air-gapped or classified data:** auto-unlock is **not** authorized by this project. It is usable **only** after your security owner signs the acceptance in §6, and the zero-sudo enterprise form is the separate Phase-2 helper, not v1.4.

*This is a risk disclosure by an open-source project. It is not an authorization,
and it does not transfer or assume liability for any deployment decision.*
