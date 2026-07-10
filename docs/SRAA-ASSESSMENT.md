# bltusb — Security Risk Assessment & Authorization (SRAA) Assessment

> Status: **Draft for security-team review** · Version target: production deployment · Date: 2026‑07‑10
> Basis: synthesis of an independent 4‑reviewer analysis (3 architecture/supply‑chain/deployment reviewers + 1 adversarial reviewer).

---

## 中文速览（Executive summary, ZH）

- **现状判决：不可直接上生产（No‑Go as‑is）。** 现在的 bltusb 是一个 bash 工具,靠 `sudo anylinuxfs mount` 工作,底层是第三方 root microVM(anylinuxfs = libkrun + Alpine)。把它变成"普通用户零 sudo 就能用"= 把 sudo 藏进一个 root 服务,并不会让它变安全。
- **可有条件过审,但代价是一个真正的工程项目**,两条重工作流并行:①用**签名原生 XPC helper**(SMAppService)替代 root bash;②**加固/自建 anylinuxfs 供应链**(锁镜像 digest、校验和、离线、只读 rootfs、禁 guest 网络、封死 shell)。
- **一个前置决策必须先由安全团队拍板**(见 §8):"第三方 root microVM + 定制未审计内核"原则上能否进生产。能→按路线走;不能→走替代方案(Paragon 商业版 / 自建 QEMU / macFUSE)。
- **利好**:anylinuxfs **不依赖 macFUSE(无 kext)**,省掉 SRAA 最大的 kext 审批变数。

---

## 1. Scope and context

`bltusb` mounts encrypted (BitLocker/LUKS) and other (NTFS/exFAT/ext) external drives on macOS. It is a thin wrapper over the open‑source **anylinuxfs**, which boots a **libkrun microVM** running an **Alpine Linux** guest, mounts the volume inside the guest with native Linux drivers, and re‑exports it to macOS over loopback **NFS**.

Mounting **requires root** (raw block‑device read + the `mount` syscall). This was verified empirically: `anylinuxfs mount` without `sudo` fails with `Cannot probe /dev/diskXsY: Insufficient permissions`. **There is no pure‑userspace path to mount external volumes on macOS.**

Two very different deployment postures must not be conflated:

| Posture | What it is | Privilege | SRAA |
|---|---|---|---|
| **Phase 0 — personal / dev** | today's `bltusb` (bash + `sudo`) | interactive `sudo` per user | **out of scope / not for production** |
| **Production** | unprivileged users, MDM‑managed, zero `sudo` | a privileged helper deployed by IT | **in scope — this document** |

The production posture requires **some** privileged component. The only question is its shape, and whether the dependency chain it fronts is acceptable.

---

## 2. Verdict

**No‑Go in the current form. Conditionally achievable** only with (a) a minimal, signed, native privileged helper, **and** (b) substantial hardening (or replacement) of the anylinuxfs supply chain. Even then, **architectural residual risks remain** that require an explicit security‑team risk‑acceptance decision (§7, §8).

The single biggest blocker is **not** `bltusb`: it is placing a third‑party, root‑capable microVM/filesystem stack — one that includes an **arbitrary‑root‑exec surface** (`anylinuxfs shell -c '<cmd>'`) and a **custom, unaudited kernel** — behind an unprivileged interface.

---

## 3. Target production architecture

Three‑layer privilege separation. Only the helper is root; everything the user touches is unprivileged.

```
================= TRUST BOUNDARY (root) =====================
  bltusb-helperd  (signed native daemon, SMAppService, MDM-deployed)
    · IPC server — XPC: validate connection audit_token + code-signing
        requirement (TeamIdentifier + designated requirement), NOT UID alone.
        (UDS alternative: getpeereid/LOCAL_PEERCRED then verify code identity.
        SO_PEERCRED is Linux — it does not exist on macOS.)
    · request validator (allowlist: external partition only)
    · operation executor -> calls anylinuxfs with FIXED args
    · audit logger (Unified Logging os_log + EndpointSecurity client;
        NOT OpenBSM/auditd — deprecated on current macOS)
============================================================
                         ^  authenticated local IPC
                         |  (password over an fd, never argv/env)
------------------- UNPRIVILEGED (user) --------------------
  bltusb (CLI)              bltusb-agent (per-user LaunchAgent)
    · UI / Keychain          · diskarbitration insert events
    · calls helper           · native password dialog (osascript)
  per-user Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
============================================================
```

