# bltusb

在 **macOS (Apple Silicon)** 上读写 **BitLocker** 加密 U 盘的命令行工具。

底层基于开源的 [anylinuxfs](https://github.com/nohajc/anylinuxfs)，**不需要 macFUSE、不需要内核扩展、不需要降低系统安全性、不需要重启**。它在后台跑一个极小的 Alpine Linux microVM，在 VM 里用 Linux 原生驱动解密 BitLocker 并读写 NTFS，再通过 NFS 把卷挂回 macOS。

- ✅ 只读 / 读写 均支持
- ✅ 密码存 macOS Keychain（不落地明文）
- ✅ 自动识别哪个分区是 BitLocker 卷（读取卷签名）
- ✅ 彩色帮助、友好提示、默认只读更安全

> 为什么不用经典的 `dislocker + macFUSE + ntfs-3g`？在 Apple Silicon 上那套要装 macFUSE 内核扩展，必须进恢复模式把安全等级降到 “Reduced Security” 并重启。anylinuxfs 完全绕开了这些。对比见 [`docs/RESEARCH.md`](docs/RESEARCH.md)。

## 安装

```bash
# 1) 放到 PATH 里（Homebrew 的 bin 已在 PATH）
curl -fsSL https://raw.githubusercontent.com/neil0306/bltusb/main/bltusb -o /opt/homebrew/bin/bltusb
chmod +x /opt/homebrew/bin/bltusb

# 或者 clone 后自行放置
git clone https://github.com/neil0306/bltusb.git
install -m 0755 bltusb/bltusb /opt/homebrew/bin/bltusb

# 2) 安装底层的 anylinuxfs（brew tap + trust + install）
bltusb install
```

## 快速开始

```bash
bltusb config init     # 交互式设置：BitLocker 密码（存 Keychain）、可选固定设备、默认模式
bltusb mount           # 只读挂载（日常推荐）
bltusb rw --open       # 读写挂载并在 Finder 打开
bltusb umount          # 用完卸载
```

## 命令一览

| 命令 | 说明 |
|---|---|
| `bltusb mount [ro\|rw] [设备] [--open]` | 挂载（默认**只读**） |
| `bltusb rw [设备] [--open]` | 读写挂载（= `mount rw`） |
| `bltusb open [ro\|rw]` | 挂载并在 Finder 打开（已挂则直接打开） |
| `bltusb umount` / `unmount` | 卸载 |
| `bltusb status` | 查看挂载状态和外接磁盘 |
| `bltusb detect` | 扫描并识别哪个分区是 BitLocker 卷 |
| `bltusb install` | 安装 anylinuxfs |
| `bltusb config [init\|set-password\|set-device\|set-mode\|clear-password]` | 配置 |
| `bltusb help` / `version` | 帮助 / 版本 |

## 密码来源优先级

```
环境变量 ALFS_PASSPHRASE  >  macOS Keychain  >  交互输入
```

密码通过 `bltusb config set-password` 存入 macOS Keychain（服务名 `bltusb-anylinuxfs`），**不会**写进任何配置文件或仓库。也可临时用环境变量：

```bash
ALFS_PASSPHRASE='你的密码' bltusb mount
```

## 说明与注意

- 挂载 / 卸载需要 `sudo`。
- 设备号（`diskN`）每次插拔可能变化；不固定 `DEVICE` 时工具会自动识别 BitLocker 卷。
- 默认**只读**，改文件时才用 `rw`，降低误操作风险。
- 配置文件在 `~/.config/bltusb/config`，只存设备号和默认模式，**不含密码**。

## 依赖

- macOS（Apple Silicon）
- [Homebrew](https://brew.sh)
- [anylinuxfs](https://github.com/nohajc/anylinuxfs)（由 `bltusb install` 自动安装）

## License

MIT — 见 [LICENSE](LICENSE)。
