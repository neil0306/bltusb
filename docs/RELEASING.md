# Releasing

Releases are cut with a single script that keeps the tool, the git tag, the
GitHub release, and the Homebrew formula in sync.

## One command

```bash
scripts/release.sh patch     # 1.2.1 -> 1.2.2
scripts/release.sh minor     # 1.2.1 -> 1.3.0
scripts/release.sh major     # 1.2.1 -> 2.0.0
scripts/release.sh 1.5.0     # explicit version
```

Preview without changing anything:

```bash
scripts/release.sh --dry-run patch
```

## What it does

1. Bumps `VERSION` in `./bltusb`.
2. Runs `shellcheck` + the smoke suite, and **aborts if either fails**.
3. Commits, tags `vX.Y.Z`, and pushes `main` + the tag.
4. Creates the GitHub release (`--generate-notes`).
5. Downloads the release tarball and computes its `sha256` (with retry, since
   the archive appears a moment after the tag is pushed).
6. Updates `url` + `sha256` in the tap formula and pushes the tap repo.

Afterwards users get it via `brew update && brew upgrade bltusb`.

## Requirements & assumptions

- Run from the bltusb repo root, on a **clean** git tree.
- `gh` (GitHub CLI) authenticated with push access to both repos.
- The Homebrew tap checkout lives at `../homebrew-tap`. Override with
  `TAP_DIR=/path/to/homebrew-tap scripts/release.sh …`.

## Manual fallback

If you ever need to do it by hand:

```bash
# 1. bump VERSION="X.Y.Z" in ./bltusb, then:
git commit -am "release: vX.Y.Z" && git tag -a vX.Y.Z -m "bltusb vX.Y.Z"
git push origin main vX.Y.Z
gh release create vX.Y.Z --generate-notes

# 2. update the formula
SHA=$(curl -fsSL https://github.com/neil0306/bltusb/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256 | awk '{print $1}')
# edit ../homebrew-tap/Formula/bltusb.rb: set url tag to vX.Y.Z and sha256 to $SHA
git -C ../homebrew-tap commit -am "bltusb X.Y.Z" && git -C ../homebrew-tap push
```
