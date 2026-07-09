<div align="right">
  <b>English</b> | <a href="README.zh-CN.md">简体中文</a>
</div>

# bltusb

A command-line tool to **read and write BitLocker-encrypted USB drives on macOS (Apple Silicon)**.

Built on top of the open-source [anylinuxfs](https://github.com/nohajc/anylinuxfs): **no macFUSE, no kernel extension, no reduced system security, no reboot**. It runs a tiny Alpine Linux microVM that decrypts BitLocker and reads/writes NTFS using native Linux drivers, then mounts the volume back to macOS over NFS.

- ✅ Read-only **and** read-write
- ✅ Password stored in the macOS Keychain (never written to disk in plaintext)
- ✅ Auto-detects which partition is the BitLocker volume (reads the volume signature)
- ✅ Colored help, friendly prompts, read-only by default for safety

> Why not the classic `dislocker + macFUSE + ntfs-3g`? On Apple Silicon that stack requires installing the macFUSE kernel extension, which means booting into Recovery, lowering the security policy to "Reduced Security", and rebooting. anylinuxfs avoids all of that. See [`docs/RESEARCH.md`](docs/RESEARCH.md) for the full comparison.

## Install

```bash
# 1) Drop it on your PATH (Homebrew's bin is already on PATH)
curl -fsSL https://raw.githubusercontent.com/neil0306/bltusb/main/bltusb -o /opt/homebrew/bin/bltusb
chmod +x /opt/homebrew/bin/bltusb

# or clone and place it yourself
git clone https://github.com/neil0306/bltusb.git
install -m 0755 bltusb/bltusb /opt/homebrew/bin/bltusb

# 2) Install the underlying anylinuxfs (brew tap + trust + install)
bltusb install
```

## Quick start

```bash
bltusb config init     # Interactive setup: BitLocker password (→ Keychain), optional fixed device, default mode
bltusb mount           # Mount read-only (recommended for daily use)
bltusb rw --open       # Mount read-write and open in Finder
bltusb umount          # Unmount when done
```

## Commands

| Command | Description |
|---|---|
| `bltusb mount [ro\|rw] [device] [--open]` | Mount (**read-only** by default) |
| `bltusb rw [device] [--open]` | Mount read-write (= `mount rw`) |
| `bltusb open [ro\|rw]` | Mount and open in Finder (or just open if already mounted) |
| `bltusb umount` / `unmount` | Unmount |
| `bltusb status` | Show mount status and external disks |
| `bltusb detect` | Scan and identify which partition is a BitLocker volume |
| `bltusb install` | Install anylinuxfs |
| `bltusb config [init\|set-password\|set-device\|set-mode\|clear-password]` | Configuration |
| `bltusb help` / `version` | Help / version |

## Password resolution order

```
env ALFS_PASSPHRASE  >  macOS Keychain  >  interactive prompt
```

The password is stored in the macOS Keychain (service name `bltusb-anylinuxfs`) via `bltusb config set-password`. It is **never** written to any config file or committed to the repo. You can also pass it ad hoc via an environment variable:

```bash
ALFS_PASSPHRASE='your-password' bltusb mount
```

## Notes

- Mount / unmount require `sudo`.
- Device numbers (`diskN`) can change on each replug; when `DEVICE` is not pinned, the tool auto-detects the BitLocker volume.
- **Read-only by default**; use `rw` only when you need to modify files, to reduce the risk of accidents.
- The config file lives at `~/.config/bltusb/config` and stores only the device and default mode — **never the password**.

## Requirements

- macOS (Apple Silicon)
- [Homebrew](https://brew.sh)
- [anylinuxfs](https://github.com/nohajc/anylinuxfs) (installed automatically by `bltusb install`)

## License

MIT — see [LICENSE](LICENSE).
