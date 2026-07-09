<div align="right">
  <b>English</b> | <a href="RESEARCH.zh-CN.md">简体中文</a>
</div>

# Research: reading/writing BitLocker USB drives on macOS (Apple Silicon)

This document records the research and hands-on testing done before building this tool, and explains why **anylinuxfs** was ultimately chosen.

## Constraints

- The machine is Apple Silicon (arm64) macOS.
- Goal: **read and write** (not just read) a BitLocker To Go encrypted USB drive on the Mac.
- A BitLocker drive is "two layers": an outer BitLocker encryption + an inner NTFS filesystem.
- Hard constraint: modern macOS (Ventura 13+) **removed native NTFS write support**, so writing NTFS must go through FUSE (ntfs-3g).

## Approach comparison

| Approach | Read | Write | Apple Silicon | Needs kext / reduced security | Free & open source |
|---|---|---|---|---|---|
| **anylinuxfs** (used by this tool) | ✅ | ✅ | ✅ | ❌ No | ✅ |
| dislocker + macFUSE + ntfs-3g | ✅ | ✅ | ✅ | ⚠️ Requires macFUSE kext: Recovery → Reduced Security + reboot | ✅ |
| dislocker + FUSE-T + ntfs-3g | Maybe | ❓ No confirmed success reports | ✅ (no kext) | ❌ | ✅ |
| dislocker-file offline decrypt + native read-only mount | ✅ | ❌ Read-only | ✅ | ❌ (zero install) | ✅ |
| libbde / bdetools | ✅ | ❌ Read-only (forensics) | ✅ | Depends on FUSE backend | ✅ |
| VeraCrypt | ❌ Does not support BitLocker format | ❌ | — | — | ✅ |
| Commercial GUI (iBoysoft, etc.) | ✅ | ✅ | ✅ | Most still need a system extension | ❌ Paid |

## Why anylinuxfs

- **Zero kernel extensions**: no macFUSE, so no Recovery mode, no lowering system security, no reboot, and no GUI approval prompts.
- **Both read and write**: uses native Linux drivers inside the VM, stable for BitLocker/NTFS read/write.
- **Native BitLocker support**: decrypts with a password / recovery key.
- **One command**: after install, just `mount`.

How it works: it spins up an Alpine Linux microVM → decrypts BitLocker + mounts NTFS inside the VM → re-exports the volume back to macOS over NFS (shows up as `nfs` in `mount`).

## Hands-on results (Apple Silicon)

- Install: `brew tap nohajc/anylinuxfs && brew trust nohajc/anylinuxfs && brew install anylinuxfs`
  - The `brew trust` step is mandatory, otherwise you get "Refusing to load formula from untrusted tap".
- The password can be passed **non-interactively** via the `ALFS_PASSPHRASE` environment variable (more accurate than the README; discovered from `anylinuxfs mount --help`).
- Read-only mount: `sudo ALFS_PASSPHRASE=*** anylinuxfs mount -o ro -w false /dev/diskXsY`
- Read-write mount: drop `-o ro`.
- Unmount: `sudo anylinuxfs unmount`
- Use the **partition** (`/dev/diskXsY`), not the whole disk.
- Mount/unmount require `sudo`.
- Read-only, read-write, and a minimal write test (write → read back → delete) all passed, with existing data untouched.

## Why the other approaches were ruled out

- **Native NTFS write / the fstab trick**: Apple removed `ntfs.kext` starting in Ventura, so it is fully broken now, and historically it could corrupt filesystems — don't use it.
- **libbde / VeraCrypt**: the former is read-only (forensics), the latter doesn't support the BitLocker format at all.
- **dislocker + macFUSE**: works for read/write, but on Apple Silicon it requires installing a kernel extension, lowering security, and rebooting — clearly more hassle.
- **dislocker + FUSE-T**: theoretically viable and kext-free, but there are no reliable success reports anywhere, and the Homebrew formula hardcodes macfuse and would need patching.
- **Read-only data rescue**: `dislocker-file` offline-decrypts to an image + `hdiutil attach` + native read-only mount — zero install, safest, but can't write and needs disk space equal to the volume size.

## References

- anylinuxfs — https://github.com/nohajc/anylinuxfs
- Tutorial (BitLocker on Mac via anylinuxfs) — https://nohajc.github.io/blog/tutorial/2025/07/20/how-to-mount-bit-locker-drives-on-mac.html
- dislocker — https://github.com/Aorimn/dislocker
- macFUSE FUSE Backends (FSKit vs kernel) — https://github.com/macfuse/macfuse/wiki/FUSE-Backends
- FUSE-T — https://github.com/macos-fuse-t/fuse-t
- libbde — https://github.com/libyal/libbde
