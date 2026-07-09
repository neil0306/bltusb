#!/usr/bin/env bash
#
# bltusb test suite.
#
#   test/bltusb_test.sh smoke      # offline checks, safe anywhere (used in CI)
#   test/bltusb_test.sh hardware   # real BitLocker USB: mount/read/write/speed (macOS, local only)
#   test/bltusb_test.sh all        # smoke + hardware
#
# The binary under test defaults to ./bltusb next to this repo; override with BLTUSB_BIN.
# The hardware suite never touches user data — it only creates/removes files
# prefixed bltusb_selftest_ and needs the BitLocker password in the Keychain
# or ALFS_PASSPHRASE. It AUTO-SKIPS (not a failure) when there is no macOS,
# no anylinuxfs, no BitLocker drive, or no password — so `all` stays green on
# a machine without the USB, and in CI.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${BLTUSB_BIN:-$HERE/../bltusb}"
PASS=0; FAIL=0; SKIP=0

ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
no()   { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
skip() { echo "  – (skip) $*"; SKIP=$((SKIP+1)); }
hdr()  { echo; echo "== $*"; }

# assert_contains <label> <needle> <haystack>
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) no "$1 (missing: $2)" ;; esac; }

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
mp()  { anylinuxfs status 2>/dev/null | grep -oE '/Volumes/[^ ]+' | head -1; }
# The NFS mount point can take a beat to become visible after `mount` returns.
wait_mount() { for _ in 1 2 3 4 5 6; do [[ -n "$(mp)" ]] && return 0; sleep 1; done; return 1; }