**Helper IPC — the complete allowlist (only these 4 operations):**

| op | inputs (validated) | notes |
|---|---|---|
| `list-external` | — | enumerate external partitions |
| `probe-external` | `device_id` (`^disk\d+s\d+$`) | fstype/label/locked |
| `mount-external` | `device_id`, `fs_type∈{bitlocker,ntfs,exfat,ext*}`, `mountpoint∈/Volumes/…`, password **via fd** | ro default |
| `unmount-external` | `mountpoint` | |

**The helper must NEVER:** forward arbitrary anylinuxfs subcommands; invoke `anylinuxfs shell`/exec/format; accept any argument containing `shell`/`exec`/`-c`; touch internal/system disks, EFI, whole disks, or `/dev/rdisk*`; put the password in argv/env/logs/temp; trust the caller's UID claim (verify the XPC connection **audit token + code‑signing requirement**, not UID — `SO_PEERCRED` is Linux‑only); load or `dlopen` any client‑supplied path.

**No kernel extension.** anylinuxfs uses a microVM + NFS, not macFUSE — this removes the single largest SRAA scheduling variable (kext approval). The helper does need **Full Disk Access** (raw device), granted non‑interactively via an MDM **PPPC** profile; the agent needs **Automation** TCC for the dialog (also via PPPC). `com.apple.servicemanagement` (TeamIdentifier rule) auto‑approves the background items — **zero user action, zero sudo**.

---

## 4. Threat model (summary)

| Adversary | Vector | Mitigation |
|---|---|---|
| Malicious local user | malformed/oversized IPC; `shell` request; path traversal; forged UID | JSON schema + length cap; op allowlist (no passthrough); regex + `realpath`; verify XPC **audit token + code‑signing requirement** (ignore client‑claimed UID; `SO_PEERCRED` is Linux‑only); per‑uid rate limit |
| Malicious USB | hostile block data hits NTFS/ext/BitLocker/NFS parsers **as root** | ro default; run anylinuxfs under a Seatbelt profile; prefer `ntfs3` over `ntfs-3g`; **residual: parser‑exploitation risk cannot be fully removed** |
| Tampered client/agent | replace agent, call helper directly, replay, race insert | helper owns all policy; validates caller; never trusts client‑side checks or UI state |
| Supply chain | malicious anylinuxfs / Alpine image / dependency binary | signature verify anylinuxfs before exec; pin+verify image digest; root‑owned, non‑user‑writable artifacts (§5) |
| VM escape / guest→host | libkrun guest shares security context with the VMM | **residual: architectural, not configurable away** (§7) |

**In scope — physical / peripheral (domain P).** For a removable‑media tool the USB *is* the primary untrusted input, so physical attacks are a dominant vector, not an exclusion. Controls to add (P‑01…P‑07): controlled ports + approved‑media allowlist; hardware **write‑blocker** for intake/forensic reads; accessory inventory + BadUSB/HID and USB‑network‑adapter detection; two‑person action for `rw`/intake; Thunderbolt/USB4 **DMA** posture (Apple Silicon IOMMU mitigates, does not eliminate); DFU/1TR control; power‑state (sleep/cold‑boot key‑residency) and disposal policy.

