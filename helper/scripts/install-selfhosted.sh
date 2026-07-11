#!/bin/bash
# install-selfhosted.sh — MODE B (personal self-hosted) installer.
#
# Puts bltusb-helperd in as a ROOT system LaunchDaemon and installs the
# unprivileged bltusb-client alongside it, so the user thereafter talks to the
# helper with ZERO further sudo (like `cloudflared service install`).
#
# WHAT NEEDS ROOT: only this installer (it writes under /Library and does one
# `launchctl bootstrap system`). RUNTIME is zero-sudo: the unprivileged client
# connects to the already-running root daemon over an authenticated XPC Mach
# service.
#
# SECURITY INVARIANTS this installer establishes (see docs/DEPLOY-MODES.md):
#   · daemon + client installed ROOT-OWNED (root:wheel), mode 0755, under a
#     non-user-writable tree — a user-writable privileged binary is exactly the
#     backdoor the old --nopasswd path was; this is why root ownership is the
#     critical invariant, NOT a cosmetic detail.
#   · caller-auth is cdhash-PINNED to the one installed client (ad-hoc has no
#     Team ID). The pin lives in a ROOT-OWNED 0644 peer-requirement.txt the
#     daemon reads; the daemon ignores it unless it is root-owned + not
#     world-writable (fail closed) — see SelfHostedRequirement.swift.
#   · the daemon is built Mode-B (`-D BLTUSB_SELFHOSTED`): the peer-requirement
#     file is consulted ONLY because kPeerCodeSigningRequirement is still the
#     <TEAMID> placeholder. A real Team-ID (Mode A) build ignores it entirely.
#
# Idempotent: an existing instance is booted out first.
#
# Run:  sudo helper/scripts/install-selfhosted.sh
set -euo pipefail

# ---- must be root -----------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "error: run as root:  sudo $0" >&2
  exit 1
fi

# The unprivileged user we build/sign as and pin (SUDO_USER when invoked via sudo).
BUILD_USER="${SUDO_USER:-$(id -un)}"
if [ "$BUILD_USER" = "root" ]; then
  echo "error: run via 'sudo' from your normal account (need SUDO_USER to build" >&2
  echo "       + own the client cdhash), not a root login shell." >&2
  exit 1
fi

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- install layout (root-owned) --------------------------------------------
LABEL="co.carryai.bltusb.helperd"
MACH_SERVICE="co.carryai.bltusb.helperd"
INSTALL_ROOT="/Library/Application Support/bltusb"
INSTALL_BIN="$INSTALL_ROOT/bin"
DAEMON_DST="$INSTALL_BIN/bltusb-helperd"
CLIENT_DST="$INSTALL_BIN/bltusb-client"
REQ_FILE="$INSTALL_ROOT/peer-requirement.txt"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

