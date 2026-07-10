#!/bin/bash
# dev-common.sh — shared config for the LOCAL DEV harness that proves the
# bltusb-helperd XPC + caller-authentication boundary works with ad-hoc signing,
# a per-user LaunchAgent, and NO Apple account / Xcode / root / MDM.
#
# This harness NEVER installs a system/root daemon. It only bootstraps a
# per-user (gui domain) LaunchAgent. It does not touch the bash `bltusb`.
set -euo pipefail

# Repo layout
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIG="debug"
BIN_DIR="$HELPER_DIR/.build/$BUILD_CONFIG"

# Where we stage the ad-hoc-signed dev binaries + plist (kept out of the repo).
DEV_ROOT="${BLTUSB_DEV_ROOT:-$HOME/Library/Application Support/bltusb-dev}"
DEV_BIN="$DEV_ROOT/bin"
DAEMON_SRC="$BIN_DIR/bltusb-helperd"
CLIENT_SRC="$BIN_DIR/bltusb-client"
DAEMON_DEV="$DEV_BIN/bltusb-helperd"
CLIENT_DEV="$DEV_BIN/bltusb-client"
# A DIFFERENT binary used to prove the negative case (unauthorized => rejected).
CLIENT_EVIL="$DEV_BIN/bltusb-client-evil"

# The agent-owned file the (dev-flagged) daemon reads its pinned requirement from.
# MUST match DevRequirement.path in Sources/bltusb-helperd/DevRequirement.swift.
REQ_FILE="$DEV_ROOT/peer-requirement.txt"

# Per-user LaunchAgent
LABEL="co.carryai.bltusb.helperd.dev"
MACH_SERVICE="co.carryai.bltusb.helperd"   # matches kHelperMachServiceName
PLIST="$DEV_ROOT/$LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"
LOG_OUT="$DEV_ROOT/helperd.out.log"
LOG_ERR="$DEV_ROOT/helperd.err.log"

# Ad-hoc code signing identifiers. Ad-hoc identity is "-" (no cert, no Apple ID).
CLIENT_IDENTIFIER="co.carryai.bltusb.client.dev"
DAEMON_IDENTIFIER="co.carryai.bltusb.helperd.dev"
EVIL_IDENTIFIER="co.carryai.bltusb.client.evil"

# Extract the CandidateCDHash (the cdhash) of a signed binary.
cdhash_of() {
  # codesign -dvvv prints e.g. "CandidateCDHash sha256=<hex>" and "CDHash=<hex>".
  # We want the SHA-256 CDHash used by SecCode requirements: `cdhash H"<hex>"`.
  codesign -dvvv "$1" 2>&1 | awk -F= '/CandidateCDHash/{print $2; exit}'
}

log()  { printf '\033[1;34m[dev]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