# ---------------------------------------------------------------------------
# smoke — offline, no diskutil/security/sudo, safe in CI (Linux or macOS)
# ---------------------------------------------------------------------------
smoke() {
  hdr "smoke: binary present & executable"
  if [[ -x "$BIN" ]]; then ok "found $BIN"; else no "binary not executable: $BIN"; return; fi

  hdr "smoke: version matches VERSION in script"
  local v_script v_run
  v_script="$(grep -m1 '^VERSION=' "$BIN" | sed -E 's/.*"(.*)".*/\1/')"
  v_run="$("$BIN" version 2>/dev/null | awk '{print $2}')"
  if [[ -n "$v_run" && "$v_run" == "$v_script" ]]; then ok "version $v_run"; else no "version mismatch (script=$v_script run=$v_run)"; fi

  hdr "smoke: help renders in all three languages"
  assert_contains "en help"    "read/write BitLocker" "$(BLTUSB_LANG=en    "$BIN" help 2>/dev/null)"
  assert_contains "en quick"   "Quick start"          "$(BLTUSB_LANG=en    "$BIN" help 2>/dev/null)"
  assert_contains "zh-CN help" "快速开始"              "$(BLTUSB_LANG=zh-CN "$BIN" help 2>/dev/null)"
  assert_contains "zh-TW help" "快速開始"              "$(BLTUSB_LANG=zh-TW "$BIN" help 2>/dev/null)"

  hdr "smoke: BLTUSB_LANG env switches language"
  assert_contains "env=zh-TW" "掛載"  "$(BLTUSB_LANG=zh-TW "$BIN" help 2>/dev/null)"
  assert_contains "env=en"    "Mount" "$(BLTUSB_LANG=en    "$BIN" help 2>/dev/null)"

  hdr "smoke: lang override persists (isolated config)"
  local tmp cfg show
  tmp="$(mktemp -d)"; cfg="$tmp/bltusb/config"
  XDG_CONFIG_HOME="$tmp" BLTUSB_LANG='' "$BIN" lang zh-TW >/dev/null 2>&1
  if grep -q 'LANG_OVERRIDE="zh-TW"' "$cfg" 2>/dev/null; then ok "lang zh-TW written to config"; else no "lang override not persisted"; fi
  show="$(XDG_CONFIG_HOME="$tmp" BLTUSB_LANG='' "$BIN" lang show 2>/dev/null)"
  assert_contains "lang show reflects override" "zh-TW" "$show"
  XDG_CONFIG_HOME="$tmp" BLTUSB_LANG='' "$BIN" lang auto >/dev/null 2>&1
  if grep -q 'LANG_OVERRIDE=""' "$cfg" 2>/dev/null; then ok "lang auto clears override"; else no "lang auto did not clear override"; fi
  rm -rf "$tmp"

  hdr "smoke: unknown command exits non-zero"
  if "$BIN" definitely-not-a-command >/dev/null 2>&1; then no "unknown command should fail"; else ok "unknown command exits non-zero"; fi

  hdr "smoke: version flags"
  assert_contains "-v flag" "bltusb" "$("$BIN" -v 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# hardware — real BitLocker USB (macOS only, local). Non-destructive. Auto-skips.
# ---------------------------------------------------------------------------
hardware() {
  hdr "hardware: preflight (auto-skips if the environment isn't available)"
  if [[ "${CI:-}" == "true" ]]; then skip "running in CI — hardware suite disabled"; return; fi
  if [[ "$(uname -s)" != "Darwin" ]]; then skip "not macOS"; return; fi
  if ! command -v anylinuxfs >/dev/null 2>&1; then skip "anylinuxfs not installed"; return; fi

  local dev
  dev="$("$BIN" detect 2>/dev/null | grep 'BitLocker volume' | grep -oE '/dev/disk[0-9]+s[0-9]+' | head -1)"
  if [[ -z "$dev" ]]; then skip "no BitLocker drive detected — plug one in to run this suite"; return; fi
  ok "BitLocker drive detected: $dev"

  if [[ -z "${ALFS_PASSPHRASE:-}" ]] && ! security find-generic-password -s bltusb-anylinuxfs -a passphrase -w >/dev/null 2>&1; then
    skip "no password in Keychain or ALFS_PASSPHRASE"; return
  fi
  [[ -z "$(mp)" ]] || sudo anylinuxfs unmount >/dev/null 2>&1

  hdr "hardware: read-only mount + read"
  "$BIN" mount ro "$dev" >/dev/null 2>&1
  local M f; wait_mount; M="$(mp)"
  if [[ -n "$M" ]]; then
    ok "read-only mounted: $M"
    if touch "$M/bltusb_selftest_probe" 2>/dev/null; then no "read-only was writable"; rm -f "$M/bltusb_selftest_probe"; else ok "read-only rejects writes"; fi
    f="$(find "$M" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | head -1)"
    if [[ -n "$f" ]]; then
      if md5 -q "$f" >/dev/null 2>&1; then ok "read existing file: $(basename "$f")"; else no "could not read existing file"; fi
    fi
  else
    no "read-only mount failed"
  fi
  "$BIN" umount >/dev/null 2>&1
  if [[ -z "$(mp)" ]]; then ok "unmounted"; else no "still mounted after umount"; fi

  hdr "hardware: read-write mount + speed + integrity"
  local size_mb=100 tmp src out src_md5
  tmp="$(mktemp -d)"; src="$tmp/src.bin"; out="$tmp/out.bin"
  dd if=/dev/urandom of="$src" bs=1m count=$size_mb 2>/dev/null
  src_md5="$(md5 -q "$src")"

  "$BIN" rw "$dev" >/dev/null 2>&1
  wait_mount; M="$(mp)"
  if [[ -z "$M" ]]; then
    no "read-write mount failed"
  else
    ok "read-write mounted: $M"
    local testf="$M/bltusb_selftest_$$.bin" t0 t1 t2 t3
    t0="$(now)"; dd if="$src" of="$testf" bs=1m 2>/dev/null; sync; t1="$(now)"
    ok "write ${size_mb}MB → $(perl -e "printf '%.1f MB/s', $size_mb/($t1-$t0)")"
    sudo purge 2>/dev/null || true
    t2="$(now)"; dd if="$testf" of="$out" bs=1m 2>/dev/null; t3="$(now)"
    ok "read  ${size_mb}MB → $(perl -e "printf '%.1f MB/s', $size_mb/($t3-$t2)")  (may be cached)"
    if [[ "$src_md5" == "$(md5 -q "$out")" ]]; then ok "md5 integrity OK"; else no "md5 mismatch"; fi
    rm -f "$testf"; sync
    if ls "$M"/bltusb_selftest_* >/dev/null 2>&1; then no "test files left behind"; else ok "test files cleaned up"; fi
  fi
  "$BIN" umount >/dev/null 2>&1
  if [[ -z "$(mp)" ]]; then ok "unmounted"; else no "still mounted after umount"; fi
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
main() {
  local suite="${1:-smoke}"
  case "$suite" in
    smoke)    smoke ;;
    hardware) hardware ;;
    all)      smoke; hardware ;;
    *) echo "usage: $0 [smoke|hardware|all]"; exit 2 ;;
  esac
  echo
  echo "== summary: pass=$PASS fail=$FAIL skip=$SKIP"
  if [[ $FAIL -eq 0 ]]; then echo "== OK"; exit 0; else echo "== FAILED"; exit 1; fi
}
main "$@"
