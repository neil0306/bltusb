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
    · IPC server (XPC or UDS + SO_PEERCRED caller check)
    · request validator (allowlist: external partition only)
    · operation executor -> calls anylinuxfs with FIXED args
    · audit logger (os_log / BSM)
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

**The helper must NEVER:** forward arbitrary anylinuxfs subcommands; invoke `anylinuxfs shell`/exec/format; accept any argument containing `shell`/`exec`/`-c`; touch internal/system disks, EFI, whole disks, or `/dev/rdisk*`; put the password in argv/env/logs/temp; trust the caller's UID claim (verify via `SO_PEERCRED`/audit token); load or `dlopen` any client‑supplied path.

**No kernel extension.** anylinuxfs uses a microVM + NFS, not macFUSE — this removes the single largest SRAA scheduling variable (kext approval). The helper does need **Full Disk Access** (raw device), granted non‑interactively via an MDM **PPPC** profile; the agent needs **Automation** TCC for the dialog (also via PPPC). `com.apple.servicemanagement` (TeamIdentifier rule) auto‑approves the background items — **zero user action, zero sudo**.

---

## 4. Threat model (summary)

| Adversary | Vector | Mitigation |
|---|---|---|
| Malicious local user | malformed/oversized IPC; `shell` request; path traversal; forged UID | JSON schema + length cap; op allowlist (no passthrough); regex + `realpath`; `SO_PEERCRED` (ignore client‑claimed UID); per‑uid rate limit |
| Malicious USB | hostile block data hits NTFS/ext/BitLocker/NFS parsers **as root** | ro default; run anylinuxfs under a Seatbelt profile; prefer `ntfs3` over `ntfs-3g`; **residual: parser‑exploitation risk cannot be fully removed** |
| Tampered client/agent | replace agent, call helper directly, replay, race insert | helper owns all policy; validates caller; never trusts client‑side checks or UI state |
| Supply chain | malicious anylinuxfs / Alpine image / dependency binary | signature verify anylinuxfs before exec; pin+verify image digest; root‑owned, non‑user‑writable artifacts (§5) |
| VM escape / guest→host | libkrun guest shares security context with the VMM | **residual: architectural, not configurable away** (§7) |

Out of scope: `root` acting directly; MDM compromise; physical attack.

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

**P1 (strong):** SBOM + CVE process (S4); `ntfs3` not `ntfs-3g` (S5); read‑only rootfs + tmpfs overlay; audit logs to SIEM (os_log/BSM); parser‑risk acceptance memo.

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
| Audit & logging | os_log (public metadata, never secrets) + BSM `AUE_MOUNT`; SIEM forward |
| Monitoring / IR | alert on unauthorized IPC callers; helper removable/disable via MDM (`launchctl bootout` + profile removal) |
| Change management | signed pkg re‑distributed via MDM; version in Info.plist; unload‑then‑replace |

---

## 12. Recommendation

1. **Do not build the production privileged component yet.** First take §8 to the security team. Their answer determines the entire direction and whether the investment is warranted.
2. If proceeding: **self‑build the Alpine rootfs (Alt A)** to erase S1–S3 immediately, and design the **signed XPC helper** per §3.
3. Keep the current bash tool clearly labeled **Phase‑0 / personal‑dev only**; do not present it as an enterprise solution.
4. The optional **auto‑unlock UX** (insert → native dialog) can ship as a **personal‑dev convenience** on machines that already have `sudo`, but it is explicitly **not** the production/SRAA path.

*This document is a synthesis for review. It is not itself an authorization. Figures (effort, CVEs) should be re‑verified at implementation time.*
