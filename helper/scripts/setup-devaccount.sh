#!/bin/bash
# setup-devaccount.sh — MODE A (paid Apple Developer account) SCAFFOLD.
#
# STATUS: SCAFFOLD / PRE-FLIGHT ONLY. This cannot be completed in the current
# build environment (no Apple Developer Program membership, no Xcode, no MDM).
# It WARNS about the requirements, detects what is present, and GUIDES the
# maintainer through the Developer-ID-signed + notarized + SMAppService path.
# Every step that needs the account/Xcode is clearly marked TODO and GUARDED so
# the script NEVER hard-fails on a machine without them — it detects + instructs.
#
# Mode A yields a distributable, Gatekeeper-happy, notarized, MDM-deployable
# helper (SMAppService LaunchDaemon, PPPC, com.apple.servicemanagement auto-
# approve). Mode B (install-selfhosted.sh) is personal-machine-only. See
# docs/DEPLOY-MODES.md.
set -uo pipefail   # NOT -e: pre-flight should report ALL gaps, not stop at the first.

log()  { printf '\033[1;34m[devacct]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok   ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ WARN  ]\033[0m %s\n' "$*"; }
todo() { printf '\033[1;35m[ TODO  ]\033[0m %s\n' "$*"; }

echo "=================================================================="
echo " MODE A — Developer-ID signed + notarized helper (scaffold)"
echo "=================================================================="
echo
warn "REQUIREMENTS (Mode A is heavyweight — read before proceeding):"
warn "  · Apple Developer Program membership (paid, ~USD 99/yr) — for a"
warn "    Developer ID Application cert + notarization (notarytool)."
warn "  · Xcode (full, NOT just Command Line Tools): ~15–40 GB free disk,"
warn "    8 GB+ RAM recommended, and a long first-launch install."
warn "  · An MDM to push the PPPC (Full Disk Access + Automation) and the"
warn "    com.apple.servicemanagement (TeamIdentifier) auto-approval profiles."
echo

READY=1

# ---- disk / RAM sanity ------------------------------------------------------
log "checking disk space (Xcode needs ~15–40 GB)"
AVAIL_KB="$(df -k / | awk 'NR==2{print $4}')"
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
if [ "$AVAIL_GB" -lt 40 ]; then
  warn "only ${AVAIL_GB} GB free on / — Xcode + notarization may not fit (want >=40 GB)."
else
  ok "${AVAIL_GB} GB free on /"
fi

# ---- Xcode present? ---------------------------------------------------------
log "checking for a full Xcode toolchain"
XSEL="$(xcode-select -p 2>/dev/null || true)"
if [ -n "$XSEL" ] && [ -d "$XSEL" ] && echo "$XSEL" | grep -q "Xcode.app"; then
  ok "Xcode selected: $XSEL"
  if command -v xcodebuild >/dev/null 2>&1; then ok "xcodebuild: $(xcodebuild -version 2>/dev/null | head -1)"; fi
else
  READY=0
  todo "Full Xcode not selected (found: '${XSEL:-none}')."
  todo "  1) install Xcode from the App Store (or 'xcodes install'),"
  todo "  2) sudo xcode-select -s /Applications/Xcode.app/Contents/Developer,"
  todo "  3) sudo xcodebuild -license accept"
fi

# ---- notarytool / credentials ----------------------------------------------
log "checking notarization tooling"
if xcrun --find notarytool >/dev/null 2>&1; then
  ok "notarytool present"
  todo "store credentials once (interactive; needs your Apple ID + app-specific"
  todo "  password + Team ID):"
  todo "      xcrun notarytool store-credentials bltusb-notary \\"
  todo "        --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-pw>"
else
  READY=0
  todo "notarytool unavailable (needs full Xcode)."
fi

# ---- signing identity -------------------------------------------------------
log "checking for a Developer ID Application signing identity"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  IDENT="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1)"
  ok "found: $IDENT"
  TEAMID="$(printf '%s' "$IDENT" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"
  [ -n "$TEAMID" ] && ok "Team ID: $TEAMID"
else
  READY=0
  todo "No 'Developer ID Application' identity in the login keychain."
  todo "  In Xcode: Settings > Accounts > (your account) > Manage Certificates >"
  todo "  '+' > 'Developer ID Application'. Or use 'xcodebuild -allowProvisioningUpdates'."
fi

echo
echo "------------------------------------------------------------------"
echo " GUARDED BUILD/SIGN/NOTARIZE/REGISTER STEPS (run only when READY)"
echo "------------------------------------------------------------------"

if [ "$READY" -ne 1 ]; then
  warn "Pre-flight found gaps above (TODO lines). NOT running the signed build."
  warn "Resolve the TODOs, then re-run this script. Exiting 0 (pre-flight only)."
  echo
  todo "When ready, this script would then:"
  todo "  1. Bake the real Team ID into kPeerCodeSigningRequirement (replace <TEAMID>)"
  todo "     in Sources/bltusb-helperd/XPCServer.swift, so requirementIsConfigured=true"
  todo "     and the daemon authenticates against the Team ID (Mode-A path; the"
  todo "     Mode-B peer-requirement.txt override becomes unreachable)."
  todo "  2. swift build -c release   (NO -D BLTUSB_SELFHOSTED / NO -D BLTUSB_DEV_REQUIREMENT)."
  todo "  3. Assemble a Developer-ID app bundle with the daemon at Contents/MacOS and"
  todo "     Contents/Library/LaunchDaemons/co.carryai.bltusb.helperd.plist"
  todo "     (BundleProgram + MachServices matching kHelperMachServiceName)."
  todo "  4. codesign --options runtime --timestamp -s \"Developer ID Application: … (<TEAMID>)\""
  todo "     the client, the daemon, and the bundle."
  todo "  5. xcrun notarytool submit <bundle.zip> --keychain-profile bltusb-notary --wait"
  todo "     then  xcrun stapler staple <bundle>."
  todo "  6. Register the LaunchDaemon via SMAppService:  bltusb-helperd --register"
  todo "     (needs the com.apple.servicemanagement MDM profile to auto-approve)."
  todo "  7. Push PPPC (Full Disk Access for the daemon, Automation for the agent) via MDM."
  exit 0
fi

# READY path (only reached on a fully-provisioned machine — cannot run here).
ok "Pre-flight PASSED. Proceeding to the signed Mode-A build."
todo "IMPLEMENT-ME on the provisioned machine: steps 1–7 listed above. This block"
todo "is intentionally left as a guarded no-op in the scaffold so it cannot run"
todo "half-configured. Fill in with the maintainer's real Team ID + bundle layout."
