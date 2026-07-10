---
name: ship-version
description: Full lifecycle for building and releasing a bltusb version — SRAA-constrained planning, Opus implementation, Sonnet functional testing, an independent audit+fix loop, a pre-push regression re-test, and the release. Use whenever implementing or shipping a bltusb version (e.g. "do v1.4", "start the auto-unlock feature", "ship the next version", "cut a bltusb release", "release 1.3.x"). Encodes the operational rules learned the hard way (codex path/stdin, hardware-test serialization, shellcheck local-vs-CI drift, release.sh preconditions, don't-strip-Phase-0-features).
---

# Ship a bltusb version

The standing process for taking a bltusb version from idea to a released, CI-green tag.
Two tracks:

- **Feature version** (e.g. v1.4 auto-unlock trigger): run **all** phases 0→5.
- **Patch version** (bugfix / docs / CI fix): skip 0–1; do 3 (audit only if code changed), 4, 5. A CI/lint-only fix can go straight to 4→5.

**Golden rule (from `verify-autofix`):** a reasoning-audit that "passes" is **not** done. Every phase that changes code ends with **real functional/hardware testing**, and the human (you, the main loop) reviews every subagent diff — subagent fixers redesign and regress, especially around secrets, `sudo`, mount ops, temp files, device validation, and i18n `printf`.

---

## The pipeline

### Phase 0 — Plan under SRAA constraints  *(Opus subagent)*
Dispatch an **Opus subagent** to draft the execution plan for the version's goal, **bounded by `docs/SRAA-ASSESSMENT.md`**. It must:
- State which SRAA phase the feature belongs to and whether it's shippable now. **Phase-0 = personal/dev, needs `sudo`; Phase-2 = signed helper, zero-sudo, BLOCKED on the security-team go/no-go (`SRAA-ASSESSMENT.md §8`).** Do **not** build Phase-2 work before that decision.
- Keep it **Phase-0-appropriate**: never strip personal-convenience features (auto-open, persistent `rw`, unknown-fs override, `sudo bltusb detect`) to satisfy enterprise/government findings — those are Phase-2/government-mode, tracked in the SRAA doc, not forced into the personal tool.
- Produce: concrete file/function touch-list, the exact new UX, threat notes for the new surface, test additions (smoke + hardware), and explicit non-goals.
You review the plan before implementation.

### Phase 1 — Implement  *(Opus subagent, or main loop for small changes)*
Write the code to the plan. Match surrounding style, i18n all three languages (en/zh-cn/zh-tw), keep `set -euo pipefail` safe (mind the `local x; x=$(pipe)` abort — use `|| true` or the combined `local x=$(...)` form). Add/extend tests. Bump nothing yet.

### Phase 2 — Functional test  *(Sonnet subagent)*
Dispatch a **Sonnet subagent** to run the functional tests and fix any bugs it finds (looping with you reviewing diffs):
- `shellcheck bltusb test/bltusb_test.sh` and `bash -n bltusb` clean (see shellcheck drift rule below).
- `./test/bltusb_test.sh smoke` green.
- **Hardware** on the real BitLocker USB (see rules below). Bugs → fix → re-run until green.

### Phase 3 — Audit + fix loop  *(independent Opus subagent + codex)*
This is the quality gate. Using the **`sraa-audit-offline-macos`** skill (domains O offline / P peripheral / M macOS + base code-level):
1. Dispatch **one Opus subagent** and **codex** independently to audit the diff (read-only).
2. Consolidate findings. Classify each: **code-fixable now** (→ fix) vs **architectural/Phase-2** (→ record in `SRAA-ASSESSMENT.md`, don't force into bash).
3. Fix real findings with an **Opus subagent** (or main). **Review the diff** against `verify-autofix` regression classes.
4. **Re-audit** (codex again on the new diff). Loop until **PASS**. codex reliably finds runtime bugs reasoning misses — expect 2–3 rounds; do not stop on a fix, only on a clean re-audit.

### Phase 4 — Pre-push regression re-test  *(critical)*
Re-run the **full hardware functional test** after the audit fixes — **"audit 修完，功能不能坏."** This catches a fix that was "correct by reasoning" but broke functionally. Also re-confirm shellcheck + smoke. Verify Keychain restored and no zombie mounts/processes.

### Phase 5 — Release
Only after Phase 4 is green. Push is **outward-facing → confirm with the user first.** Then:
1. Land the feature changes as ONE commit (`bltusb` + `test/` + `docs/`) — `release.sh` only `git add bltusb`, so commit everything else yourself first, with VERSION left at the **previous** number.
2. `scripts/release.sh patch|minor|major` — it bumps VERSION, re-runs shellcheck+smoke, commits `release: vX.Y.Z`, tags, pushes main+tag, creates the GitHub release, updates the `neil0306/tap` formula (url+sha256).
3. **Confirm CI green** (`gh run list --commit $(git rev-parse HEAD)`). ShellCheck + Test must both pass.

---

## Hard operational rules (learned the hard way)

- **codex** lives at **`~/.local/bin/codex`** (NOT `/opt/homebrew/bin` — gone; background shells don't have it on PATH → use the absolute path). Run: `~/.local/bin/codex exec --sandbox read-only --cd /Users/ning/src/bltusb "<prompt>" </dev/null`. **The `</dev/null` is mandatory** or codex hangs on "Reading additional input from stdin".
- **Hardware test** — serialize, never concurrent: two `anylinuxfs mount` on one disk **deadlock** and strand the device with multi-hour zombies. Run exactly one; wait for it. Invocation (all subtests):
  `BLTUSB_TEST_DEVICE=/dev/disk4s1 BLTUSB_TEST_FRESH=1 ./test/bltusb_test.sh hardware`
  - Requires `sudo` (check `sudo -n true` — if not cached, you can't prompt from a tool; ask the user to run it via the `! ` prefix).
  - The BitLocker drive is auto-detected (`bltusb detect | grep bitlocker`, currently **disk4s1**). Password comes from the Keychain (per-device or legacy global) or `ALFS_PASSPHRASE` — the fresh-device subtest reads the stored value itself, so **you never handle the password**. **Never print the BitLocker password.**
  - It is **DESTRUCTIVE + credential-mutating**: writes ~100 MB to the target drive, deletes/restores Keychain items. After it runs, verify Keychain restored + no `anylinuxfs mount`/`vmnet-helper`/`vfkit` leftovers (`pkill -9 -f` + `anylinuxfs stop` if a backend hung).
- **shellcheck local≠CI drift:** CI uses `ubuntu-latest`'s preinstalled shellcheck, which enables optional style checks (e.g. **SC2002**) that local 0.11.0 does not. Before release, run `shellcheck --enable=all bltusb test/bltusb_test.sh` and fix anything CI would hit (or the release passes locally and fails CI).
- **`release.sh` preconditions:** clean tree, on `main`, synced with `origin/main`, `gh` authed, `../homebrew-tap` present + clean. It refuses otherwise. It **only stages `bltusb`** — commit `test/`+`docs/` yourself first.
- **Never save what git/docs already record** to memory; the durable process facts live in `[[bltusb-release-and-audit-process]]` and this skill.

## Related
- `verify-autofix` — the diff-review + real-testing discipline every phase depends on.
- `sraa-audit-offline-macos` — the audit rule set for Phase 3.
- `docs/SRAA-ASSESSMENT.md` — the phased roadmap, verdict (Phase-2 No-Go pending security decision), and residual risks that bound Phase 0.
