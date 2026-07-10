export const meta = {
  name: 'audit-gate',
  description: 'Independent Sonnet + codex audit → Opus fix → re-audit loop until clean',
  phases: [
    { title: 'Audit', detail: 'Sonnet subagent + codex review the code in parallel' },
    { title: 'Fix', detail: 'Opus subagent fixes any HIGH/MED blockers' },
  ],
}

const REPO = '/Users/ning/src/bltusb'
const VERSION = (args && args.version) ? args.version : 'v1.3.1'
const SCOPE = (args && args.scope) ? args.scope
  : 'v1.3.1: data-loss guards (host-unmount before mount, ext norecovery, fail-closed read-only, unknown-fs confirm, device-identity check, unmount sync + -w), and the per-device Keychain password model (per-volume key, opt-in default, recovery-key support, retry-on-wrong-password).'

const SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    passed: { type: 'boolean', description: 'true only if NO HIGH or MEDIUM findings' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          severity: { type: 'string', enum: ['HIGH', 'MEDIUM', 'LOW'] },
          area: { type: 'string' },
          problem: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['severity', 'problem', 'fix'],
      },
    },
  },
  required: ['passed', 'findings'],
}

const AUDIT_FOCUS = `Audit the bltusb tool for issues that could cause USER DATA LOSS, security problems, or correctness bugs. Files (read them, do NOT modify anything, do NOT mount/format any drive):
- ${REPO}/bltusb  (main script)
- ${REPO}/test/bltusb_test.sh
- ${REPO}/scripts/release.sh
Scope of this release — ${SCOPE}
Priorities: (1) data safety: wrong-device, host↔VM double-mount, read-only truly read-only, unmount flush; (2) password model: per-volume key correctness (no cross-drive password reuse; multiple BitLocker drives each unlock correctly), opt-in default, no secret leak to argv/ps/logs, recovery keys not saved; (3) correctness: shell quoting, set -euo pipefail traps, fstype classification. Report ONLY real HIGH/MEDIUM issues (skip style nits). Set passed=true only if there are no HIGH or MEDIUM findings.`

let round = 0, passed = false, remaining = []
while (round < 3 && !passed) {
  round++
  log(`Audit round ${round} — Sonnet + codex (independent)`)

  const results = await parallel([
    () => agent(
      `You are an independent security/data-safety auditor. ${AUDIT_FOCUS}\nReturn your findings via the structured schema.`,
      { label: `audit:sonnet:r${round}`, phase: 'Audit', model: 'sonnet', schema: SCHEMA }
    ),
    () => agent(
      `Run codex as an independent auditor, then return its findings via the schema.\nSteps:\n1) Run this shell command (it writes the report to a file):\n   codex exec --cd ${REPO} --sandbox read-only -o /tmp/audit_codex_r${round}.md "${AUDIT_FOCUS.replace(/"/g, '\\"')}"\n2) Read /tmp/audit_codex_r${round}.md and translate codex's findings into the structured schema (severity HIGH/MEDIUM/LOW, area, problem, fix). If codex reports it is safe to ship with no HIGH/MEDIUM issues, set passed=true and findings=[]. Do NOT modify any files.`,
      { label: `audit:codex:r${round}`, phase: 'Audit', schema: SCHEMA }
    ),
  ])

  const findings = results.filter(Boolean)
    .flatMap(r => (r.findings || []))
    .filter(f => f && (f.severity === 'HIGH' || f.severity === 'MEDIUM'))
  remaining = findings

  if (findings.length === 0) {
    passed = true
    log(`Round ${round}: audit CLEAN (no HIGH/MED from either auditor)`)
    break
  }

  log(`Round ${round}: ${findings.length} blocker(s) — dispatching Opus fixer`)
  const list = findings.map((f, i) => `${i + 1}. [${f.severity}] (${f.area || '?'}) ${f.problem}\n   suggested: ${f.fix}`).join('\n')
  await agent(
    `You are an expert bash engineer. Fix these HIGH/MEDIUM audit findings in ${REPO}/bltusb (and test/bltusb_test.sh or scripts/release.sh if the finding is there). Edit the files directly.\n\nFindings:\n${list}\n\nRules: keep behavior otherwise unchanged; preserve read-only-by-default and the per-device password model; after editing run \`shellcheck ${REPO}/bltusb ${REPO}/test/bltusb_test.sh ${REPO}/scripts/release.sh\` and \`bash -n ${REPO}/bltusb\` and make sure both pass (0 findings). Do NOT mount/format any real drive. Report exactly what you changed.`,
    { label: `fix:r${round}`, phase: 'Fix', model: 'opus' }
  )
}

return { version: VERSION, passed, rounds: round, remainingBlockers: remaining }
