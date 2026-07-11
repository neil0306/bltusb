#!/bin/bash
# client-call.sh — how the UNPRIVILEGED user (or the bash `bltusb`) invokes the
# 4 helper ops against the installed MODE B root daemon. ZERO sudo at runtime.
#
# After `sudo install-selfhosted.sh`, the root LaunchDaemon owns the
# co.carryai.bltusb.helperd Mach service and the client is at:
#     /Library/Application Support/bltusb/bin/bltusb-client
# Only THAT client (cdhash-pinned) is accepted; any other binary is rejected
# notAuthorized by the daemon.
#
# Usage:
#   client-call.sh list
#   client-call.sh probe   <diskNsM>
#   client-call.sh mount   <diskNsM> <fs_type> </Volumes/Name> [ro|rw]   # passphrase on stdin
#   client-call.sh unmount </Volumes/Name>
set -euo pipefail

CLIENT="/Library/Application Support/bltusb/bin/bltusb-client"
if [ ! -x "$CLIENT" ]; then
  echo "error: $CLIENT not found — run 'sudo helper/scripts/install-selfhosted.sh' first" >&2
  exit 1
fi

# NOTE: no sudo. The unprivileged user connects to the already-running root
# daemon over XPC; the daemon re-validates every input and re-runs every guard.
exec "$CLIENT" "$@"

# ---------------------------------------------------------------------------
# How the existing bash `bltusb` wires in (replacing the `sudo anylinuxfs` path):
#
#   # instead of:  sudo anylinuxfs mount /dev/disk4s1 -o ro ...
#   # do:
#   CLIENT="/Library/Application Support/bltusb/bin/bltusb-client"
#   mp="$(printf '%s' "$volume_password" | "$CLIENT" mount disk4s1 bitlocker /Volumes/Backup ro)"
#   # -> passphrase piped on STDIN (never argv, never ALFS_PASSPHRASE in the bash
#   #    env); no sudo, no SUDO_ASKPASS admin prompt. The Keychain/dialog UX in
#   #    bltusb is unchanged — only the privileged mount call is replaced.
#
#   # list / probe / unmount likewise:
#   "$CLIENT" list
#   "$CLIENT" probe   disk4s1
#   "$CLIENT" unmount /Volumes/Backup
# ---------------------------------------------------------------------------
