#!/bin/bash
# dev-down.sh — tear the dev harness down and leave the machine as we found it.
#   bootout the LaunchAgent from gui/UID, remove the plist, the pinned
#   requirement, the staged/signed binaries, and the dev support dir.
# shellcheck source=helper/scripts/dev-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dev-common.sh"

log "bootout LaunchAgent $LABEL from $GUI_DOMAIN"
if launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null; then
  ok "booted out"
else
  warn "not loaded (already gone)"
fi

# Kill any lingering staged daemon process (should exit on bootout, but be sure).
pkill -f "$DAEMON_DEV" 2>/dev/null && log "killed lingering daemon" || true

log "remove dev staging dir: $DEV_ROOT"
rm -rf "$DEV_ROOT"
ok "removed"

echo
log "verify nothing is left:"
echo -n "  launchctl print $GUI_DOMAIN/$LABEL => "
if launchctl print "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1; then
  warn "STILL PRESENT"
else
  ok "gone"
fi
echo -n "  daemon process                     => "
if pgrep -f "bltusb-helperd" >/dev/null 2>&1; then warn "STILL RUNNING"; else ok "none"; fi
echo -n "  dev support dir                    => "
if [ -e "$DEV_ROOT" ]; then warn "STILL EXISTS: $DEV_ROOT"; else ok "removed"; fi
