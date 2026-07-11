#!/bin/bash
# dev-verify.sh — prove the boundary works, BOTH ways.
#   A. `diskutil list external physical` (ground truth).
#   B. authorized client -> list-external over XPC => ACCEPTED, returns partitions.
#   C. a DIFFERENT ("evil") ad-hoc binary -> list-external => REJECTED notAuthorized.
# shellcheck source=helper/scripts/dev-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dev-common.sh"

echo "=================================================================="
echo "A. GROUND TRUTH: diskutil list external physical"
echo "=================================================================="
/usr/sbin/diskutil list external physical

echo
echo "=================================================================="
echo "B. AUTHORIZED client -> list-external over XPC (expect: ACCEPTED)"
echo "=================================================================="
set +e
OUT_OK="$("$CLIENT_DEV" list 2>&1)"; RC_OK=$?
set -e
echo "$OUT_OK"
echo "(exit=$RC_OK)"
if [ $RC_OK -eq 0 ] && [ -n "$OUT_OK" ]; then
  ok "authorized client ACCEPTED — helper returned partition rows over XPC"
else
  warn "authorized client did NOT get rows (rc=$RC_OK) — see $LOG_ERR"
fi

echo
echo "=================================================================="
echo "C. UNAUTHORIZED client (different ad-hoc identity/cdhash)"
echo "   -> list-external over XPC (expect: REJECTED notAuthorized)"
echo "=================================================================="
set +e
OUT_EVIL="$("$CLIENT_EVIL" list 2>&1)"; RC_EVIL=$?
set -e
echo "$OUT_EVIL"
echo "(exit=$RC_EVIL)"
if echo "$OUT_EVIL" | grep -qi "notAuthorized"; then
  ok "unauthorized client REJECTED with notAuthorized — boundary holds"
elif [ $RC_EVIL -ne 0 ] && [ -z "$OUT_EVIL" ]; then
  ok "unauthorized client got NO data (rc=$RC_EVIL) — kernel dropped it pre-delivery"
else
  warn "unexpected: evil client was not clearly rejected"
fi

echo
echo "=================================================================="
echo "SUMMARY"
echo "=================================================================="
printf '  ground-truth external partitions : %s\n' "$(/usr/sbin/diskutil list external physical | grep -cE 'disk[0-9]+s[0-9]+')"
printf '  authorized  client rc            : %s (0 = accepted)\n' "$RC_OK"
printf '  unauthorized client rc           : %s (non-0 = rejected)\n' "$RC_EVIL"
