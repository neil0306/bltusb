<div align="right">
  <a href="RESEARCH.md">English</a> | <b>简体中文</b>
</div>

# 方案调研：在 macOS (Apple Silicon) 上读写 BitLocker U 盘

本文件记录了做这个工具之前的调研与实测结论，解释为什么最终选择 **anylinuxfs**。

## 背景约束

- 机器是 Apple Silicon（arm64）macOS。
- 目标：在 Mac 上**读写**（不只是读）BitLocker To Go 加密 U 盘。
- BitLocker 盘是「两层」结构：外层 BitLocker 加密 + 内层 NTFS 文件系统。
- 硬约束：现代 macOS（Ventura 13+）**移除了原生 NTFS 写支持**，NTFS 写入必须靠 FUSE（ntfs-3g）。

## 候选方案对比

| 方案 | 能读 | 能写 | Apple Silicon | 需内核扩展/降安全性 | 免费开源 |
|---|---|---|---|---|---|
| **anylinuxfs**（本工具采用） | ✅ | ✅ | ✅ | ❌ 不需要 | ✅ |
| dislocker + macFUSE + ntfs-3g | ✅ | ✅ | ✅ | ⚠️ 需装 macFUSE kext、进恢复模式降到 Reduced Security + 重启 | ✅ |
| dislocker + FUSE-T + ntfs-3g | 可能 | ❓ 无实测成功案例 | ✅（无 kext） | ❌ | ✅ |
| dislocker-file 离线解密 + 原生只读挂载 | ✅ | ❌ 只读 | ✅ | ❌（零安装） | ✅ |
| libbde / bdetools | ✅ | ❌ 只读（取证用途） | ✅ | 视 FUSE 后端 | ✅ |
| VeraCrypt | ❌ 不支持 BitLocker 格式 | ❌ | — | — | ✅ |
| 商业 GUI（iBoysoft 等） | ✅ | ✅ | ✅ | 多数仍需 system extension | ❌ 收费 |

## 为什么选 anylinuxfs

- **零内核扩展**：不用 macFUSE，因此不必进恢复模式、不必降低系统安全性、不必重启，也没有 GUI 批准弹窗。
- **能读也能写**：VM 内用 Linux 原生驱动，读写 BitLocker/NTFS 都稳定。
- **原生支持 BitLocker**：用密码 / recovery key 即可解密。
- **一条命令**：安装后 `mount` 即可。

原理：起一个 Alpine Linux microVM → VM 里解密 BitLocker + 挂载 NTFS → 通过 NFS 把卷回传给 macOS（在 `mount` 里显示为 nfs）。

## 实测结论（Apple Silicon）

- 安装：`brew tap nohajc/anylinuxfs && brew trust nohajc/anylinuxfs && brew install anylinuxfs`
  - `brew trust` 这步不能省，否则报 “Refusing to load formula from untrusted tap”。
- 密码可**非交互**传入：环境变量 `ALFS_PASSPHRASE`（比 README 更准，从 `anylinuxfs mount --help` 挖到）。
- 只读挂载：`sudo ALFS_PASSPHRASE=*** anylinuxfs mount -o ro -w false /dev/diskXsY`
- 读写挂载：去掉 `-o ro`。
- 卸载：`sudo anylinuxfs unmount`
- 设备用**分区**（`/dev/diskXsY`），不是整盘。
- 挂载/卸载需要 `sudo`。
- 只读、读写、最小写测试（写→读回→删）均实测通过，原有数据不受影响。

## 被排除的方案要点

- **原生 NTFS 写 / fstab 偏方**：Ventura 起 Apple 删了 `ntfs.kext`，已彻底失效，且历史上会损坏数据，别用。
- **libbde / VeraCrypt**：前者只读（取证），后者根本不支持 BitLocker 格式。
- **dislocker + macFUSE**：能读写，但 Apple Silicon 上要装内核扩展、降安全性、重启，明显更折腾。
- **dislocker + FUSE-T**：理论可行且无 kext，但全网无可靠实测成功记录，且 Homebrew formula 硬编码 macfuse 需打补丁。
- **只读救数据**：`dislocker-file` 离线解密成镜像 + `hdiutil attach` + 原生只读挂，零安装、最安全，但不能写、需等量磁盘空间。

## 参考

- anylinuxfs — https://github.com/nohajc/anylinuxfs
- 教程（BitLocker on Mac via anylinuxfs）— https://nohajc.github.io/blog/tutorial/2025/07/20/how-to-mount-bit-locker-drives-on-mac.html
- dislocker — https://github.com/Aorimn/dislocker
- macFUSE FUSE Backends（FSKit vs kernel）— https://github.com/macfuse/macfuse/wiki/FUSE-Backends
- FUSE-T — https://github.com/macos-fuse-t/fuse-t
- libbde — https://github.com/libyal/libbde
