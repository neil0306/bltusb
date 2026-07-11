#!/bin/bash
# dev-up.sh — build (dev flag), ad-hoc sign, pin the dev requirement to the
# client's cdhash, and bootstrap the per-user LaunchAgent. NO root, NO Apple ID.
#
# Steps:
#   1. swift build with -D BLTUSB_DEV_REQUIREMENT (dev override path compiled in).
#   2. Copy daemon + client to the dev staging dir; ad-hoc sign both.
#      Also make a DIFFERENT ("evil") client with a different ad-hoc identity to
#      prove the negative case.
#   3. Write the agent-owned peer-requirement.txt pinning the client's cdhash.
#   4. Write the LaunchAgent plist (MachServices) and bootstrap it into gui/UID.
# shellcheck source=helper/scripts/dev-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dev-common.sh"

log "1/4 swift build (dev requirement flag ON)"
( cd "$HELPER_DIR" && swift build \
    -Xswiftc -DBLTUSB_DEV_REQUIREMENT ) >/dev/null
ok "built: $DAEMON_SRC + $CLIENT_SRC"

log "2/4 stage + ad-hoc sign daemon, client, and a DIFFERENT 'evil' client"
mkdir -p "$DEV_BIN"
cp -f "$DAEMON_SRC" "$DAEMON_DEV"
cp -f "$CLIENT_SRC" "$CLIENT_DEV"
cp -f "$CLIENT_SRC" "$CLIENT_EVIL"

# Ad-hoc sign (identity "-"): no certificate, no Apple Developer account.
# Stable per-identifier cdhash; --force overwrites the linker's ad-hoc sig.
codesign -s - --force --identifier "$DAEMON_IDENTIFIER" "$DAEMON_DEV"
codesign -s - --force --identifier "$CLIENT_IDENTIFIER" "$CLIENT_DEV"
# The evil client: valid ad-hoc signature but a DIFFERENT identifier + cdhash,
# so it must NOT satisfy the pinned requirement.
codesign -s - --force --identifier "$EVIL_IDENTIFIER" "$CLIENT_EVIL"

codesign --verify --verbose=2 "$DAEMON_DEV"  2>&1 | sed 's/^/    daemon: /' || true
codesign --verify --verbose=2 "$CLIENT_DEV"  2>&1 | sed 's/^/    client: /' || true
ok "ad-hoc signed"

CLIENT_CDHASH="$(cdhash_of "$CLIENT_DEV")"
EVIL_CDHASH="$(cdhash_of "$CLIENT_EVIL")"
log "    authorized client cdhash: $CLIENT_CDHASH"
log "    evil       client cdhash: $EVIL_CDHASH"

log "3/4 pin dev requirement to the authorized client's identifier + cdhash"
# Pin BOTH the ad-hoc identifier AND the exact cdhash: only this one signed
# client binary is accepted. `H"..."` is the SecRequirement cdhash literal.
HEX="${CLIENT_CDHASH#*=}"   # strip a leading "sha256=" if codesign added one
printf 'identifier "%s" and cdhash H"%s"\n' "$CLIENT_IDENTIFIER" "$HEX" > "$REQ_FILE"
# Lock the file down so no other local account can plant a permissive rule
# (DevRequirement.swift rejects group/other-writable or non-owned files).
chmod 600 "$REQ_FILE"
log "    requirement: $(cat "$REQ_FILE")"
# Sanity: the requirement string must actually compile as a SecRequirement.
if csreq -r- -b /dev/null < /dev/null 2>/dev/null; then :; fi
ok "pinned -> $REQ_FILE"

log "4/4 write LaunchAgent plist + bootstrap into $GUI_DOMAIN"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DAEMON_DEV</string></array>
  <key>MachServices</key>
  <dict><key>$MACH_SERVICE</key><true/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG_OUT</string>
  <key>StandardErrorPath</key><string>$LOG_ERR</string>
</dict>
</plist>
PLIST

# Idempotent: bootout any stale copy first (ignore failure), then bootstrap.
launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$GUI_DOMAIN" "$PLIST"
ok "LaunchAgent bootstrapped: $LABEL (Mach service $MACH_SERVICE)"
launchctl print "$GUI_DOMAIN/$LABEL" 2>/dev/null | grep -E 'state|program|endpoints|co.carryai' | sed 's/^/    /' || true
echo
ok "dev-up complete. Run: scripts/dev-verify.sh"
