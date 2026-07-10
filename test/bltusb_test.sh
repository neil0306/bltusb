#!/usr/bin/env bash
#
# bltusb test suite.
#
#   test/bltusb_test.sh smoke      # offline checks, safe anywhere (used in CI)
#   test/bltusb_test.sh hardware   # real BitLocker USB: mount/read/write/speed (macOS, local only)
#   test/bltusb_test.sh all        # smoke + hardware
#
# The binary under test defaults to ./bltusb next to this repo; override with BLTUSB_BIN.
#
# WARNING — the hardware suite is DESTRUCTIVE and CREDENTIAL-MUTATING:
#   * it WRITES and deletes real files on the TARGET external drive (a ~100 MB
#     read/write speed test, files prefixed bltusb_selftest_), and
#   * it DELETES then restores real macOS Keychain secrets to exercise the
#     fresh-device / migration prompt paths.
# Run it ONLY against a dedicated, disposable BitLocker drive whose data you do
# not care about, with the password in the Keychain or ALFS_PASSPHRASE.
# Missing prerequisites (no macOS, no anylinuxfs, no external BitLocker drive,
# no password) are reported as SKIP — a distinct, visible outcome that is NOT
# counted as a pass (see the pass/fail/skip summary) — so `all` is runnable in
# CI without the USB while never masking absent security coverage.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${BLTUSB_BIN:-$HERE/../bltusb}"
PASS=0; FAIL=0; SKIP=0
KC_SVC="bltusb-anylinuxfs"; KC_ACC="passphrase"
FRESH_ORIG=""     # password to feed during the test (legacy/global slot or env)
FRESH_DEVKEY=""   # per-device Keychain account used during the fresh-device test
FRESH_DEVORIG=""  # captured PER-DEVICE password (the one we delete+must restore)
FRESH_LEGACYORIG="" # captured LEGACY global password (deleted to force the prompt path; restored on exit)

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
# anylinuxfs needs a moment to fully tear down before the next mount.
settle() { sleep 2; }
kc_has() { security find-generic-password -s "$KC_SVC" -a "$1" -w >/dev/null 2>&1; }
# Same per-volume key derivation bltusb uses (Partition UUID, else boot-sector fingerprint).
dev_key() {
  local d="$1" uuid b64 fp
  uuid="$(diskutil info "$d" 2>/dev/null | awk -F': +' '/Partition UUID/{print $2; exit}')"
  if [[ -n "$uuid" ]]; then printf 'puuid:%s' "$uuid"; return 0; fi
  # No UUID — fall back to a boot-sector fingerprint, mirroring the main script's
  # device_key() guard. Carry the sector through a pipe rather than a temp file
  # (same symlink-TOCTOU-free path as device_key): base64-encode it (NUL-safe in a
  # shell variable) and require EXACTLY 512 raw bytes — 684 base64 chars — before
  # hashing. A cold `sudo -n` or a short read yields zero/short output, whose
  # length check fails; hashing an empty read would otherwise mint a bogus, shared
  # key and restore_keychain would then write the user's real password under the
  # wrong account. Emit nothing (return 1) on a short read so callers treat it as
  # "no stable identity". The hash is over the DECODED 512 raw bytes, so this
  # produces the SAME fp:... as the main script's device_key() for the same drive.
  b64="$(sudo -n dd if="/dev/r${d#/dev/}" bs=512 count=1 2>/dev/null | base64 2>/dev/null | tr -d '\n')"
  [[ ${#b64} -eq 684 ]] || return 1
  fp="$(printf '%s' "$b64" | base64 -d 2>/dev/null | shasum -a 256 | cut -c1-32)"
  [[ -n "$fp" ]] && printf 'fp:%s' "$fp"
}
restore_keychain() {
  # The fresh-device test deletes the user's REAL per-device Keychain item
  # (FRESH_DEVKEY) to simulate an unseen drive. Under v1.3.1's per-device model
  # the mount path never consults the legacy global slot, so we must put the
  # password back under the SAME per-device account we removed — restoring only
  # the legacy KC_ACC would silently destroy the user's remembered per-drive
  # password. Prefer the exact per-device value we captured; fall back to the
  # feed password (FRESH_ORIG) if the per-device slot happened to be empty.
  # Restoring the user's REAL secrets is safety-critical: if security(1) fails
  # (Keychain momentarily locked, re-auth required, transient error) we MUST NOT
  # swallow the error and report success — that silently leaves the user without
  # their saved password. Track any failure so the caller can FAIL the suite, and
  # verify the per-device slot actually came back via kc_has afterwards.
  local rc=0
  if [[ -n "$FRESH_DEVKEY" ]]; then
    # Only restore a per-device item that ACTUALLY existed before the test
    # (FRESH_DEVORIG). If the drive had none (an upgrade user with only the legacy
    # global item), delete anything the test created so we leave the exact prior
    # state — never mint a new per-device item that then shadows the migration path.
    if [[ -n "$FRESH_DEVORIG" ]]; then
      # Feed the secret on stdin (`-w` with no value) so the plaintext never
      # appears in argv where a concurrent `ps` could read it — same pattern as
      # the main script's keychain_set(). The interactive form prompts twice.
      if printf '%s\n%s\n' "$FRESH_DEVORIG" "$FRESH_DEVORIG" \
          | security add-generic-password -U -s "$KC_SVC" -a "$FRESH_DEVKEY" -w >/dev/null 2>&1; then
        # Confirm the secret is actually retrievable again, not just that the
        # command returned 0.
        kc_has "$FRESH_DEVKEY" || { no "restore failed: per-device key not retrievable"; rc=1; }
      else
        no "restore failed: per-device key (security add-generic-password errored)"; rc=1
      fi
    else
      security delete-generic-password -s "$KC_SVC" -a "$FRESH_DEVKEY" >/dev/null 2>&1
    fi
  fi
  # Put the legacy global item back if we deleted it (the mount path's migration
  # fallback reads it), so this opt-in test never destroys the user's password.
  if [[ -n "$FRESH_LEGACYORIG" ]]; then
    if printf '%s\n%s\n' "$FRESH_LEGACYORIG" "$FRESH_LEGACYORIG" \
        | security add-generic-password -U -s "$KC_SVC" -a "$KC_ACC" -w >/dev/null 2>&1; then
      kc_has "$KC_ACC" || { no "restore failed: legacy global item not retrievable"; rc=1; }
    else
      no "restore failed: legacy global item (security add-generic-password errored)"; rc=1
    fi
  fi
  return "$rc"
}

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

  hdr "smoke: sanitize_display defangs terminal-escape / bidi injection from media labels"
  # A crafted USB volume label reaches the terminal via cmd_status / the wizard.
  # Extract the real sanitize_display() from the script (its body ends at a col-0
  # '}') and prove it strips control/bidi codepoints while preserving UTF-8. If the
  # function is ever removed or weakened, these assertions fail in CI.
  local sanf; sanf="$(mktemp)"
  # Extract the function body and append a dispatch line so `bash "$sanf"` reads
  # stdin and writes the sanitized result — no `source`, so no SC1090.
  sed -n '/^sanitize_display()/,/^}/p' "$BIN" > "$sanf"
  printf '\nsanitize_display\n' >> "$sanf"
  if grep -q 'perl -CSAD\|tr -d' "$sanf"; then
    local esc_out uni_out del_out
    esc_out="$(printf 'A\033[31m\033]0;pwn\007B' | bash "$sanf")"
    case "$esc_out" in
      *$'\033'*|*$'\007'*) no "strips ESC/BEL bytes (got: $(printf %s "$esc_out" | cat -v))" ;;
      *) ok "strips ESC/BEL bytes" ;;
    esac
    uni_out="$(printf '\346\225\260\346\215\256' | bash "$sanf")"   # 数据
    if [[ "$uni_out" == "数据" ]]; then ok "preserves UTF-8 label (数据)"; else no "UTF-8 label mangled (got: $uni_out)"; fi
    del_out="$(printf 'x\177y\342\200\256z' | bash "$sanf")"        # DEL + bidi U+202E
    if [[ "$del_out" == "xyz" ]]; then ok "strips DEL + bidi override"; else no "DEL/bidi not stripped (got: $(printf %s "$del_out" | cat -v))"; fi
    # ZWJ (U+200D) is legitimate in emoji sequences (👨‍👩) and Arabic/Indic text —
    # it must survive (regression guard: an earlier range wrongly stripped it).
    local zwj_in zwj_out; zwj_in="$(printf '\360\237\221\250\342\200\215\360\237\221\251')"  # 👨‍👩
    zwj_out="$(printf '%s' "$zwj_in" | bash "$sanf")"
    if [[ "$zwj_out" == "$zwj_in" ]]; then ok "preserves ZWJ emoji sequence (👨‍👩)"; else no "ZWJ emoji corrupted"; fi
    # Malformed UTF-8 from hostile media must be non-fatal AND must not leak perl
    # decode warnings to stderr; the valid bytes around it survive.
    local mal_out mal_err; mal_err="$(mktemp)"
    mal_out="$(printf 'a\377b' | bash "$sanf" 2>"$mal_err")"
    if [[ -s "$mal_err" ]]; then no "malformed UTF-8 leaked stderr: $(cat "$mal_err" | head -1)"; else ok "malformed UTF-8 is non-fatal, no stderr leak"; fi
    case "$mal_out" in a*b) ok "malformed UTF-8 keeps surrounding valid bytes" ;; *) no "malformed UTF-8 dropped valid bytes (got: $(printf %s "$mal_out" | cat -v))" ;; esac
    rm -f "$mal_err"
  else
    no "could not extract sanitize_display from \$BIN"
  fi
  rm -f "$sanf"
}

