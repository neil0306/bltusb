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
    if [[ -s "$mal_err" ]]; then no "malformed UTF-8 leaked stderr: $(head -1 "$mal_err")"; else ok "malformed UTF-8 is non-fatal, no stderr leak"; fi
    case "$mal_out" in a*b) ok "malformed UTF-8 keeps surrounding valid bytes" ;; *) no "malformed UTF-8 dropped valid bytes (got: $(printf %s "$mal_out" | cat -v))" ;; esac
    rm -f "$mal_err"
  else
    no "could not extract sanitize_display from \$BIN"
  fi
  rm -f "$sanf"

  smoke_autounlock
}

# ---------------------------------------------------------------------------
# smoke: auto-unlock (v1.4.0) — install/uninstall/status/config round-trip,
# plist shape, secret-free plist+askpass, and a no-drive scan. All offline: an
# isolated HOME + XDG_CONFIG_HOME, an osascript stub, and the dryrun hook, so
# no real drive / sudo / GUI is needed (CI-safe on Linux and macOS).
# ---------------------------------------------------------------------------
smoke_autounlock() {
  hdr "smoke: auto-unlock status defaults to off"
  local td home cfg plist show
  td="$(mktemp -d)"; home="$td/home"; mkdir -p "$home/Library/LaunchAgents"
  cfg="$td/cfg"; plist="$home/Library/LaunchAgents/co.carryai.bltusb.autounlock.plist"
  show="$(HOME="$home" XDG_CONFIG_HOME="$cfg" BLTUSB_LANG=en "$BIN" autounlock status 2>/dev/null)"
  assert_contains "status shows State" "State" "$show"
  case "$show" in *"State"*"off"*) ok "auto-unlock off by default" ;; *) no "auto-unlock not off by default" ;; esac

  hdr "smoke: auto-unlock config keys round-trip + validate rejects garbage"
  # A hand-written config with valid + garbage values: valid persist, garbage
  # falls back to the safe default (fail-closed), never executes.
  mkdir -p "$cfg/bltusb"
  cat > "$cfg/bltusb/config" <<EOF
AUTOUNLOCK="on"
EOF
  show="$(HOME="$home" XDG_CONFIG_HOME="$cfg" BLTUSB_LANG=en "$BIN" config show 2>/dev/null)"
  case "$show" in *"on"*) ok "valid AUTOUNLOCK load" ;; *) no "valid autounlock config not loaded" ;; esac
  cat > "$cfg/bltusb/config" <<EOF
