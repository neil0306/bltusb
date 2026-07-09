<div align="right">
  <a href="README.md">English</a> | <b>简体中文</b> | <a href="README.zh-TW.md">繁體中文</a>
</div>

# bltusb

[![ShellCheck](https://github.com/neil0306/bltusb/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/neil0306/bltusb/actions/workflows/shellcheck.yml)
[![Test](https://github.com/neil0306/bltusb/actions/workflows/test.yml/badge.svg)](https://github.com/neil0306/bltusb/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-black)

在 **macOS (Apple Silicon)** 上读写 **BitLocker** 加密 U 盘的命令行工具。

底层基于开源的 [anylinuxfs](https://github.com/nohajc/anylinuxfs)，**不需要 macFUSE、不需要内核扩展、不需要降低系统安全性、不需要重启**。它在后台跑一个极小的 Alpine Linux microVM，在 VM 里用 Linux 原生驱动解密 BitLocker 并读写 NTFS，再通过 NFS 把卷挂回 macOS。

- ✅ **直接运行 `bltusb`** —— 自动检测设备、让你选一个、然后挂载
- ✅ 只读 / 读写 均支持
- ✅ 密码存 macOS Keychain（不落地明文）
- ✅ 自动识别哪个分区是 BitLocker 卷（读取卷签名）
- ✅ **多语言界面**（English / 简体中文 / 繁體中文），自动跟随系统语言
- ✅ 彩色帮助、友好提示、默认只读更安全

> 为什么不用经典的 `dislocker + macFUSE + ntfs-3g`？在 Apple Silicon 上那套要装 macFUSE 内核扩展，必须进恢复模式把安全等级降到 “Reduced Security” 并重启。anylinuxfs 完全绕开了这些。对比见 [`docs/RESEARCH.zh-CN.md`](docs/RESEARCH.zh-CN.md)。

## 安装

### Homebrew（推荐）

```bash
brew install neil0306/tap/bltusb
bltusb install   # 一次性：装好底层 anylinuxfs
```

### 手动

```bash
curl -fsSL https://raw.githubusercontent.com/neil0306/bltusb/main/bltusb -o /opt/homebrew/bin/bltusb
chmod +x /opt/homebrew/bin/bltusb
bltusb install   # 一次性：装好底层 anylinuxfs
```

## 快速开始

直接运行、**不带任何参数** —— bltusb 会自动检测外接设备、让你选一个、然后挂载（默认只读）。第一次需要密码时会问你要不要存进 Keychain（以后免输）。

```console
$ bltusb
==> 正在检测外接设备…

请选择要挂载的设备：
  1) /dev/disk4s1  61.5 GB   Windows_FAT_32  BitLocker  (推荐)
  2) /dev/disk6s1  209.7 MB  EFI
输入编号 [默认 1]:

挂载方式：
  1) 只读（安全，默认）
  2) 读写
选择 [默认 1]:

✓ 挂载成功 → /Volumes/…   (ro)
现在在 Finder 打开吗？[Y/n]
```

喜欢显式命令？它们依然都能用：

```bash
bltusb rw --open       # 读写挂载并在 Finder 打开
bltusb umount          # 用完卸载
```

## 命令一览

| 命令 | 说明 |
|---|---|
| `bltusb`（无参数） | **交互式**：检测设备 → 选择 → 挂载 |
| `bltusb mount [ro\|rw] [设备] [--open]` | 挂载（默认**只读**） |
| `bltusb rw [设备] [--open]` | 读写挂载（= `mount rw`） |
| `bltusb open [ro\|rw]` | 挂载并在 Finder 打开（已挂则直接打开） |
| `bltusb umount` / `unmount` | 卸载 |
| `bltusb status` | 查看挂载状态和外接磁盘 |
| `bltusb detect` | 扫描并识别哪个分区是 BitLocker 卷 |
| `bltusb install` | 安装 anylinuxfs |
| `bltusb config [init\|set-password\|set-device\|set-mode\|clear-password]` | 配置 |
| `bltusb lang [en\|zh-CN\|zh-TW\|auto]` | 切换菜单语言 |
| `bltusb help` / `version` | 帮助 / 版本 |

## 语言

界面语言**自动跟随系统**（macOS `AppleLocale`，其次 `$LANG`）。随时可手动切换：

```bash
bltusb lang zh-TW      # 强制繁体中文
bltusb lang auto       # 恢复为跟随系统
BLTUSB_LANG=en bltusb  # 用环境变量临时切换
```

优先级：环境变量 `BLTUSB_LANG` → 保存的覆盖设置（`bltusb lang …`）→ 系统语言 → 英文。

## 密码来源优先级

```
环境变量 ALFS_PASSPHRASE  >  macOS Keychain  >  交互输入
```

密码通过 `bltusb config set-password`（或在挂载时接受"存入 Keychain？"提示）存入 macOS Keychain（服务名 `bltusb-anylinuxfs`），**不会**写进任何配置文件或仓库。也可临时用环境变量：

```bash
ALFS_PASSPHRASE='你的密码' bltusb mount
```

## 说明与注意

- 挂载 / 卸载需要 `sudo`。
- 设备号（`diskN`）每次插拔可能变化；向导每次都会重新检测，未固定 `DEVICE` 时会自动识别 BitLocker 卷。
- 默认**只读**，改文件时才用 `rw`，降低误操作风险。
- 配置文件在 `~/.config/bltusb/config`，只存设备号、默认模式和语言，**不含密码**。

## 测试

```bash
test/bltusb_test.sh smoke      # 离线检查（CI 里也跑这个）
test/bltusb_test.sh hardware   # 真机 BitLocker U 盘：挂载/读写/速度（macOS，本地）
test/bltusb_test.sh all
```

- **smoke** —— 版本、三语帮助、语言切换、参数处理。不需要 U 盘；Linux/macOS 和 CI 都能跑。
- **hardware** —— 对真盘端到端：detect → 只读/读写挂载 → 读回 → md5 完整性 → 读写速度 → 清理。**非破坏性**（只碰 `bltusb_selftest_*` 文件），且在没有 BitLocker 盘 / 没有密码 / 非 macOS 时**自动跳过**——所以没插 U 盘时 `test/bltusb_test.sh all` 依然是绿的。另有一个可选子项（`BLTUSB_TEST_FRESH=1`）会额外验证"新设备首次弹密码 + 存 Keychain"流程（会清除并恢复你已存的密码）。

## 依赖

- macOS（Apple Silicon）
- [Homebrew](https://brew.sh)
- [anylinuxfs](https://github.com/nohajc/anylinuxfs)（由 `bltusb install` 自动安装）

## License

MIT — 见 [LICENSE](LICENSE)。
