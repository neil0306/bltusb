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
| `bltusb config [init\|set-password\|set-device\|set-mode\|clear-password]` | Configuration |
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

## Password resolution order

```
env ALFS_PASSPHRASE  >  macOS Keychain  >  interactive prompt
```

The password is stored in the macOS Keychain (service name `bltusb-anylinuxfs`) via `bltusb config set-password` (or when you accept the "save to Keychain?" prompt). It is **never** written to any config file or committed to the repo. You can also pass it ad hoc:

```bash
ALFS_PASSPHRASE='your-password' bltusb mount
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