AUTOUNLOCK="garbage; rm -rf /"
EOF
  show="$(HOME="$home" XDG_CONFIG_HOME="$cfg" BLTUSB_LANG=en "$BIN" config show 2>/dev/null)"
  case "$show" in *"garbage"*) no "garbage autounlock config not rejected" ;; *) ok "garbage autounlock config falls back to defaults" ;; esac
  case "$show" in *"off"*) ok "fail-closed default (off)" ;; *) no "unexpected autounlock default after garbage" ;; esac
  rm -f "$cfg/bltusb/config"

  hdr "smoke: auto-unlock install writes a valid, correct plist"
  # Stub anylinuxfs so ensure_installed passes without a real backend, and stub
  # launchctl so bootstrap is a no-op (the plist is what we assert on).
  local bindir; bindir="$td/bin"; mkdir -p "$bindir"
  printf '#!/bin/sh\necho ready\n' > "$bindir/anylinuxfs"; chmod +x "$bindir/anylinuxfs"
  # Stateful launchctl stub: bootstrap loads / bootout unloads / print reflects it
  # (state file under the isolated $HOME) — so the install honesty gate sees
  # "loaded" and the verifying stop-helper sees "unloaded" after bootout.
  # shellcheck disable=SC2016  # stub body vars expand at run time, not here
  printf '%s\n' \
    '#!/bin/sh' \
    'st="$HOME/.bltusb_lcstate"' \
    'case "$1" in' \
    '  bootstrap) : > "$st" ;;' \
    '  bootout) rm -f "$st" ;;' \
    '  print) [ -f "$st" ] || exit 1 ;;' \
    'esac' \
    'exit 0' > "$bindir/launchctl"; chmod +x "$bindir/launchctl"
  # Stub `brew` so detection resolves to the self path HERMETICALLY (the fake
  # `brew --prefix bltusb` never matches the running binary) and the self path's
  # defensive `brew services stop` no-ops against the stub, not real brew.
  # shellcheck disable=SC2016  # stub body: $1/$2 are the stub's runtime args, must NOT expand here
  printf '#!/bin/sh\ncase "$1 $2" in "--prefix bltusb") echo /nonexistent/notbltusb ;; esac\nexit 0\n' > "$bindir/brew"; chmod +x "$bindir/brew"
  HOME="$home" XDG_CONFIG_HOME="$cfg" PATH="$bindir:$PATH" BLTUSB_LANG=en "$BIN" autounlock install >/dev/null 2>&1
  if [[ -f "$plist" ]]; then
    ok "plist written"
    if command -v plutil >/dev/null 2>&1; then
      if plutil -lint "$plist" >/dev/null 2>&1; then ok "plist passes plutil -lint"; else no "plist failed plutil -lint"; fi
    else
      skip "plutil not available (non-macOS) — skipping lint"
    fi
    local pc; pc="$(cat "$plist")"
    assert_contains "plist Label"          "co.carryai.bltusb.autounlock" "$pc"
    assert_contains "plist KeepAlive"      "<key>KeepAlive</key>"         "$pc"
    assert_contains "plist RunAtLoad"      "<key>RunAtLoad</key>"         "$pc"
    assert_contains "plist daemon arg"     "__autounlock-daemon"          "$pc"
    assert_contains "plist StandardErr null" "<key>StandardErrorPath</key>" "$pc"
    case "$pc" in *"<key>StandardErrorPath</key>"*"<string>/dev/null</string>"*) ok "StandardErrorPath = /dev/null" ;; *) no "StandardErrorPath not /dev/null" ;; esac
    # No password-shaped content may ever reach the plist.
    if grep -iqE 'password|passphrase|ALFS_PASSPHRASE|[0-9]{6}-[0-9]{6}' "$plist"; then no "plist contains password-shaped content"; else ok "plist has no password-shaped content"; fi
  else
    no "install did not write plist"
  fi
  show="$(HOME="$home" XDG_CONFIG_HOME="$cfg" PATH="$bindir:$PATH" BLTUSB_LANG=en "$BIN" autounlock status 2>/dev/null)"
  case "$show" in *"State"*"on"*) ok "status → on after install" ;; *) no "status not on after install" ;; esac
  case "$show" in *"self-managed LaunchAgent"*) ok "status shows self-managed mechanism" ;; *) no "status missing self mechanism" ;; esac
  if grep -q 'AUTOUNLOCK_VIA="self"' "$cfg/bltusb/config" 2>/dev/null; then ok "AUTOUNLOCK_VIA=self persisted"; else no "AUTOUNLOCK_VIA=self not persisted"; fi

  hdr "smoke: auto-unlock uninstall removes plist + sets AUTOUNLOCK=off"
  HOME="$home" XDG_CONFIG_HOME="$cfg" PATH="$bindir:$PATH" BLTUSB_LANG=en "$BIN" autounlock uninstall >/dev/null 2>&1
  if [[ -f "$plist" ]]; then no "plist still present after uninstall"; else ok "plist removed"; fi
  if grep -q 'AUTOUNLOCK="off"' "$cfg/bltusb/config" 2>/dev/null; then ok "AUTOUNLOCK=off after uninstall"; else no "AUTOUNLOCK not off after uninstall"; fi

  smoke_autounlock_brew "$td"

  hdr "smoke: generated askpass helper carries no secret"
  # Extract make_askpass_helper() + its deps and run it in isolation, then grep
  # the generated helper for password-shaped content.
  local akf; akf="$(mktemp)"
  {
    echo 'BLTUSB_LANG_CODE=en'
    sed -n '/^t() {/,/^}/p' "$BIN"
    sed -n '/^make_askpass_helper() {/,/^}/p' "$BIN"
    # shellcheck disable=SC2016  # literal probe body, must NOT expand here
    printf '%s\n' 'h="$(make_askpass_helper)"; printf "%s\n" "$h"; cat "$h"; rm -rf "$(dirname "$h")"'
  } > "$akf"
  local akout; akout="$(bash "$akf" 2>/dev/null)"
  if printf '%s' "$akout" | grep -iqE 'password.?=|passphrase.?=|[0-9]{6}-[0-9]{6}|STUBPASS'; then
    no "askpass helper contains password-shaped content"
  else
    ok "askpass helper has no password-shaped content"
  fi
  rm -f "$akf"

  hdr "smoke: __autounlock-scan with no external drive exits 0, no dialog"
  # An osascript stub records any GUI call; the dryrun hook keeps scan/mount from
  # invoking sudo/anylinuxfs. With no external partitions the scan must be a
  # clean no-op and must NOT pop a dialog.
  local stub called; called="$td/dialog_called"
  stub="$td/osastub.sh"
  printf '#!/bin/sh\necho called >> "%s"\necho "text returned:x, gave up:false"\n' "$called" > "$stub"; chmod +x "$stub"
  local scan_rc=0
  HOME="$home" XDG_CONFIG_HOME="$cfg" BLTUSB_LANG=en \
    BLTUSB_AUTOUNLOCK_DRYRUN=1 BLTUSB_OSASCRIPT_STUB="$stub" \
    "$BIN" __autounlock-scan >/dev/null 2>&1 || scan_rc=$?
  if [[ $scan_rc -eq 0 ]]; then ok "__autounlock-scan exits 0"; else no "__autounlock-scan non-zero ($scan_rc)"; fi
  # In the dryrun path no dialog should ever fire (even if a drive happens to be
  # present, dryrun prints the intended action instead of prompting).
  if [[ -f "$called" ]]; then no "scan popped a GUI dialog (dryrun should not)"; else ok "scan popped no dialog"; fi

  hdr "smoke: auto-unlock dialog prompt is sanitized before display"
  # gui_prompt_passphrase must route the (media-derived) label through the same
  # sanitize discipline: prove a control/bidi char in a label can't reach the
  # dialog. We drive gui_prompt_passphrase with a stub that echoes back the argv
  # (the AppleScript text) so we can inspect what would be displayed.
  local gpf; gpf="$(mktemp)"
  {
    echo 'BLTUSB_LANG_CODE=en'
    sed -n '/^t() {/,/^}/p' "$BIN"
    sed -n '/^_osascript() {/,/^}/p' "$BIN"
    sed -n '/^_as_escape()/,/^}/p' "$BIN"
    sed -n '/^gui_prompt_passphrase() {/,/^}/p' "$BIN"
    # shellcheck disable=SC2016  # literal probe body, must NOT expand here
    printf '%s\n' 'pw="$(gui_prompt_passphrase "safe-label")"; printf "pw=[%s]\n" "$pw"'
  } > "$gpf"
  # Stub that returns a canned passphrase and records the argv (the AppleScript
  # program text) to a file — gui_prompt_passphrase suppresses osascript stderr,
  # so route the capture through a file (AU_STUB_ARGS) instead of stderr.
  local pstub argf; pstub="$td/pstub.sh"; argf="$td/dialog_args"
  # shellcheck disable=SC2016  # stub body: $* and $AU_STUB_ARGS expand at run time
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$AU_STUB_ARGS"\necho "text returned:CANNED, gave up:false"\n' > "$pstub"; chmod +x "$pstub"
  local gpout
  gpout="$(AU_STUB_ARGS="$argf" BLTUSB_OSASCRIPT_STUB="$pstub" bash "$gpf" 2>/dev/null)"
  case "$gpout" in *"pw=[CANNED]"*) ok "gui_prompt_passphrase returns stub passphrase on stdout" ;; *) no "gui_prompt_passphrase did not return stub passphrase (got: $gpout)" ;; esac
  # The dialog text must reference our translated prompt (proving the label flows
  # through t()/the sanitized display path, not raw into the AppleScript verb),
  # and must use `hidden answer` so the secret is never echoed on screen.
  if grep -q 'BitLocker password' "$argf" 2>/dev/null; then ok "dialog uses translated prompt text"; else no "dialog prompt text missing"; fi
  if grep -q 'hidden answer' "$argf" 2>/dev/null; then ok "dialog uses hidden answer (secret not shown)"; else no "dialog not hidden answer"; fi
  rm -f "$gpf" "$argf"

  hdr "smoke: auto-unlock dialog resists AppleScript injection via crafted volume label"
  # sanitize_display does NOT strip backslash/quote, so a label like  x" & (do
  # shell script "...")  must be neutralized by _as_escape before it reaches the
  # osascript program text — else a hostile USB label injects code on auto-mount.
  local escf escout
  escf="$(printf '%s\n%s\n' "$(sed -n '/^_as_escape()/,/^}/p' "$BIN")" '_as_escape '\''a\" & (do shell script \"x\")'\''')"
  escout="$(bash -c "$escf" 2>/dev/null)"
  case "$escout" in
    *'\\\"'*) ok "_as_escape escapes backslash+quote (breakout neutralized)" ;;
    *) no "_as_escape leaves AppleScript breakout unescaped (got: $escout)" ;;
  esac

  rm -rf "$td"
}

