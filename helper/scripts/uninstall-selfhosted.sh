#!/bin/bash
# uninstall-selfhosted.sh — MODE B uninstaller. Removes the root LaunchDaemon,
# its plist, and the entire root-owned install tree.
#
# Loud on failure: a leftover ROOT service or a leftover root-owned binary is a
# security-relevant residue, so we NEVER hide a failed step — we warn visibly and
# exit non-zero if anything could not be removed, so you know to investigate.
#
# Run:  sudo helper/scripts/uninstall-selfhosted.sh
set -uo pipefail   # NOT -e: we want to attempt every step and report all failures

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run as root:  sudo $0" >&2
  exit 1
fi

LABEL="co.carryai.bltusb.helperd"
INSTALL_ROOT="/Library/Application Support/bltusb"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

log()  { printf '\033[1;34m[uninstall]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[   ok    ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[  WARN   ]\033[0m %s\n' "$*"; }

FAIL=0

# ---- 1. bootout the system daemon -------------------------------------------
log "1/3 launchctl bootout system/$LABEL"
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  if launchctl bootout "system/$LABEL" 2>/dev/null; then
    ok "booted out system/$LABEL"
  else
    warn "FAILED to bootout system/$LABEL — a ROOT service may STILL BE RUNNING."
    warn "   investigate:  sudo launchctl print system/$LABEL"
    FAIL=1
  fi
else
  ok "not loaded (already gone)"
fi

# ---- 2. remove the plist ----------------------------------------------------
log "2/3 remove $PLIST"
if [ -e "$PLIST" ]; then
  if rm -f "$PLIST"; then ok "removed plist"; else warn "FAILED to remove $PLIST"; FAIL=1; fi
else
  ok "plist already gone"
fi

# ---- 3. remove the root-owned install tree ----------------------------------
log "3/3 remove $INSTALL_ROOT (root-owned binaries + peer-requirement.txt)"
if [ -e "$INSTALL_ROOT" ]; then
  if rm -rf "$INSTALL_ROOT"; then ok "removed install tree"; else warn "FAILED to remove $INSTALL_ROOT"; FAIL=1; fi
else
  ok "install tree already gone"
fi

echo
log "verify nothing is left:"
if launchctl print "system/$LABEL" >/dev/null 2>&1; then warn "STILL LOADED: system/$LABEL"; FAIL=1; else ok "daemon not loaded"; fi
if pgrep -f "bltusb-helperd" >/dev/null 2>&1;          then warn "daemon process STILL RUNNING";       FAIL=1; else ok "no daemon process"; fi
if [ -e "$PLIST" ];        then warn "STILL EXISTS: $PLIST";        FAIL=1; else ok "plist gone"; fi
if [ -e "$INSTALL_ROOT" ]; then warn "STILL EXISTS: $INSTALL_ROOT"; FAIL=1; else ok "install tree gone"; fi

echo
if [ "$FAIL" -ne 0 ]; then
  warn "UNINSTALL INCOMPLETE — see the WARN lines above and remove the residue manually."
  exit 1
fi
ok "MODE B UNINSTALL COMPLETE — no bltusb root service, plist, or root-owned binary remains."