Out of scope (genuinely): `root` acting directly (already the trusted base); MDM compromise (covered by the platform's own SRAA, not this component).

---

## 5. Supply‑chain assessment (anylinuxfs v0.18.0)

This is the heart of the No‑Go. Findings (severity):

| # | Finding | Sev | Mitigation |
|---|---|---|---|
| S1 | Alpine image pulled as **`alpine:latest`** (mutable) with **`InsecureAcceptAnything`** policy — no signature/digest verification | **HIGH** | Pin `alpine@sha256:<digest>` in an **internal OCI registry**; fork `init-rootfs` to use a digest‑pinned reference; or **self‑build** the rootfs (§9 alt A) |
| S2 | 5 dependency binaries (libkrunfw kernel, `gvproxy`, `vmnet-helper`, …) downloaded with **no sha256 verification** | **HIGH** | Fork `download-dependencies.sh` to verify pinned hashes; vendor artifacts in the enterprise artifact store |
| S3 | rootfs lives in **`~/.anylinuxfs/`** (user‑writable) — a root helper booting from user‑writable files is a direct trust violation | **HIGH** | Move to a **root‑owned, non‑user‑writable, MDM‑installed** path (e.g. `/Library/Application Support/…`); verify hash before each boot; read‑only rootfs |
| S4 | No SBOM / VEX / CVE‑tracking process | MED | Generate SBOM (syft/trivy); establish a CVE‑tracking + patch process |
| S5 | Guest `ntfs-3g` carries CVE‑2026‑40706 (CVSS 7.8) | MED | Use kernel `ntfs3`; drop `ntfs-3g`; minimize the guest package set |
| S6 | `com.apple.security.cs.disable-library-validation` entitlement (libkrun loaded as dylib) | MED | Requires upstream notarization work to remove; otherwise document as accepted risk |
| S7 | libkrunfw **custom kernel** (nohajc fork, 6.12.62) — no independent audit / CVE tracking | MED | Track upstream; pin + hash; accept or self‑build |
| S8 | libkrun security model: **guest and VMM share one security context**, no namespace isolation | MED · **residual** | Architectural; cannot be configured away — see §7 |

Guest network: anylinuxfs currently reaches Docker Hub + Alpine CDN on first init and runs a `gvproxy` network path. **Recommend: offline apk pre‑seed + block guest egress** (PF rules / host‑only vmnet), so the guest has **no outbound network** in production.

---

## 6. Required controls before authorization (minimum set)

**P0 (must):**
1. Privileged helper is **signed (Developer ID) + notarized + Hardened Runtime**, **root‑owned**, non‑user‑writable, **MDM‑deployed** (SMAppService).
2. Helper exposes **only** the 4‑op allowlist; **no** arbitrary command / shell / env / path / option / rootfs / config inputs from clients.
3. anylinuxfs binary + libkrunfw + Alpine rootfs + config are **bundled or MDM‑installed, root‑owned, version‑pinned, hash‑verified** (S1‑S3, S7).
4. `anylinuxfs shell`/exec is **unreachable by policy** and verified by tests.
5. **Passphrase never via environment** — delivered over an authenticated IPC fd, zeroed after use.
6. Read‑only by default; read‑write requires explicit enterprise policy.
7. Guest has **no outbound network** (offline apk + egress block).

**P1 (strong):** SBOM + CVE process (S4); `ntfs3` not `ntfs-3g` (S5); read‑only rootfs + tmpfs overlay; audit logs via Unified Logging + EndpointSecurity to SIEM (not OpenBSM — deprecated); parser‑risk acceptance memo.

**Review must cover the whole chain** — anylinuxfs, libkrun, libkrunfw kernel, Alpine rootfs, `gvproxy`, `vmnet-helper` — not just `bltusb`.

---

## 7. Residual risks requiring explicit acceptance

Even after all mitigations, these cannot be fully removed and must be **accepted in writing** by the security team:

- **R1 — libkrun shared security context (S8):** a guest‑to‑VMM exploit runs as host root. No public libkrun VM‑escape CVE exists today, but the model provides no namespace isolation.
- **R2 — Custom unaudited kernel (S7):** libkrunfw ships a forked Linux kernel with anylinuxfs patches; no independent security audit.
- **R3 — `disable-library-validation` (S6):** persists unless upstream notarizes and removes it; enables dylib‑hijack if an attacker can write the DYLD search path.
- **R4 — Root parses hostile USB media (§4):** the NTFS/ext/BitLocker/NFS parsers process attacker‑controlled bytes as root; read‑only helps data safety, not parser exploitation.

---

## 8. The pivotal decision (for the security team, before any build)

> **Is a third‑party, root‑capable microVM (libkrun) with a custom unaudited kernel acceptable in principle for production — given R1–R4 — after the §6 hardening?**

- **Yes (accept residual with hardening):** proceed with §3 + §5–§6 (a multi‑month program).
- **No:** the anylinuxfs approach is out; pivot to §9 alternatives.

This is a **budget/appetite gate**, not an engineering detail. It should be answered **before** investing in the signed helper + supply‑chain fork, to avoid building something the review will reject.

---

## 9. Alternatives (if R1–R4 are not acceptable)

| Alt | Approach | Pros | Cons |
|---|---|---|---|
| **A. Self‑built minimal Alpine rootfs** (keep anylinuxfs) | `alpine-make-rootfs` from GPG‑verified mirror → fixed‑SHA squashfs in the artifact store | removes S1‑S3; full provenance | still R1/R2/R3 (libkrun + custom kernel) |
| **B. Chainguard/distroless image** | cosign‑signed, SBOM, zero‑CVE base | strong supply chain | compatibility with anylinuxfs init unverified; still R1/R2 |
| **C. Commercial NTFS/BitLocker (e.g. Paragon)** | vendor with a security‑support contract | often already enterprise‑approved; support SLA | paid; closed source; may not cover BitLocker on USB; still needs a privileged component |
| **D. Self‑built QEMU/UTM VM** | full control of image + kernel | maximal auditability | heavy; loses anylinuxfs convenience; still root + VM |
| **E. Read‑only rescue only** | `dislocker-file` offline decrypt + native read‑only mount | no microVM, minimal surface | read‑only; needs disk space; no seamless UX |

---

## 10. Phased roadmap and effort

| Phase | Goal | Effort | SRAA |
|---|---|---|---|
| **0 — personal/dev** *(done: v1.3.x)* | function validation on dev machines (bash + sudo) | — | out of scope |
| **1 — SRAA design + go/no‑go** | this doc + threat model + supply‑chain plan; **security‑team decision (§8)** | ~weeks | gate |
| **2 — build** | signed Swift XPC helper (SMAppService) + hardened/self‑built anylinuxfs + MDM profiles (PPPC FDA + Automation + servicemanagement) | ~1–3 months; needs Apple Developer Program + Swift + a fork | prep |
| **3 — submit + pilot + prod** | SRAA package, 10–20‑seat pilot, rollout/rollback runbook | — | authorization |

Effort delta: a **bash + LaunchDaemon** helper is ~1–2 person‑days but is a **red flag** (root, mutable, unsignable → low pass probability). A **signed native XPC helper** is ~5–15 person‑days but is the Apple‑recommended, SRAA‑friendly form (**high** pass probability). The bash form is acceptable **only** for Phase 0.

---

## 11. Compliance control mapping (target design)

| Control | Implementation |
|---|---|
| Least privilege | root only in the helper; 4‑op allowlist; CLI/agent unprivileged; minimal entitlements |
| Separation of duties | helper (root) / agent (user UI) / CLI (user) fully separated; one‑way signed IPC |
| Input validation | allowlist regex + `realpath`; `execve` array (no shell); `additionalProperties:false` |
| Integrity | Developer ID + notarization + Hardened Runtime; kernel verifies signature pre‑exec; anylinuxfs signature checked before invocation |
| Data protection | passphrase in memory only, over an fd, zeroed; never on disk/argv/env/logs |
| Supply chain | pinned + hash‑verified artifacts; SBOM; internal registry; CVE process |
| Audit & logging | Unified Logging os_log (public metadata, never secrets) + an **EndpointSecurity** client (ES_EVENT_TYPE_NOTIFY_MOUNT/UNMOUNT); SIEM forward. **Not** OpenBSM/`AUE_MOUNT` — deprecated on current macOS. Document the local‑root log‑tampering window + encrypted/WORM offline export |
| Monitoring / IR | alert on unauthorized IPC callers; helper removable/disable via MDM (`launchctl bootout` + profile removal) |
| Change management | signed pkg re‑distributed via MDM; version in Info.plist; unload‑then‑replace |

---

## 12. Recommendation

1. **Do not build the production privileged component yet.** First take §8 to the security team. Their answer determines the entire direction and whether the investment is warranted.
2. If proceeding: **self‑build the Alpine rootfs (Alt A)** to erase S1–S3 immediately, and design the **signed XPC helper** per §3.
3. Keep the current bash tool clearly labeled **Phase‑0 / personal‑dev only**; do not present it as an enterprise solution. ⚠️ **A label is not an exemption:** "out of scope" holds only if Phase‑0 is **technically and administratively excluded** from government systems and government data (e.g. not installable on the managed fleet, not used on machines that touch classified/PII data). Maintain a signed scope statement. If Phase‑0 ever handles government data, its controls revert to **KEEP** and it is **No‑Go** until remediated.
4. The optional **auto‑unlock UX** (insert → native dialog) can ship as a **personal‑dev convenience** on machines that already have `sudo`, but it is explicitly **not** the production/SRAA path.

*This document is a synthesis for review. It is not itself an authorization. Figures (effort, CVEs) should be re‑verified at implementation time.*

---

## 13. Audit addendum — offline + macOS SRAA (v1.3.4)

Independent re‑audit of the shipping bash tool against the **`sraa-audit-offline-macos`** rule set (domains **O** offline/air‑gap integrity, **P** peripheral/physical, **M** macOS hardening) by two independent reviewers (Opus subagent + codex, read‑only static, no mount/network/disk). **Verdict unchanged: No‑Go for government production**; every blocking High is architectural/supply‑chain and already tracked in §5–§10. Both reviewers confirmed the bash code is otherwise clean (no new exploitable code‑level bug in the crypto/device‑identity/config paths). The v1.3.4 fixes then went through a **2‑round adversarial re‑audit loop** (codex found 4 regressions round‑1, 2 round‑2 — all fixed and re‑verified — then PASS round‑3), plus a full hardware functional re‑test (19/19: ro/rw/speed/integrity + fresh‑device prompt/save/Keychain‑restore).

**Applied in v1.3.4 (bltusb‑side, no functional loss to the Phase‑0 tool):**
- **C‑02 (terminal‑escape / bidi injection):** added `sanitize_display()` and applied it to every backend/media‑derived string printed to the terminal (`cmd_status` raw `anylinuxfs status` + `diskutil list`; the wizard's device‑row labels). It strips C0 controls (keeping TAB/NEWLINE), DEL, C1 (U+0080–U+009F), and the true bidi controls (U+061C, U+200E/F, U+202A–E, U+2066–9) — but deliberately **keeps** ZWNJ/ZWJ (U+200C/D, legit in emoji/Arabic/Indic) and U+200B. It decodes each line via `Encode::decode(…, FB_DEFAULT)` so malformed UTF‑8 from hostile media becomes U+FFFD (non‑fatal, no stderr leak) rather than blanking the whole line/row; it is byte‑identical on clean output. Six regression tests in the smoke suite + CI.
- **O‑01‑b (blind‑trust soft‑fail):** `brew trust nohajc/anylinuxfs` failure is now **fatal** (`die`, was `warn`) — install no longer proceeds with an untrusted tap.
- **SEC‑01 (doc/behaviour mismatch):** corrected the stale `get_passphrase_quiet()` comment that falsely claimed the legacy global Keychain item is "not consulted." The **migration fallback is retained by design** (upgrading users must keep working); the comment now describes it accurately as a one‑time, per‑drive migration path.
- **PROC‑01 (test honesty):** relabelled the hardware suite as **DESTRUCTIVE + credential‑mutating** (it writes ~100 MB to the target drive and deletes/restores real Keychain secrets); documented that SKIP is a distinct, visible outcome not counted as a pass.

**Design‑doc corrections made above (were technical errors):**
- **M‑03:** `SO_PEERCRED` is Linux‑only → macOS must validate the **XPC connection audit token + code‑signing requirement** (or `getpeereid`/`LOCAL_PEERCRED` + code‑identity check on a UDS). Fixed §3/§4.
- **M‑02:** OpenBSM/`AUE_MOUNT` is deprecated → **Unified Logging + EndpointSecurity**. Fixed §3/§6/§11.
- **DOC‑01:** physical/peripheral attack is **in scope** (the USB is the primary untrusted input) → added domain‑P controls (P‑01…P‑07) in §4.
- **P2‑SCOPE‑01:** a "Phase‑0 out of scope" label is not an exemption without technical + administrative exclusion → §12.3.

**Refinements to existing tracking (not new blockers):**
- **O‑04:** the unverified‑dependency / user‑writable‑rootfs problem **cannot be mitigated inside the bash tool** (anylinuxfs owns those artifacts) — it requires the Phase‑2 self‑built, signed, root‑owned rootfs (Alt‑A). Confirmed, not collapsible into a hash check.
- **P‑02:** `fstype()`/`_devbytes()` means **bltusb itself** also reads raw boot sectors of untrusted media under `sudo` (narrow surface — `tr -d` + `case` only, fail‑safe `|| true`), in addition to anylinuxfs's parsers. Recorded.
- **O‑09:** `scripts/release.sh`'s execution host is formally in the **build‑machine** scope and must get its own **networked** `sraa-audit`; it hashes only its own tarball (proves consistency, not independent origin — needs signed tags + independently‑signed manifest).
- **P2‑O‑01 (air‑gap gate):** anylinuxfs first‑run requires Homebrew + Docker Hub + Alpine network, so the deployment **cannot claim continuous air‑gap**; network/TLS/RA controls stay `N/A‑PENDING‑VERIFICATION` until O‑01 evidence + egress‑blocking + O‑10 diagram exist. Elevated to a gate.

**Deferred to government‑mode / Phase‑2 (intentionally NOT applied to the Phase‑0 personal tool — they remove personal‑convenience features and belong to the signed‑helper phase):** refuse `EUID=0` (M‑01, would break the advertised `sudo bltusb detect` fallback); fail‑closed on unknown filesystem (C‑01); no Finder auto‑open (P‑01); no persistent `rw` / `DEFAULT_MODE=rw` (P‑02); durable structured audit log (H‑01); signed release tags + independent manifest (F‑01).

### 13.1 v1.4 auto‑unlock — on‑insert exposure to R4 (accepted for Phase‑0)

The opt‑in auto‑unlock feature (`bltusb autounlock install`, a per‑user LaunchAgent watching `diskutil activity`) **changes the character of the R4 hostile‑media root‑parser exposure**: on an auto‑unlock‑enabled machine, plugging in an external drive moves the NTFS/ext/BitLocker/NFS parsers from a **deliberate, manual** `mount` invocation to **automatic invocation on physical insertion** — narrowing the gap between "attacker gets USB into the port" and "attacker‑controlled bytes reach a root parser." It is **mitigated**: the auto path is **read‑only only** (never rw); it reuses every fail‑closed guard (external‑partition only; never EFI / whole‑disk / internal; no double‑mount over a live macOS mount; unknown filesystem → silent no‑op); it **re‑validates the device's strong identity across the passphrase dialog** (TOCTOU guard — a device swap during the ≤120 s dialog aborts the mount); and secrets never touch argv, a logged environment, or a temp file. The residual **parser‑exploitation risk (R4) is unchanged in kind and is accepted for Phase‑0** on personal‑dev machines only — its real fix is the **Phase‑2 Seatbelt‑sandboxed / signed‑helper** work (§6), not any bash‑level control. Auto‑unlock **must not** be enabled on a managed/government fleet.

Additionally, the earlier `--nopasswd` option (which wrote a standing passwordless‑root rule to a user‑writable‑Homebrew‑pinned path under `/etc/sudoers.d/bltusb`) **was removed as an unsafe root‑escalation backdoor** — it could not be made safe at Phase‑0. The GUI `SUDO_ASKPASS` admin‑password dialog is now the **only** sudo path; `autounlock uninstall` additionally performs a **visible** (warn‑on‑failure, never silently swallowed) defensive cleanup of any legacy sudoers rule left by a prior build.
