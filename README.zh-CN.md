<div align="right">
  <a href="README.md">English</a> | <b>简体中文</b> | <a href="README.zh-TW.md">繁體中文</a>
</div>

# bltusb

[![ShellCheck](https://github.com/neil0306/bltusb/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/neil0306/bltusb/actions/workflows/shellcheck.yml)
[![Test](https://github.com/neil0306/bltusb/actions/workflows/test.yml/badge.svg)](https://github.com/neil0306/bltusb/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-black)

在 **macOS (Apple Silicon)** 上读写 **BitLocker / NTFS / exFAT 等**外接盘的命令行工具 —— 包括 macOS 原生不能写(NTFS)或根本打不开(BitLocker)的那些。

底层基于开源的 [anylinuxfs](https://github.com/nohajc/anylinuxfs)，**不需要 macFUSE、不需要内核扩展、不需要降低系统安全性、不需要重启**。它在后台跑一个极小的 Alpine Linux microVM，用 Linux 原生驱动读写卷，再通过 NFS 把卷挂回 macOS。

- ✅ **直接运行 `bltusb`** —— 自动检测设备、让你选一个、然后挂载
- ✅ **anylinuxfs 支持的任意文件系统** —— BitLocker、NTFS、exFAT、ext4… 加密盘会问密码，普通盘不问
- ✅ 只读 / 读写 均支持
- ✅ 密码存 macOS Keychain（不落地明文）
- ✅ 自动识别每个分区的文件系统、以及哪些是加密的（读取磁盘签名）
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
| `bltusb detect` | 显示每个外接分区的文件系统（标出加密的） |
| `bltusb install` | 安装 anylinuxfs |
| `bltusb config [init\|set-device\|set-mode]` | 显示/修改配置 |
| `bltusb forget [/dev/diskXsY\|--all]` | 忘记某块盘记住的密码 |
| `bltusb autounlock [install\|uninstall\|status]` | 插入即自动只读挂载 *（个人/开发便利）* |
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

## 密码（加密盘）

加密盘（BitLocker/LUKS）挂载时会问密码 —— 或 48 位 BitLocker 恢复密钥。每块盘**各自记忆、默认不记（opt-in）**，就像 Windows 的**"在这台电脑上自动解锁"**：

- 解锁成功后会问 **"下次在这台 Mac 上自动解锁这块盘吗？[y/N]"** —— 默认**否**。
- 选**是**，该盘密码就按**它自己的卷标识**（Partition UUID，或含 BitLocker 卷 GUID 的引导扇区指纹）存进 macOS Keychain。多块不同密码的盘互不覆盖。
- **恢复密钥永不保存**（那是灾难恢复凭证）。
- 已存密码失效会自动回退到手输 —— 适合每次重新加密的临时搬数据盘。
- `bltusb forget /dev/diskXsY` 删除某块盘的已存密码；`bltusb forget --all` 全清。

挂载时取密码优先级：`环境变量 ALFS_PASSPHRASE` → 本盘已存密码 → 交互输入。脚本里可临时传（不落地）：

```bash
ALFS_PASSPHRASE='你的密码' bltusb mount ro /dev/diskXsY
```

## 插入即自动解锁（个人/开发便利）

> ⚠️ **仅限个人 / 开发机。** 这是一个 Phase-0 便利功能，复用你交互式的 `sudo` 和 Keychain。它**不是**生产/SRAA 路径，**绝不可**在受管或政府机群上启用。
>
> 📄 **启用前请先读风险说明 [`docs/AUTO-UNLOCK-RISK.md`](docs/AUTO-UNLOCK-RISK.md)** —— 有哪些风险、我们做了哪些防护、以及(组织内部署时)你的安全负责人必须就什么签字。完整架构见 [`docs/SRAA-ASSESSMENT.md`](docs/SRAA-ASSESSMENT.md)。

`bltusb autounlock install` 会安装一个**每用户 LaunchAgent**，通过 `diskutil activity` 监听插盘事件；插入外接盘时自动**只读**挂载 —— 类似 Windows 的「在这台电脑上自动解锁」，但覆盖整个流程：

- 复用全部既有安全护栏（仅外接分区、绝不碰 EFI / 整盘 / 内置盘、绝不在 macOS 已挂载之上二次挂载），并**始终只读挂载** —— 永不自动读写。
- 加密盘先静默尝试这块盘已存的 Keychain 密码（或 `ALFS_PASSPHRASE`）；未命中才弹出原生 GUI 密码框。成功后会（GUI）询问是否记住该卷密码；恢复密钥永不保存。
- 无终端获取 root：在挂载时弹出**原生 macOS 管理员密码框**（通过 `SUDO_ASKPASS`）—— 与 BitLocker 密码不同。这是**唯一**的 sudo 路径。两个密码都绝不进入命令行、被记录命令的环境变量或临时文件。
- **运行机制：** 当 bltusb 是 **Homebrew 安装**时，`autounlock install` 会自动委托给 **`brew services`** —— 等价于你自己运行 `brew services start bltusb`（**无需 `sudo`** —— 它是每用户代理；**切勿** `sudo brew services`，那会安装一个 root LaunchDaemon）。手动（非 Homebrew）安装则回退到自管的每用户 **LaunchAgent**。

```bash
bltusb autounlock install            # 挂载时弹管理员密码框（brew 安装则走 brew services）
bltusb autounlock status             # 运行机制 + 是否已加载
bltusb autounlock uninstall          # 停止服务 / 移除 LaunchAgent
# Homebrew 安装的等价命令（每用户，无需 sudo）：
brew services start bltusb
brew services stop bltusb
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