# ---------------------------------------------------------------------------
# smoke: auto-unlock brew-services path (v1.4.0). Exercises the REAL detector
# (no env override): a COPY of the binary is placed under a fake Homebrew
# formula prefix, and a stubbed `brew` reports that same prefix for
# `brew --prefix bltusb`, so autounlock_via() resolves to `brew` by canonical
# identity match. The stub records argv and makes `brew services list` report
# `bltusb started`. Install must invoke `brew services start bltusb`, persist
# AUTOUNLOCK_VIA="brew", status must show the brew mechanism, uninstall must
# invoke `brew services stop bltusb`. Fully offline (isolated HOME + XDG).
# ---------------------------------------------------------------------------
smoke_autounlock_brew() {
  local outer="$1" td home cfg bindir argf show fp fbin
  hdr "smoke: auto-unlock brew path delegates to \`brew services\` (real detection)"
  td="$outer/brew"; home="$td/home"; cfg="$td/cfg"; bindir="$td/bin"
  fp="$td/prefix"                      # fake `brew --prefix bltusb`
  mkdir -p "$home" "$cfg" "$bindir" "$fp/bin"
  argf="$td/brew_args"
  fbin="$fp/bin/bltusb"                # the "formula" binary = a copy of $BIN
  cp "$BIN" "$fbin"; chmod +x "$fbin"
  # Fake brew: record argv; report the fake prefix for `--prefix bltusb` (so the
  # running copy matches by identity → detector picks `brew`), and `started`.
  # shellcheck disable=SC2016  # stub body: $BREW_ARGS/$BREW_FAKE_PREFIX/$* expand at run time
  printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "$*" >> "$BREW_ARGS"' \
    'st="$HOME/.bltusb_brewstate"' \
    'case "$*" in' \
    '  "--prefix bltusb") echo "$BREW_FAKE_PREFIX" ;;' \
    '  "services start bltusb") echo started > "$st" ;;' \
    '  "services stop bltusb") echo stopped > "$st" ;;' \
    '  "services list") echo "bltusb $(cat "$st" 2>/dev/null || echo none) $HOME/foo" ;;' \
    'esac' \
    'exit 0' > "$bindir/brew"; chmod +x "$bindir/brew"
  printf '#!/bin/sh\necho ready\n' > "$bindir/anylinuxfs"; chmod +x "$bindir/anylinuxfs"
  # Stateful launchctl stub (see self test) so the verifying `_autounlock_stop_self`
  # (called by the brew install to enforce single-daemon) confirms "not loaded".
  # shellcheck disable=SC2016  # stub body vars expand at run time, not here
  printf '%s\n' \
    '#!/bin/sh' \
    'st="$HOME/.bltusb_lcstate"' \
    'case "$1" in' \
    '  bootstrap) : > "$st" ;;' \
    '  bootout) rm -f "$st" ;;' \
    '  print) [ -f "$st" ] || exit 1 ;;' \
    'esac' \
    'exit 0' > "$bindir/launchctl"; chmod +x "$bindir/launchctl"

  # Transition guard: simulate a PRIOR self-managed agent (plist + "loaded"
  # state), so the brew install must actively DEACTIVATE it (single-daemon
  # enforcement), not merely avoid writing one.
  mkdir -p "$home/Library/LaunchAgents"
  : > "$home/Library/LaunchAgents/co.carryai.bltusb.autounlock.plist"
  : > "$home/.bltusb_lcstate"

  # Run the COPIED binary (under the fake prefix), NOT $BIN, so detection matches.
  local run_env=(BREW_ARGS="$argf" BREW_FAKE_PREFIX="$fp" HOME="$home" XDG_CONFIG_HOME="$cfg" PATH="$bindir:$PATH" BLTUSB_LANG=en)
  env "${run_env[@]}" "$fbin" autounlock install >/dev/null 2>&1
  if grep -q '^services start bltusb$' "$argf" 2>/dev/null; then ok "install invoked \`brew services start bltusb\`"; else no "install did not invoke brew services start"; fi
  if grep -q 'AUTOUNLOCK_VIA="brew"' "$cfg/bltusb/config" 2>/dev/null; then ok "AUTOUNLOCK_VIA=brew persisted (real detection)"; else no "AUTOUNLOCK_VIA=brew not persisted"; fi
  # Single-daemon enforcement: the pre-seeded self plist must be GONE and the
  # self agent unloaded (bootout ran) — the brew install deactivated it.
  if [[ -f "$home/Library/LaunchAgents/co.carryai.bltusb.autounlock.plist" ]]; then no "brew install left the prior self plist (double daemon)"; else ok "brew install deactivated the prior self plist (single mechanism)"; fi
  if [[ -f "$home/.bltusb_lcstate" ]]; then no "brew install did not bootout the self agent"; else ok "brew install booted out the self agent"; fi

  show="$(env "${run_env[@]}" "$fbin" autounlock status 2>/dev/null)"
  case "$show" in *"Homebrew services"*) ok "status shows brew mechanism" ;; *) no "status missing brew mechanism (got: $show)" ;; esac
  case "$show" in *"State"*"on"*) ok "brew status → on after install" ;; *) no "brew status not on after install" ;; esac

  : > "$argf"
  env "${run_env[@]}" "$fbin" autounlock uninstall >/dev/null 2>&1
  if grep -q '^services stop bltusb$' "$argf" 2>/dev/null; then ok "uninstall invoked \`brew services stop bltusb\`"; else no "uninstall did not invoke brew services stop"; fi
  if grep -q 'AUTOUNLOCK="off"' "$cfg/bltusb/config" 2>/dev/null; then ok "AUTOUNLOCK=off after brew uninstall"; else no "AUTOUNLOCK not off after brew uninstall"; fi
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

  autounlock_hw "$dev"

  fresh_device "$dev"
}

