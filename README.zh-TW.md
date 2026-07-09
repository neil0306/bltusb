<div align="right">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <b>繁體中文</b>
</div>

# bltusb

[![ShellCheck](https://github.com/neil0306/bltusb/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/neil0306/bltusb/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-black)

在 **macOS (Apple Silicon)** 上讀寫 **BitLocker** 加密隨身碟的命令列工具。

底層基於開源的 [anylinuxfs](https://github.com/nohajc/anylinuxfs)，**無需 macFUSE、無需核心擴充、無需降低系統安全性、無需重開機**。它在背景執行一個極小的 Alpine Linux microVM，在 VM 內用 Linux 原生驅動解密 BitLocker 並讀寫 NTFS，再透過 NFS 把磁碟區掛回 macOS。

- ✅ **直接執行 `bltusb`** —— 自動偵測裝置、讓你選一個、然後掛載
- ✅ 唯讀 / 讀寫 皆支援
- ✅ 密碼存 macOS Keychain（不落地明文）
- ✅ 自動辨識哪個分割區是 BitLocker 磁碟區（讀取磁碟區簽章）
- ✅ **多語言介面**（English / 简体中文 / 繁體中文），自動跟隨系統語言
- ✅ 彩色說明、友善提示、預設唯讀較安全

> 為什麼不用經典的 `dislocker + macFUSE + ntfs-3g`？在 Apple Silicon 上那套要裝 macFUSE 核心擴充，必須進復原模式把安全等級降到 “Reduced Security” 並重開機。anylinuxfs 完全繞開了這些。比較見 [`docs/RESEARCH.zh-CN.md`](docs/RESEARCH.zh-CN.md)。

## 安裝

```bash
# 1) 放到 PATH 裡（Homebrew 的 bin 已在 PATH）
curl -fsSL https://raw.githubusercontent.com/neil0306/bltusb/main/bltusb -o /opt/homebrew/bin/bltusb
chmod +x /opt/homebrew/bin/bltusb

# 或者 clone 後自行放置
git clone https://github.com/neil0306/bltusb.git
install -m 0755 bltusb/bltusb /opt/homebrew/bin/bltusb

# 2) 安裝底層的 anylinuxfs（brew tap + trust + install）
bltusb install
```

## 快速開始

直接執行、**不帶任何參數** —— bltusb 會自動偵測外接裝置、讓你選一個、然後掛載（預設唯讀）。第一次需要密碼時會問你要不要存進 Keychain（以後免輸入）。

```console
$ bltusb
==> 正在偵測外接裝置…

請選擇要掛載的裝置：
  1) /dev/disk4s1  61.5 GB   Windows_FAT_32  BitLocker  (推薦)
  2) /dev/disk6s1  209.7 MB  EFI
輸入編號 [預設 1]:

掛載方式：
  1) 唯讀（安全，預設）
  2) 讀寫
選擇 [預設 1]:

✓ 掛載成功 → /Volumes/…   (ro)
現在在 Finder 開啟嗎？[Y/n]
```

喜歡明確命令？它們依然都能用：

```bash
bltusb rw --open       # 讀寫掛載並在 Finder 開啟
bltusb umount          # 用完卸載
```

## 命令一覽

| 命令 | 說明 |
|---|---|
| `bltusb`（無參數） | **互動式**：偵測裝置 → 選擇 → 掛載 |
| `bltusb mount [ro\|rw] [裝置] [--open]` | 掛載（預設**唯讀**） |
| `bltusb rw [裝置] [--open]` | 讀寫掛載（= `mount rw`） |
| `bltusb open [ro\|rw]` | 掛載並在 Finder 開啟（已掛則直接開啟） |
| `bltusb umount` / `unmount` | 卸載 |
| `bltusb status` | 檢視掛載狀態和外接磁碟 |
| `bltusb detect` | 掃描並辨識哪個分割區是 BitLocker 磁碟區 |
| `bltusb install` | 安裝 anylinuxfs |
| `bltusb config [init\|set-password\|set-device\|set-mode\|clear-password]` | 設定 |
| `bltusb lang [en\|zh-CN\|zh-TW\|auto]` | 切換選單語言 |
| `bltusb help` / `version` | 說明 / 版本 |

## 語言

介面語言**自動跟隨系統**（macOS `AppleLocale`，其次 `$LANG`）。隨時可手動切換：

```bash
bltusb lang zh-TW      # 強制繁體中文
bltusb lang auto       # 恢復為跟隨系統
BLTUSB_LANG=en bltusb  # 用環境變數臨時切換
```

優先序：環境變數 `BLTUSB_LANG` → 儲存的覆寫設定（`bltusb lang …`）→ 系統語言 → 英文。

## 密碼來源優先序

```
環境變數 ALFS_PASSPHRASE  >  macOS Keychain  >  互動輸入
```

密碼透過 `bltusb config set-password`（或在掛載時接受「存入 Keychain？」提示）存入 macOS Keychain（服務名稱 `bltusb-anylinuxfs`），**不會**寫進任何設定檔或倉庫。也可臨時用環境變數：

```bash
ALFS_PASSPHRASE='你的密碼' bltusb mount
```

## 說明與注意

- 掛載 / 卸載需要 `sudo`。
- 裝置編號（`diskN`）每次插拔可能變動；向導每次都會重新偵測，未固定 `DEVICE` 時會自動辨識 BitLocker 磁碟區。
- 預設**唯讀**，改檔案時才用 `rw`，降低誤操作風險。
- 設定檔在 `~/.config/bltusb/config`，只存裝置編號、預設模式和語言，**不含密碼**。

## 相依

- macOS（Apple Silicon）
- [Homebrew](https://brew.sh)
- [anylinuxfs](https://github.com/nohajc/anylinuxfs)（由 `bltusb install` 自動安裝）

## License

MIT — 見 [LICENSE](LICENSE)。
