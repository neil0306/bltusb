<div align="right">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <b>繁體中文</b>
</div>

# bltusb

[![ShellCheck](https://github.com/neil0306/bltusb/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/neil0306/bltusb/actions/workflows/shellcheck.yml)
[![Test](https://github.com/neil0306/bltusb/actions/workflows/test.yml/badge.svg)](https://github.com/neil0306/bltusb/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-black)

在 **macOS (Apple Silicon)** 上讀寫 **BitLocker / NTFS / exFAT 等**外接碟的命令列工具 —— 包括 macOS 原生不能寫(NTFS)或根本打不開(BitLocker)的那些。

底層基於開源的 [anylinuxfs](https://github.com/nohajc/anylinuxfs)，**無需 macFUSE、無需核心擴充、無需降低系統安全性、無需重開機**。它在背景執行一個極小的 Alpine Linux microVM，用 Linux 原生驅動讀寫磁碟區，再透過 NFS 把磁碟區掛回 macOS。

- ✅ **直接執行 `bltusb`** —— 自動偵測裝置、讓你選一個、然後掛載
- ✅ **anylinuxfs 支援的任意檔案系統** —— BitLocker、NTFS、exFAT、ext4… 加密碟會問密碼，普通碟不問
- ✅ 唯讀 / 讀寫 皆支援
- ✅ 密碼存 macOS Keychain（不落地明文）
- ✅ 自動辨識每個分割區的檔案系統、以及哪些是加密的（讀取磁碟簽章）
- ✅ **多語言介面**（English / 简体中文 / 繁體中文），自動跟隨系統語言
- ✅ 彩色說明、友善提示、預設唯讀較安全

> 為什麼不用經典的 `dislocker + macFUSE + ntfs-3g`？在 Apple Silicon 上那套要裝 macFUSE 核心擴充，必須進復原模式把安全等級降到 “Reduced Security” 並重開機。anylinuxfs 完全繞開了這些。比較見 [`docs/RESEARCH.zh-CN.md`](docs/RESEARCH.zh-CN.md)。

## 安裝

### Homebrew（推薦）

```bash
brew install neil0306/tap/bltusb
bltusb install   # 一次性：裝好底層 anylinuxfs
```

### 手動

```bash
curl -fsSL https://raw.githubusercontent.com/neil0306/bltusb/main/bltusb -o /opt/homebrew/bin/bltusb
chmod +x /opt/homebrew/bin/bltusb
bltusb install   # 一次性：裝好底層 anylinuxfs
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
| `bltusb detect` | 顯示每個外接分割區的檔案系統（標出加密的） |
| `bltusb install` | 安裝 anylinuxfs |
| `bltusb config [init\|set-device\|set-mode]` | 顯示/修改設定 |
| `bltusb forget [/dev/diskXsY\|--all]` | 忘記某塊磁碟記住的密碼 |
| `bltusb autounlock [install\|uninstall\|status]` | 插入即自動唯讀掛載 *（個人/開發便利）* |
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

## 密碼（加密碟）

加密碟（BitLocker/LUKS）掛載時會問密碼 —— 或 48 位 BitLocker 還原金鑰。每塊磁碟**各自記憶、預設不記（opt-in）**，就像 Windows 的**「在這台電腦上自動解鎖」**：

- 解鎖成功後會問 **「下次在這台 Mac 上自動解鎖這塊磁碟嗎？[y/N]」** —— 預設**否**。
- 選**是**，該磁碟密碼就按**它自己的磁碟區識別**（Partition UUID，或含 BitLocker 卷 GUID 的開機磁區指紋）存進 macOS Keychain。多塊不同密碼的磁碟互不覆寫。
- **還原金鑰永不儲存**（那是災難還原憑證）。
- 已存密碼失效會自動回退到手動輸入 —— 適合每次重新加密的臨時搬資料碟。
- `bltusb forget /dev/diskXsY` 刪除某塊磁碟的已存密碼；`bltusb forget --all` 全清。

掛載時取密碼優先序：`環境變數 ALFS_PASSPHRASE` → 本磁碟已存密碼 → 互動輸入。指令稿裡可臨時傳（不落地）：

```bash
ALFS_PASSPHRASE='你的密碼' bltusb mount ro /dev/diskXsY
```

## 插入即自動解鎖（個人/開發便利）

> ⚠️ **僅限個人 / 開發機。** 這是一個 Phase-0 便利功能，複用你互動式的 `sudo` 和 Keychain。它**不是**生產/SRAA 路徑，**絕不可**在受管或政府機群上啟用 —— 見 [`docs/SRAA-ASSESSMENT.md`](docs/SRAA-ASSESSMENT.md)。

`bltusb autounlock install` 會安裝一個**每使用者 LaunchAgent**，透過 `diskutil activity` 監聽插碟事件；插入外接碟時自動**唯讀**掛載 —— 類似 Windows 的「在這台電腦上自動解鎖」，但涵蓋整個流程：

- 複用全部既有安全護欄（僅外接分割區、絕不碰 EFI / 整碟 / 內建碟、絕不在 macOS 已掛載之上二次掛載），並**始終唯讀掛載** —— 永不自動讀寫。
- 加密碟先靜默嘗試這塊碟已存的 Keychain 密碼（或 `ALFS_PASSPHRASE`）；未命中才彈出原生 GUI 密碼框。成功後會（GUI）詢問是否記住該磁碟區密碼；還原金鑰永不儲存。
- 無終端取得 root：在掛載時彈出**原生 macOS 管理員密碼框**（透過 `SUDO_ASKPASS`）—— 與 BitLocker 密碼不同。這是**唯一**的 sudo 路徑。兩個密碼都絕不進入命令列、被記錄命令的環境變數或暫存檔。
- **運行機制：** 當 bltusb 是 **Homebrew 安裝**時，`autounlock install` 會自動委派給 **`brew services`** —— 等價於你自己執行 `brew services start bltusb`（**無需 `sudo`** —— 它是每使用者代理；**切勿** `sudo brew services`，那會安裝一個 root LaunchDaemon）。手動（非 Homebrew）安裝則回退到自管的每使用者 **LaunchAgent**。

```bash
bltusb autounlock install            # 掛載時彈管理員密碼框（brew 安裝則走 brew services）
bltusb autounlock status             # 運行機制 + 是否已載入
bltusb autounlock uninstall          # 停止服務 / 移除 LaunchAgent
# Homebrew 安裝的等價命令（每使用者，無需 sudo）：
brew services start bltusb
brew services stop bltusb
```

## 說明與注意

- 掛載 / 卸載需要 `sudo`。
- 裝置編號（`diskN`）每次插拔可能變動；向導每次都會重新偵測，未固定 `DEVICE` 時會自動辨識 BitLocker 磁碟區。
- 預設**唯讀**，改檔案時才用 `rw`，降低誤操作風險。
- 設定檔在 `~/.config/bltusb/config`，只存裝置編號、預設模式和語言，**不含密碼**。

## 測試

```bash
test/bltusb_test.sh smoke      # 離線檢查（CI 裡也跑這個）
test/bltusb_test.sh hardware   # 真機 BitLocker 隨身碟：掛載/讀寫/速度（macOS，本地）
test/bltusb_test.sh all
```

- **smoke** —— 版本、三語說明、語言切換、參數處理。不需要隨身碟；Linux/macOS 和 CI 都能跑。
- **hardware** —— 對真磁碟端到端：detect → 唯讀/讀寫掛載 → 讀回 → md5 完整性 → 讀寫速度 → 清理。**非破壞性**（只碰 `bltusb_selftest_*` 檔案），且在沒有 BitLocker 磁碟 / 沒有密碼 / 非 macOS 時**自動跳過**——所以沒插隨身碟時 `test/bltusb_test.sh all` 依然是綠的。另有一個可選子項（`BLTUSB_TEST_FRESH=1`）會額外驗證「新裝置首次彈密碼 + 存 Keychain」流程（會清除並還原你已存的密碼）。

## 相依

- macOS（Apple Silicon）
- [Homebrew](https://brew.sh)
- [anylinuxfs](https://github.com/nohajc/anylinuxfs)（由 `bltusb install` 自動安裝）

## License

MIT — 見 [LICENSE](LICENSE)。