# Ad-hoc signing identifiers (identity "-", no cert, no Apple account).
DAEMON_IDENTIFIER="co.carryai.bltusb.helperd.selfhosted"
CLIENT_IDENTIFIER="co.carryai.bltusb.client.selfhosted"

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[   ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ warn  ]\033[0m %s\n' "$*"; }

# ---- 1. build release (Mode B) as the normal user ---------------------------
log "1/6 swift build -c release (Mode B: -D BLTUSB_SELFHOSTED) as user '$BUILD_USER'"
sudo -u "$BUILD_USER" bash -c "cd '$HELPER_DIR' && swift build -c release -Xswiftc -DBLTUSB_SELFHOSTED" >/dev/null
BIN_DIR="$(sudo -u "$BUILD_USER" bash -c "cd '$HELPER_DIR' && swift build -c release -Xswiftc -DBLTUSB_SELFHOSTED --show-bin-path")"
DAEMON_SRC="$BIN_DIR/bltusb-helperd"
CLIENT_SRC="$BIN_DIR/bltusb-client"
[ -x "$DAEMON_SRC" ] && [ -x "$CLIENT_SRC" ] || { echo "error: build did not produce binaries" >&2; exit 1; }
ok "built: $DAEMON_SRC + $CLIENT_SRC"

# ---- 2. install root-owned, non-user-writable -------------------------------
log "2/6 install ROOT-OWNED (root:wheel 0755) under $INSTALL_BIN"
install -d -o root -g wheel -m 0755 "$INSTALL_ROOT"
install -d -o root -g wheel -m 0755 "$INSTALL_BIN"
install -o root -g wheel -m 0755 "$DAEMON_SRC" "$DAEMON_DST"
install -o root -g wheel -m 0755 "$CLIENT_SRC" "$CLIENT_DST"
ok "installed root-owned daemon + client"

# ---- 3. ad-hoc sign the INSTALLED copies ------------------------------------
# Sign in place so the cdhash we pin is the cdhash of the exact installed file.
log "3/6 ad-hoc sign installed daemon + client (identity '-', hardened runtime)"
codesign -s - --force --options runtime --identifier "$DAEMON_IDENTIFIER" "$DAEMON_DST"
codesign -s - --force --options runtime --identifier "$CLIENT_IDENTIFIER" "$CLIENT_DST"
codesign --verify --verbose=2 "$DAEMON_DST" 2>&1 | sed 's/^/    daemon: /' || true
codesign --verify --verbose=2 "$CLIENT_DST" 2>&1 | sed 's/^/    client: /' || true
ok "ad-hoc signed the installed copies"

# ---- 4. pin the caller-auth requirement to the installed client's cdhash ----
log "4/6 pin caller-auth requirement to the installed client cdhash"
CDH="$(codesign -dvvv "$CLIENT_DST" 2>&1 | awk -F= '/CandidateCDHash /{print $2; exit}')"
HEX="${CDH#*=}"; HEX="$(printf '%s' "$HEX" | tr -d ' ')"
[ -n "$HEX" ] || { echo "error: could not read client cdhash" >&2; exit 1; }
REQ="identifier \"$CLIENT_IDENTIFIER\" and cdhash H\"$HEX\""
# Sanity: it must compile as a SecRequirement, and the client must satisfy it.
printf '%s\n' "$REQ" | csreq -r- -b /dev/null 2>/dev/null || { echo "error: requirement string does not compile" >&2; exit 1; }
codesign --verify -R="$REQ" "$CLIENT_DST" 2>/dev/null || { echo "error: installed client does not satisfy its own pin" >&2; exit 1; }
# Write ROOT-OWNED 0644 (world-readable, root-only-writable). The daemon rejects
# a non-root-owned or world-writable file (SelfHostedRequirement.swift).
printf '%s\n' "$REQ" > "$REQ_FILE"
chown root:wheel "$REQ_FILE"
chmod 0644 "$REQ_FILE"
ok "pinned -> $REQ_FILE"
log "    requirement: $REQ"

# ---- 5. write the system LaunchDaemon plist ---------------------------------
log "5/6 write system LaunchDaemon plist -> $PLIST"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>$DAEMON_DST</string>
  <key>ProgramArguments</key>
  <array><string>$DAEMON_DST</string></array>
  <key>MachServices</key>
  <dict><key>$MACH_SERVICE</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 0644 "$PLIST"
ok "wrote plist (root:wheel 0644)"

# ---- 6. (re)bootstrap into the system domain --------------------------------
log "6/6 bootstrap into system domain (idempotent: bootout any existing first)"
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl enable "system/$LABEL" 2>/dev/null || true
ok "bootstrapped system/$LABEL"
launchctl print "system/$LABEL" 2>/dev/null | grep -E 'state|program|endpoints' | sed 's/^/    /' || true

echo
ok "MODE B INSTALL COMPLETE — root LaunchDaemon '$LABEL' is live."
echo   "     Runtime is now ZERO-SUDO. The unprivileged client is at:"
echo   "         $CLIENT_DST"
echo   "     Try:   \"$CLIENT_DST\" list                # works now (no FDA needed)"
echo
warn "ONE-TIME MANUAL STEP REQUIRED FOR MOUNTING:"
echo   "     The daemon needs Full Disk Access to read raw disk devices (macOS TCC"
echo   "     restricts this even for a root daemon). Until granted, mounts fail"
echo   "     CLOSED with 'weakDeviceIdentity'. list/probe of metadata work without it."
echo   "     Grant it once:"
echo   "       System Settings ▸ Privacy & Security ▸ Full Disk Access ▸ [+] ▸ add:"
echo   "         $DAEMON_DST"
echo   "       then:  sudo launchctl kickstart -k system/$LABEL"
echo   "     (Mode A/MDM auto-grants this via a PPPC profile; Mode B grants it by hand.)"
echo
echo   "     See:   helper/scripts/client-call.sh   and   docs/DEPLOY-MODES.md"
echo   "     Uninstall:  sudo helper/scripts/uninstall-selfhosted.sh"
echo   "     NOTE: on any client/daemon rebuild you MUST re-run this installer to"
echo   "           re-pin the cdhash (a new build has a new cdhash)."
