# Backend Hardening — Scope & Feasibility (self-built minimal, pinned, root-owned VM)

> Goal: make Mode B `mount` actually work **safely** by giving the root daemon an
> anylinuxfs backend whose **entire trust chain is root-owned + pinned + minimal**,
> so `verifiedBackendPath()` accepts it and the SRAA supply-chain findings
> (S1 mutable image, S3 user-writable rootfs, attack surface) are closed.
> Grounded in the actual anylinuxfs 0.18.0 install on this machine.

## 1. How anylinuxfs is actually built (0.18.0)

| Piece | Location | Ownership | Pinned? |
|---|---|---|---|
| `anylinuxfs` binary + `init-rootfs`, `gvproxy`, `vmnet-helper`, `vmproxy` | `…/Cellar/anylinuxfs/0.18.0/{bin,libexec}` | user (Homebrew) | ✅ formula sha256 |
| **Kernel** `libexec/Image`, `Image-4K` (libkrunfw fork 6.12.62) | Cellar `libexec` | user | ✅ formula sha256 (`1de75a3d…`) |
| **Kernel modules** `lib/modules.squashfs` (the FS drivers) | Cellar `lib` | user | ✅ formula sha256 (`86ed485e…`) |
| `libkrun` VMM | Homebrew | user | ✅ formula sha256 |
| **Image config** `anylinuxfs.toml` | `…/etc/anylinuxfs.toml` | user | editable |
| **Rootfs** (Alpine, ~95 MB) | **`~/.anylinuxfs/alpine/rootfs`** | **user-writable** | ❌ `docker_ref = "alpine:latest"` |

**Key insight:** the microVM stack (kernel, modules, VMM, network helpers) is
**already pinned by sha256** in the Homebrew formula. The **only** mutable
supply-chain hole is the base rootfs image: `anylinuxfs.toml` pulls
`alpine:latest` (S1), and umoci-builds it into **user-writable `~/.anylinuxfs`**
(S3). The current local build resolved `alpine:latest` to a concrete digest
`sha256:e7a1a92a…`.

## 2. Levers anylinuxfs gives us (no fork needed)

- **`/etc/anylinuxfs.toml`** — declarative image definitions. We can add our own
  `[images.bltusb-min]` entry with `docker_ref = "alpine@sha256:<pinned>"`
  (pin the digest → closes S1) and the same pinned kernel URLs.
- **`anylinuxfs image install <NAME>`** — builds the rootfs for a TOML-defined image.
- **`anylinuxfs apk add|del|info`** — add/remove Alpine packages in the rootfs →
  strip to only what we need (cryptsetup, ntfs-3g/ntfs3, mount.nfs, busybox),
  drop btrfs/lvm/zfs/freebsd/edge → smaller attack surface.
- **HOME-relative rootfs** — the rootfs lives at `~/.anylinuxfs`. The helper daemon
  runs as **root**, so as root it resolves to **`/var/root/.anylinuxfs`** (root-owned,
  non-user-writable) — closing S3 automatically for the daemon's own build.
- **`config`** — VM params (vCPU/RAM/net-helper); no rootfs relocation, but we don't
  need it (HOME handles it).

## 3. Hardening design (pinned + minimal + root-owned, via anylinuxfs's own mechanism)

Two one-time-idempotent operations (the scripts the maintainer asked for):

### `vm build` — create the minimal, pinned, root-owned backend
1. **Stage the whole anylinuxfs install root-owned**: copy `bin/anylinuxfs`,
   `libexec/*` (kernel, tools), `lib/modules.squashfs`, `share/*` into
   `/Library/Application Support/bltusb/anylinuxfs/` as `root:wheel`, and a
   root-owned `anylinuxfs.toml` next to it. (Closes the user-writable-binary/kernel
   hole the Mode B audit flagged.)
2. **Pin the base**: in the root-owned toml, define `[images.bltusb-min]` with
   `docker_ref = "alpine@sha256:<current-digest>"` (record the digest we blessed).
3. **Build as root**: `sudo … anylinuxfs image install bltusb-min` → rootfs built into
   **root-owned `/var/root/.anylinuxfs`**.
4. **Strip to minimal**: `anylinuxfs apk del <unneeded>` (or add-only from a minimal
   base) → keep cryptsetup + ntfs + mount.nfs + busybox.
5. **Record + verify**: sha256 the built rootfs (mtree already exists) + the staged
   binaries; store the manifest root-owned. The daemon's `verifiedBackendPath()` +
   a new rootfs-hash check verify this before every boot.

### `vm update` — bless a newer base
1. Re-resolve `alpine:latest` → new digest; show the maintainer the old→new digest.
2. Update the pin in the root-owned toml, rebuild (steps 3–5), re-verify, re-record.
   Deliberate, verified, logged — never a silent `latest` drift.

## 4. What this achieves vs. what it does NOT

**Closes:** S1 (pin the digest, no more `latest`), S3 (root-owned rootfs +
staged binaries), attack-surface (apk-strip), and makes Mode B `mount` pass
`verifiedBackendPath` (root-owned chain end-to-end). The kernel/modules/VMM were
already pinned.

**Residual (honest):** the base is still **Alpine** (built by anylinuxfs), not a
from-scratch rootfs — so we trust Alpine's package set + the `libkrunfw` **forked
kernel** (S7/R2), which remains a pinned-but-unaudited residual (accept per SRAA,
or self-build the kernel later). A *fully* from-scratch rootfs booted via libkrun
directly (bypassing anylinuxfs entirely) is a separate, much larger project and is
**out of scope** for these scripts.

## 5. Feasibility

**HIGH** for the pragmatic path above — it uses anylinuxfs's supported mechanisms
(toml image config + `apk` + `image install`) plus our root-owning + digest-pinning
+ hash-verify. No fork of anylinuxfs required.

**Spike results (verified 2026-07-11):**
- ✅ **Relocation works.** A copied anylinuxfs install run from a temp prefix read
  the **relocated** `etc/anylinuxfs.toml` (it errored on a custom entry there, not
  the `/opt/homebrew` one) — so config (and libexec/kernel, resolved from the
  binary prefix) come from the STAGED tree. Staging the whole install root-owned in
  `/Library` is viable.
- 📝 A custom `[images.<name>]` toml entry **requires `kernel.image_url` +
  `kernel.modules_url`** (parse error "missing field `kernel`") — reuse the pinned
  libkrunfw URLs, or point at the staged local kernel files to avoid re-download.
- 📝 The binary honors env vars **`KRUN_HOME`, `KRUN_CONFIG`, `KRUN_WORKDIR`,
  `KRUN_BLOCK_ROOT`** — `KRUN_HOME` can pin the rootfs to an explicit root-owned
  path (cleaner than relying on root's `$HOME`=/var/root).

**Still to confirm during implementation** (cheaper, not architectural):
- Whether `sudo … anylinuxfs image install <custom>` builds the rootfs into a
  root-owned path (via `KRUN_HOME` or root `$HOME`) — needs a real (slow, networked)
  build.
- Whether `apk del`-stripping is reliable vs. building minimal from a smaller base.

## 6. Delivery shape (for maintainer decision)

The `build` + `update` operations can live as: a **`bltusb vm build|update|status`
subcommand** (integrated, discoverable), and/or the **Mode B `install-selfhosted.sh`**
calls `vm build` so a single install gives a working, safe mount. Recommended:
`bltusb vm …` subcommand that the helper installer invokes.