# ---------------------------------------------------------------------------
# hardware — real BitLocker USB (macOS only, local). DESTRUCTIVE + credential-
# mutating (writes to the target drive, deletes/restores Keychain). Auto-skips
# when prerequisites are absent. See the WARNING in the file header.
# ---------------------------------------------------------------------------
hardware() {
  hdr "hardware: preflight (auto-skips if the environment isn't available)"
  if [[ "${CI:-}" == "true" ]]; then skip "running in CI — hardware suite disabled"; return; fi
  if [[ "$(uname -s)" != "Darwin" ]]; then skip "not macOS"; return; fi
  if ! command -v anylinuxfs >/dev/null 2>&1; then skip "anylinuxfs not installed"; return; fi

  local dev
  dev="$(BLTUSB_LANG=en "$BIN" detect 2>/dev/null | grep -i 'bitlocker' | grep -oE '/dev/disk[0-9]+s[0-9]+' | head -1)"
  if [[ -z "$dev" ]]; then skip "no BitLocker drive detected — plug one in to run this suite"; return; fi
  ok "BitLocker drive detected: $dev"

  # Match the actual v1.3.1 mount path: get_passphrase_quiet reads ALFS_PASSPHRASE
  # or THIS drive's PER-DEVICE Keychain item (via device_key), NOT the legacy
  # global `-a passphrase` account. A normal v1.3.1 user who saved via the opt-in
  # flow has only a per-device entry, so gating on the legacy account alone would
  # permanently skip the whole suite (including fresh_device). Skip only when the
  # env var, the per-device item, AND the legacy global item are all absent.
  if [[ -z "${ALFS_PASSPHRASE:-}" ]] \
     && ! kc_has "$(dev_key "$dev")" \
     && ! security find-generic-password -s bltusb-anylinuxfs -a passphrase -w >/dev/null 2>&1; then
    skip "no password in Keychain or ALFS_PASSPHRASE"; return
  fi
  # Never force-unmount a foreign mount. A pre-existing anylinuxfs mount may be
  # a read-write volume with pending buffered writes that this test does not own;
  # a raw `anylinuxfs unmount` skips the safe path (no sync, no -w wait-for-flush)
  # and can lose in-flight data. Require the user to unmount it themselves via the
  # main script's safe path (`bltusb umount` = sync + `-w`) before running the
  # hardware suite.
  if [[ -n "$(mp)" ]]; then
    skip "an anylinuxfs volume is already mounted — run 'bltusb umount' first, then re-run this suite"
    return
  fi

  hdr "hardware: read-only mount + read"
  "$BIN" mount ro "$dev" >/dev/null 2>&1
  local M f; wait_mount; M="$(mp)"
  if [[ -n "$M" ]]; then
    ok "read-only mounted: $M"
    local probe="$M/bltusb_selftest_ro_$$"
    if touch "$probe" 2>/dev/null; then no "read-only was writable"; rm -f "$probe"; else ok "read-only rejects writes"; fi
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
  # Destructive-ish (writes a temp file to a real drive). Only run against a
  # device the operator explicitly names as disposable — never an auto-detected
  # drive — to avoid ever writing to the wrong disk. Skipping still lets the
  # fresh-device test below run.
  if [[ -z "${BLTUSB_TEST_DEVICE:-}" ]]; then
    skip "read-write test needs BLTUSB_TEST_DEVICE=/dev/diskXsY (won't write to an auto-detected drive)"
  elif [[ "$dev" != "$BLTUSB_TEST_DEVICE" ]]; then
    skip "detected $dev != BLTUSB_TEST_DEVICE $BLTUSB_TEST_DEVICE — skipping write test"
  else
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
  fi

  fresh_device "$dev"
}