# autounlock_hw — opt-in hardware check for the v1.4.0 auto-unlock flow. Uses the
# osascript STUB (no human needed) + the real drive: proves the dry-run scan
# selects the correct external /dev/diskXsY (skipping EFI/whole-disk), then the
# real (non-dryrun) autounlock_mount mounts ro, read-back+md5, and unmounts —
# reusing the same Keychain save/restore discipline as fresh_device. Off by
# default; enable with BLTUSB_TEST_AUTOUNLOCK=1.
autounlock_hw() {
  local dev="$1" out M f
  hdr "hardware: auto-unlock scan + ro mount (opt-in, stubbed GUI)"
  if [[ "${BLTUSB_TEST_AUTOUNLOCK:-}" != "1" ]]; then
    skip "set BLTUSB_TEST_AUTOUNLOCK=1 to run the auto-unlock hardware flow"; return
  fi
  if [[ -n "$(mp)" ]]; then skip "a volume is already mounted — unmount first"; return; fi

  # 1) dry-run scan must select the detected BitLocker partition and never an
  #    EFI/whole-disk one. The dryrun hook prints "would mount <dev> ...".
  out="$(BLTUSB_AUTOUNLOCK_DRYRUN=1 BLTUSB_LANG=en "$BIN" __autounlock-scan 2>&1)"
  case "$out" in
    *"would mount $dev"*) ok "dry-run scan selected $dev" ;;
    *"would mount /dev/disk"*[0-9]*) no "dry-run scan selected the wrong device: $out" ;;
    *) skip "dry-run scan selected nothing (drive may be host-mounted) — $out" ;;
  esac
  case "$out" in *EFI*) no "dry-run scan considered an EFI partition" ;; *) ok "dry-run scan skipped EFI/whole-disk" ;; esac

  # 2) real auto-mount path (ro). Feed a stub osascript that returns the stored
  #    passphrase so no human dialog is needed; the passphrase itself comes from
  #    the Keychain/env quiet path first, so the stub is only a fallback.
  local stub td dk kc_acct
  # The stub must contain NO secret. Decide at runtime where it fetches the
  # passphrase FROM: prefer the Keychain (the stub runs `security ...` itself,
  # given only the non-secret account id via an exported env var); fall back to
  # ALFS_PASSPHRASE passed through the environment (a value, read at runtime —
  # never baked into the stub file). Clean up the temp dir on any early return.
  dk="$(dev_key "$dev")"
  # Pick the Keychain account that actually holds a value (per-device first, then
  # the legacy global). Empty string means "no Keychain value — use the env var".
  kc_acct=""
  if security find-generic-password -s "$KC_SVC" -a "$dk" -w >/dev/null 2>&1; then
    kc_acct="$dk"
  elif security find-generic-password -s "$KC_SVC" -a "$KC_ACC" -w >/dev/null 2>&1; then
    kc_acct="$KC_ACC"
  fi
  if [[ -z "$kc_acct" && -z "${ALFS_PASSPHRASE:-}" ]]; then
    skip "no known passphrase to feed the stub"; return
  fi
  td="$(mktemp -d)"; stub="$td/osastub.sh"
  # shellcheck disable=SC2064  # expand $td now so the trap removes THIS temp dir
  trap "rm -rf '$td'" RETURN
  # The stub reads the secret at runtime from the Keychain (given the account id
  # via $KC_STUB_ACCT) or, if none, from $ALFS_PASSPHRASE in its own environment.
  # No password-shaped content is ever written into the stub file. Decline save.
  # shellcheck disable=SC2016  # stub body: $KC_STUB_ACCT/$ALFS_PASSPHRASE/$p expand at run time inside the stub, NOT here
  {
    printf '#!/bin/sh\n'
    printf 'case "$*" in\n'
    printf '  *hidden*)\n'
    printf '    if [ -n "$KC_STUB_ACCT" ]; then\n'
    printf '      p="$(security find-generic-password -s "%s" -a "$KC_STUB_ACCT" -w 2>/dev/null)"\n' "$KC_SVC"
    printf '    else\n'
    printf '      p="$ALFS_PASSPHRASE"\n'
    printf '    fi\n'
    printf '    printf "text returned:%%s, gave up:false\\n" "$p" ;;\n'
    printf '  *) echo "button returned:Not now" ;;\n'
    printf 'esac\n'
  } > "$stub"; chmod +x "$stub"
  settle
  KC_STUB_ACCT="$kc_acct" BLTUSB_OSASCRIPT_STUB="$stub" BLTUSB_LANG=en "$BIN" __autounlock-scan >/dev/null 2>&1
  wait_mount; M="$(mp)"
  if [[ -n "$M" ]]; then
    ok "auto-unlock mounted ro: $M"
    local probe="$M/bltusb_selftest_au_$$"
    if touch "$probe" 2>/dev/null; then no "auto-unlock mount was writable (must be ro)"; rm -f "$probe"; else ok "auto-unlock mount is read-only"; fi
    f="$(find "$M" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | head -1)"
    if [[ -n "$f" ]]; then
      if md5 -q "$f" >/dev/null 2>&1; then ok "read existing file via auto-unlock mount"; else no "could not read file via auto-unlock mount"; fi
    fi
    "$BIN" umount >/dev/null 2>&1
    if [[ -z "$(mp)" ]]; then ok "auto-unlock volume unmounted"; else no "still mounted after umount"; fi
  else
    no "auto-unlock scan did not mount the drive"
  fi
  trap - RETURN; rm -rf "$td"; settle
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
