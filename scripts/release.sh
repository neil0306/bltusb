#!/usr/bin/env bash
#
# release.sh — cut a new bltusb release end-to-end.
#
#   scripts/release.sh <version>     # explicit, e.g. 1.2.2
#   scripts/release.sh patch         # bump last number  (1.2.1 -> 1.2.2)
#   scripts/release.sh minor         # 1.2.1 -> 1.3.0
#   scripts/release.sh major         # 1.2.1 -> 2.0.0
#   scripts/release.sh --dry-run patch   # show the plan, change nothing
#
# What it does, in order:
#   1. bump VERSION in ./bltusb
#   2. run shellcheck + smoke tests (abort on failure)
#   3. commit, tag vX.Y.Z, push main + tag
#   4. create the GitHub release
#   5. download the release tarball, compute its sha256
#   6. update url + sha256 in the Homebrew tap formula, commit & push the tap
#
# Requirements: run from the bltusb repo; `gh` authenticated; a clean git tree.
# The tap repo defaults to ../homebrew-tap (override with TAP_DIR).
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP_DIR="${TAP_DIR:-$REPO_DIR/../homebrew-tap}"
FORMULA_REL="Formula/bltusb.rb"
GH_SLUG="neil0306/bltusb"
DRY_RUN=0

say()  { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# Run a command from its argument vector (no eval): each argument is passed
# through verbatim, so paths with spaces, quotes, or other shell metacharacters
# (e.g. a TAP_DIR like /home/o'neil/homebrew-tap) can never be word-split or
# injected into the shell.
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '   \033[2m[dry-run] %s\033[0m\n' "$*"; else "$@"; fi; }

# ---- args ----
[[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=1; shift; }
BUMP="${1:-}"
[[ -n "$BUMP" ]] || die "usage: $0 [--dry-run] <version|patch|minor|major>"

cd "$REPO_DIR"

# ---- preconditions ----
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found"
command -v shellcheck >/dev/null 2>&1 || die "shellcheck not found"
[[ -f bltusb ]] || die "must run inside the bltusb repo (no ./bltusb here)"
if [[ $DRY_RUN -eq 0 ]] && [[ -n "$(git status --porcelain)" ]]; then
  die "git tree is not clean — commit or stash first"
fi
if [[ $DRY_RUN -eq 0 && -d "$TAP_DIR/.git" ]] && [[ -n "$(git -C "$TAP_DIR" status --porcelain)" ]]; then
  die "tap repo ($TAP_DIR) is not clean — commit or stash first"
fi

CUR="$(grep -m1 '^VERSION=' bltusb | sed -E 's/.*"(.*)".*/\1/')"
[[ "$CUR" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cannot parse current VERSION ($CUR)"
IFS='.' read -r MA MI PA <<< "$CUR"

case "$BUMP" in
  patch) NEW="$MA.$MI.$((PA+1))" ;;
  minor) NEW="$MA.$((MI+1)).0" ;;
  major) NEW="$((MA+1)).0.0" ;;
  [0-9]*.[0-9]*.[0-9]*) NEW="$BUMP" ;;
  *) die "invalid version/bump: $BUMP" ;;
esac
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "computed version invalid: $NEW"
TAG="v$NEW"

DR_LABEL=""; [[ $DRY_RUN -eq 1 ]] && DR_LABEL="  [DRY RUN]"
say "Release $CUR → $NEW  (tag $TAG)$DR_LABEL"
git rev-parse "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists"

# ---- 1. bump VERSION ----
say "Bump VERSION in ./bltusb"
if [[ $DRY_RUN -eq 0 ]]; then
  perl -pi -e "s/^VERSION=\".*\"/VERSION=\"$NEW\"/" bltusb
  grep -q "^VERSION=\"$NEW\"" bltusb || die "failed to update VERSION"
fi
ok "VERSION=$NEW"

# ---- 2. tests ----
say "Lint + smoke tests"
run shellcheck bltusb test/bltusb_test.sh
if [[ $DRY_RUN -eq 1 ]]; then
  run bash test/bltusb_test.sh smoke
else
  bash test/bltusb_test.sh smoke >/dev/null
fi
ok "shellcheck + smoke passed"

# ---- 3. commit, tag, push ----
say "Commit, tag, push"
run git add bltusb
run git commit -m "release: $TAG"
run git tag -a "$TAG" -m "bltusb $TAG"
run git push origin HEAD
run git push origin "$TAG"
ok "pushed $TAG"

# ---- 4. GitHub release ----
say "Create GitHub release"
run gh release create "$TAG" --title "bltusb $TAG" --generate-notes
ok "release created"

# ---- 5. sha256 of the tarball ----
say "Compute tarball sha256"
TARBALL_URL="https://github.com/$GH_SLUG/archive/refs/tags/$TAG.tar.gz"
if [[ $DRY_RUN -eq 1 ]]; then
  SHA="<computed-from-$TAG-tarball>"
  printf '   \033[2m[dry-run] would sha256: %s\033[0m\n' "$TARBALL_URL"
else
  SHA=""
  for _ in 1 2 3 4 5 6; do
    if curl -fsSL "$TARBALL_URL" -o /tmp/bltusb-"$NEW".tar.gz 2>/dev/null; then
      SHA="$(shasum -a 256 /tmp/bltusb-"$NEW".tar.gz | awk '{print $1}')"
      [[ -n "$SHA" ]] && break
    fi
    sleep 3
  done
  [[ -n "$SHA" ]] || die "could not download/sha the tarball at $TARBALL_URL"
fi
ok "sha256=$SHA"

# ---- 6. update + push the tap formula ----
say "Update Homebrew formula in $TAP_DIR"
FORMULA="$TAP_DIR/$FORMULA_REL"
[[ -f "$FORMULA" ]] || die "formula not found: $FORMULA (set TAP_DIR)"
if [[ $DRY_RUN -eq 0 ]]; then
  perl -pi -e "s{archive/refs/tags/v[0-9.]+\.tar\.gz}{archive/refs/tags/$TAG.tar.gz}" "$FORMULA"
  perl -pi -e "s/sha256 \"[0-9a-f]{64}\"/sha256 \"$SHA\"/" "$FORMULA"
  grep -q "$TAG.tar.gz" "$FORMULA" || die "formula url not updated"
  grep -q "$SHA" "$FORMULA" || die "formula sha256 not updated"
fi
run git -C "$TAP_DIR" add "$FORMULA_REL"
run git -C "$TAP_DIR" commit -m "bltusb $NEW"
run git -C "$TAP_DIR" push origin HEAD
ok "tap updated to $NEW"

say "Done 🎉  Users can now:  brew update && brew upgrade bltusb"
if [[ $DRY_RUN -eq 1 ]]; then say "(dry run — nothing was changed)"; fi
exit 0