# fresh_device — optional, opt-in: proves an UNSEEN device (empty Keychain)
# prompts for the password, the save offer works, and once saved it stops
# prompting. Manipulates the real Keychain, so it is off by default; enable
# with BLTUSB_TEST_FRESH=1. Captures & restores the original password.
fresh_device() {
  local dev="$1" out
  hdr "hardware: fresh-device password prompt (opt-in)"
  if [[ "${BLTUSB_TEST_FRESH:-}" != "1" ]]; then
    skip "set BLTUSB_TEST_FRESH=1 to run (clears+restores the Keychain password)"; return
  fi
  # Password to FEED during the test: prefer the legacy global item (or env).
  FRESH_LEGACYORIG="$(security find-generic-password -s "$KC_SVC" -a "$KC_ACC" -w 2>/dev/null || true)"
  FRESH_ORIG="$FRESH_LEGACYORIG"
  [[ -z "$FRESH_ORIG" && -n "${ALFS_PASSPHRASE:-}" ]] && FRESH_ORIG="$ALFS_PASSPHRASE"
  FRESH_DEVKEY="$(dev_key "$dev")"
  # Capture the REAL per-device password BEFORE we delete it, so restore_keychain
  # can put back the exact value under the per-device account (the slot the mount
  # path actually reads). Without this the user's remembered per-drive password
  # would be permanently destroyed by running this opt-in test.
  FRESH_DEVORIG="$(security find-generic-password -s "$KC_SVC" -a "$FRESH_DEVKEY" -w 2>/dev/null || true)"
  # Need SOMETHING to feed (and, ideally, to restore). Prefer the per-device
  # value if that is all we have.
  [[ -z "$FRESH_ORIG" ]] && FRESH_ORIG="$FRESH_DEVORIG"
  if [[ -z "$FRESH_ORIG" ]]; then skip "no known password to feed and restore"; return; fi
  trap restore_keychain EXIT
  unset ALFS_PASSPHRASE

  # Unseen-device state: clear BOTH this drive's per-device item AND the legacy
  # global item (the mount path's migration fallback reads the latter), so the
  # prompt path is actually exercised. restore_keychain puts both back on EXIT.
  security delete-generic-password -s "$KC_SVC" -a "$FRESH_DEVKEY" >/dev/null 2>&1
  security delete-generic-password -s "$KC_SVC" -a "$KC_ACC" >/dev/null 2>&1
  if kc_has "$FRESH_DEVKEY" || kc_has "$KC_ACC"; then no "keychain not cleared"; else ok "keychain cleared (unseen-device state)"; fi
  settle   # let the previous suite's unmount fully tear down before remounting

  # 1) prompt appears; decline saving → nothing stored for this drive
  out="$(printf '%s\nn\n' "$FRESH_ORIG" | BLTUSB_LANG=en "$BIN" mount ro "$dev" 2>&1)"
  case "$out" in *"BitLocker password"*) ok "password prompt shown for unseen device" ;; *) no "no password prompt" ;; esac
  wait_mount
  if [[ -n "$(mp)" ]]; then ok "mounted with typed password"; else no "mount with typed password failed"; fi
  if kc_has "$FRESH_DEVKEY"; then no "declined save but password was stored"; else ok "declined → not saved (opt-in)"; fi
  "$BIN" umount >/dev/null 2>&1; settle

  # 2) accept saving → stored under this drive's own key
  printf '%s\ny\n' "$FRESH_ORIG" | BLTUSB_LANG=en "$BIN" mount ro "$dev" >/dev/null 2>&1
  wait_mount; "$BIN" umount >/dev/null 2>&1; settle
  if kc_has "$FRESH_DEVKEY"; then ok "accepted → saved under per-device key"; else no "accepted but not saved"; fi

  # 3) saved → no more prompt (empty stdin)
  out="$(printf '' | BLTUSB_LANG=en "$BIN" mount ro "$dev" 2>&1)"
  case "$out" in *"BitLocker password"*) no "still prompted after save" ;; *) ok "no prompt after save (uses per-device key)" ;; esac
  wait_mount
  if [[ -n "$(mp)" ]]; then ok "passwordless mount ok"; else no "passwordless mount failed"; fi
  "$BIN" umount >/dev/null 2>&1; settle

  # Only report success if the restore actually put the user's secrets back;
  # restore_keychain() emits its own `no` on any failure and returns non-zero.
  if restore_keychain; then ok "original Keychain state restored"; fi
  trap - EXIT
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
