<div align="right">
  <b>English</b> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a>
</div>

# bltusb

[![ShellCheck](https://github.com/neil0306/bltusb/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/neil0306/bltusb/actions/workflows/shellcheck.yml)
[![Test](https://github.com/neil0306/bltusb/actions/workflows/test.yml/badge.svg)](https://github.com/neil0306/bltusb/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-black)

A command-line tool to **read and write BitLocker, NTFS, exFAT and other drives on macOS (Apple Silicon)** — including the ones macOS can't write natively (NTFS) or open at all (BitLocker).

Built on top of the open-source [anylinuxfs](https://github.com/nohajc/anylinuxfs): **no macFUSE, no kernel extension, no reduced system security, no reboot**. It runs a tiny Alpine Linux microVM that uses native Linux drivers to read/write the volume, then mounts it back to macOS over NFS.

- ✅ **Just run `bltusb`** — it detects your drives, lets you pick one, and mounts it
- ✅ **Any filesystem anylinuxfs supports** — BitLocker, NTFS, exFAT, ext4, … Encrypted volumes ask for a password; plain drives don't.
- ✅ Read-only **and** read-write
- ✅ Password stored in the macOS Keychain (never written to disk in plaintext)
- ✅ Auto-detects each partition's filesystem and which ones are encrypted (reads on-disk signatures)
- ✅ **Multilingual UI** (English / 简体中文 / 繁體中文), auto-detected from your system
- ✅ Colored help, friendly prompts, read-only by default for safety

> Why not the classic `dislocker + macFUSE + ntfs-3g`? On Apple Silicon that stack requires installing the macFUSE kernel extension, which means booting into Recovery, lowering the security policy to "Reduced Security", and rebooting. anylinuxfs avoids all of that. See [`docs/RESEARCH.md`](docs/RESEARCH.md) for the full comparison.

## Install

### Homebrew (recommended)

```bash
brew install neil0306/tap/bltusb
bltusb install   # one-time: set up the anylinuxfs backend
```

### Manual

```bash
curl -fsSL https://raw.githubusercontent.com/neil0306/bltusb/main/bltusb -o /opt/homebrew/bin/bltusb
chmod +x /opt/homebrew/bin/bltusb
bltusb install   # one-time: set up the anylinuxfs backend
```

## Quick start

Just run it with **no arguments** — bltusb detects your external drives, lets you pick one, and mounts it (read-only by default). The first time it needs your password it offers to save it to the Keychain.

```console
$ bltusb
==> Detecting external drives...

Select a drive to mount:
  1) /dev/disk4s1  61.5 GB   Windows_FAT_32  BitLocker  (recommended)
  2) /dev/disk6s1  209.7 MB  EFI
Enter number [default 1]:

How to mount:
  1) read-only (safe, default)
  2) read-write
Select [default 1]:

✓ Mounted → /Volumes/…   (ro)
Open it in Finder now? [Y/n]
```

Prefer explicit commands? They all still work:

```bash
bltusb rw --open       # read-write mount and open in Finder
bltusb umount          # unmount when done
```

## Commands

| Command | Description |
|---|---|
| `bltusb` *(no args)* | **Interactive**: detect drives → pick one → mount |
| `bltusb mount [ro\|rw] [device] [--open]` | Mount (**read-only** by default) |
| `bltusb rw [device] [--open]` | Mount read-write (= `mount rw`) |
| `bltusb open [ro\|rw]` | Mount and open in Finder (or just open if already mounted) |
| `bltusb umount` / `unmount` | Unmount |
| `bltusb status` | Show mount status and external disks |
| `bltusb detect` | Show each external partition's filesystem (marks encrypted ones) |
| `bltusb install` | Install anylinuxfs |
| `bltusb config [init\|set-device\|set-mode]` | Show/change configuration |
| `bltusb forget [/dev/diskXsY\|--all]` | Forget a remembered drive password |
| `bltusb autounlock [install\|uninstall\|status]` | Auto-mount drives (read-only) on insert *(personal-dev)* |
| `bltusb lang [en\|zh-CN\|zh-TW\|auto]` | Switch menu language |
| `bltusb help` / `version` | Help / version |

## Language

The UI language is **auto-detected from your system** (macOS `AppleLocale`, then `$LANG`). Override it anytime:

```bash
bltusb lang zh-TW      # force Traditional Chinese
bltusb lang auto       # go back to following the system
BLTUSB_LANG=en bltusb  # one-off override via env var
```

Resolution order: `BLTUSB_LANG` env var → saved override (`bltusb lang …`) → system locale → English.

## Passwords (encrypted drives)

Encrypted drives (BitLocker/LUKS) ask for a password — or a 48-digit BitLocker recovery key — when you mount them. Each drive is **remembered separately** and **opt-in**, exactly like Windows' *"Automatically unlock on this PC"*:

- After a successful unlock you're asked **"Automatically unlock this drive on this Mac next time? [y/N]"** — default **No**.
- Say **yes** and that drive's password is stored in the macOS Keychain **keyed to that specific volume** (its Partition UUID, or a boot-sector fingerprint incl. the BitLocker volume GUID). Multiple drives with different passwords never overwrite each other.
- **Recovery keys are never saved** (they're disaster-recovery credentials).
- A wrong/stale saved password automatically falls back to a prompt — handy for transfer drives re-encrypted with a new password.
- `bltusb forget /dev/diskXsY` removes one drive's saved password; `bltusb forget --all` clears them all.

Resolution order when mounting: `env ALFS_PASSPHRASE` → this drive's saved password → interactive prompt. For scripts you can pass it ad hoc (never stored):

```bash
ALFS_PASSPHRASE='your-password' bltusb mount ro /dev/diskXsY
```

## Auto-unlock on insert (personal-dev convenience)

> ⚠️ **Personal / development machines only.** This is a Phase-0 convenience that reuses your interactive `sudo` and your Keychain. It is **not** the production/SRAA path and must **not** be enabled on a managed or government fleet — see [`docs/SRAA-ASSESSMENT.md`](docs/SRAA-ASSESSMENT.md).

`bltusb autounlock install` sets up a **per-user LaunchAgent** that watches for drive-insert events (`diskutil activity`) and, when you plug in an external drive, mounts it **read-only** automatically — just like Windows' *"Automatically unlock on this PC"*, but for the whole flow:

- It reuses every existing safety guard (external-partition only, never EFI / whole-disk / internal, no double-mount over a live macOS mount) and **always mounts read-only** — it never auto-mounts read-write.
- For an encrypted drive it tries this drive's saved Keychain password (or `ALFS_PASSPHRASE`) first, silently; only on a miss does it pop a native GUI password dialog. On success it offers (GUI) to remember the password for that specific volume. Recovery keys are never saved.
- Getting root without a terminal: the mount pops a **native macOS admin-password dialog** (via `SUDO_ASKPASS`) — distinct from the BitLocker passphrase. This is the **only** sudo path. Neither secret is ever placed in a command line, an environment of a logged command, or a temp file.
- **Mechanism:** when bltusb is **Homebrew-installed**, `autounlock install` delegates to **`brew services`** automatically — equivalently you can run `brew services start bltusb` yourself (**without `sudo`** — it is a per-user agent; **never** `sudo brew services`, which would install a root LaunchDaemon). For a manual (non-Homebrew) install it falls back to a self-managed per-user **LaunchAgent**.

```bash
bltusb autounlock install            # GUI admin prompt on mount (brew services if brew-installed)
bltusb autounlock status             # mechanism + loaded state
bltusb autounlock uninstall          # stop the service / remove the LaunchAgent
# Homebrew-installed equivalents (per-user, NO sudo):
brew services start bltusb
brew services stop bltusb
```

## Notes

- Mount / unmount require `sudo`.
- Device numbers (`diskN`) can change on each replug; the wizard always re-detects, and when `DEVICE` is not pinned the BitLocker volume is auto-detected.
- **Read-only by default**; use `rw` only when you need to modify files, to reduce the risk of accidents.
- The config file lives at `~/.config/bltusb/config` and stores only the device, default mode, and language — **never the password**.

## Testing

```bash
test/bltusb_test.sh smoke      # offline checks (also run in CI)
test/bltusb_test.sh hardware   # real BitLocker USB: mount/read/write/speed (macOS, local)
test/bltusb_test.sh all
```

- **smoke** — version, trilingual help, language switching, argument handling. No drive needed; runs on Linux/macOS and in CI.
- **hardware** — end-to-end against a real drive: detect → read-only/read-write mount → read-back → md5 integrity → read/write speed → cleanup. It is **non-destructive** (only touches `bltusb_selftest_*` files) and **auto-skips** when there's no BitLocker drive, no password, or the host isn't macOS — so `test/bltusb_test.sh all` stays green even without the USB. An opt-in check (`BLTUSB_TEST_FRESH=1`) additionally verifies the first-time password prompt and Keychain save (it clears then restores your saved password).

Cutting a release is one command (`scripts/release.sh patch`) — see [`docs/RELEASING.md`](docs/RELEASING.md).

## Requirements

- macOS (Apple Silicon)
- [Homebrew](https://brew.sh)
- [anylinuxfs](https://github.com/nohajc/anylinuxfs) (installed automatically by `bltusb install`)

## License

MIT — see [LICENSE](LICENSE).
