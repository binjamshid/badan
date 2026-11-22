# BADAN — build handoff

**Written:** 2026-07-22.
**Job:** keep executing `BADAN_WHOOP_HAE_EXECUTION_PLAN.md` phase by phase, iOS only.

---

## 0. Read these first, in order

1. `CLAUDE.md` — working mode + product guardrails.
2. `packages/contracts/INVARIANTS.md` — I1–I8. These govern everything.
3. `BADAN_WHOOP_HAE_EXECUTION_PLAN.md` §4 (lines 150–167) — the strategic decision rules.
4. This file.

Do **not** try to read the whole 1772-line plan at once (it is 274KB and will blow your context).
Read only the sections your current epic names. Section→line map is in the plan's own headings;
`grep -n "^#\{1,3\} " BADAN_WHOOP_HAE_EXECUTION_PLAN.md` gives you the index cheaply.

---

## 1. Standing founder directives

- **iOS ONLY.** Founder said "skip all android for now" (2026-07-22). Do not write Android
  mirrors, do not run `./gradlew`, do not spend audit budget on Android. It is a *pause*, not a
  cancellation — Android is green and complete through Phase 3B, which is a clean resume point.
- **Consequence to state honestly, not hide:** the plan's §4.6 cross-platform parity rule is now
  *suspended by decision*, not satisfied. Never write "parity verified" in a report again until
  Android resumes. CI has Android jobs that will go red as iOS-only work lands shared contracts —
  **flag that, do not delete the Android CI job to make the dashboard green.**
- **"All phases one-shot, use your best judgement, don't stop."** The founder wants autonomy.
  Don't halt to ask about technical choices. *Do* stop and report on the gated items in §5.
- Shared contracts in `packages/` (registry, `algorithms.json`, export schemas, fixtures) still get
  maintained — they are platform-neutral and Android needs them when it resumes.

---

## 2. Exactly where things stand

### Committed and pushed (branch `phase-0-foundation`, remote `origin` = private repo)

| Commit | Contents |
|---|---|
| `d0d9b8a` | **Phase 0** — HK/HC ingestion widening, workouts + consent-gated GPS routes, background substrate, migration v4 |
| `3a5097e` | **Phase 1** — export domain: schema v1.0, templates, Quick Export, GPX, folder destinations, Export Health, backup |
| `3391644` | **Phase 2A** — scores: baseline v2 (migration v6, append-only), sleep/readiness/effort engines, health monitor, published formulas |
| `3ed010a` | **Phase 2B** — scheduling/automation engine, hydration module v1 (migration v7) |
| `86ec427` | **Phase 3A** — delta export, REST destination (built, **gated off**), reports, notification engine, Apple Health importer (migration v8) |
| `26d9653` | hygiene — track `DATA_DICTIONARY.md` (CI needs it), track the plan, ignore `apps/ios/build-device/` |

### ⚠️ Commits from a parallel session

Commits `54bf241`, `84e95cb`, `a7aa034`, `c477ca7` landed during a parallel session. They add
`docs/DECISIONS.md`, an ADR-0008 Android-parity addendum, a SwiftUI reachability ratchet
(`scripts/check-reachability.py`), and `docs/assumptions.md`.

**Before you do anything: `git log --oneline -10` and `git status`.** Assume the tree may have moved
under you. Do not force-push. Do not revert commits from the parallel session.

### 🔴 Uncommitted work in progress — THIS IS YOUR FIRST TASK

~130 uncommitted files: **Phase 3B** (behavior journal, correlation engine, device-gated stress
monitor) plus a **partially applied remediation**.

Phase 3B itself was built and verified green before the remediation started:
**iOS 975 tests / Android 689, 0 failures.**

An independent audit then found 7 findings. A remediation workflow was **2 of 5 lanes complete**
when the founder paused:

- ✅ **DONE** — `wire-context-and-stress`: wired `ContextAnnotator` into the score engines so a
  score computed during declared travel/illness actually carries lower confidence + a visible
  caveat (the UI had been promising this with *no production caller*); wired `StressEngine` into
  `DerivationCoordinator` so `stress.day_trend` rows are actually persisted.
- ✅ **DONE** — `honesty-and-fail-closed`: corrected the false "not yet wired" banners in
  `docs/algorithms/{correlations,stress}.md`; made the stored-finding reader **fail closed** (it
  had rebuilt a missing CI as `ciLow == ciHigh == delta`, which reads as a *confident* direction
  with n=0 — a statistical finding fabricated from missing data); fixed 3 wrong comments.
- ❌ **NOT DONE** — `export-schema-1.1.0` (see §3 below).
- ❌ **NOT DONE** — reverify.
- ❌ **NOT DONE** — independent recheck.

The last full-suite numbers seen after the two completed lanes were **iOS 988 / Android 700, green**
— but the founder then "played with the sim and repo", so **treat that as unverified. Re-run the
build yourself before trusting anything.**

---

## 3. Your immediate task list

1. **Re-run the iOS suite** and establish the real current state (command in §6 — note the
   simulator name gotcha).
2. **Finish the export-schema lane.** This is a genuine external-consumer bug:
   - `json_bundle.schema.json` gained `logs.journal` + `logs.context_statuses` (and earlier phases
     added `logs.hydration`, `deletions[]`, `corrections[]`, `is_delta`, `cursor_before/after`,
     `previous_manifest_sha`) — but `ExportSchema.version` is still `"1.0.0"`
     (`apps/ios/Sources/Export/CSVWriter.swift:14`) and `packages/export-schemas/CHANGELOG.md` is
     untouched.
   - `logs` is `"additionalProperties": false`, so **a consumer validating a sensitive bundle from
     this build against the published 1.0.0 schema will reject it.**
   - Bump to **1.1.0** everywhere the version token lives (a schema-version-agreement CI gate exists
     — make sure it still passes), write one honest CHANGELOG entry naming which phase added which
     key, add a journal-bearing fixture to `packages/fixtures/export/` and wire it into the CI
     schema-validation loop (mirror how `bundle-hydration-v1.json` was added), register its sha256
     in the fixture manifest, regenerate `DATA_DICTIONARY.md`.
   - Verify drift-sensitivity: break the fixture, confirm CI fails, restore.
3. **Verify** iOS green, all gates pass (§6).
4. **Run an independent audit** (§4) and fix what it finds.
5. **Commit Phase 3B.** Follow the existing commit-message style: what shipped, what the audit
   found and how it was fixed, and an explicit **"Known debt"** section. Read `git show 86ec427`
   for the register.
6. Then continue to **Phase 3C** (§5).

---

## 4. The method — this is the part that matters

Every phase so far has **built green and then had an independent audit find something real.** That
loop is why the code is sound. Do not skip it.

**Per phase:**
1. Launch a `Workflow` with parallel lanes that have **disjoint file ownership** (name the owned
   files explicitly in each lane's brief, and name what they must NOT touch).
2. A verify stage that builds + tests and fixes integration breakage.
3. **An independent auditor agent that wrote none of the code**, given *specific invariant
   questions* — not "review this". Vague audits produce vague findings.
4. Fix the findings (another workflow, or yourself if small), re-verify, commit.

**Audit brief must always include these, because they have recurred in EVERY phase:**
- **"Built but dark"** — a feature fully implemented, tested, and reachable from *no user path*.
  Found in hydration export, REST destination, delta export, `StressEngine.persist()`,
  `ContextAnnotator`. Ask: *trace the path from a user tap to this code.*
- **Phantom test citations** — a doc comment naming a test class that does not exist, which reads
  as a guard existing when it doesn't. Found 3×. Ask the auditor to grep every `*Tests`/`*Test`
  identifier in changed sources and confirm each resolves.
- **Comments asserting behaviour the code doesn't have** (the "not yet wired" banners, the
  "nightly job" that doesn't exist, `INSERT OR REPLACE` under a header claiming "nothing is
  overwritten").
- **Fail-open error paths** — swallowed `try?`, a missing value defaulting to something confident.

**Never fix a finding by deleting the claim and leaving the gap.** Either make the claim true, or
replace it with an accurate statement. Tell the auditor to check for exactly this.

Real examples of what audits caught (so you know the bar): `UIBackgroundModes` absent so
`BGTaskScheduler` could *never* run on device while a comment asserted its omission was correct;
Android advancing a changes-token cursor past records it had dropped (permanent data loss recorded
as `COMPLETED`); baselines using `INSERT OR REPLACE` against a unique natural key, which SQLite
resolves by delete-then-insert, violating append-only.

---

## 5. What comes next, and what you must NOT build

### Remaining Phase 3 sub-phases (iOS only)

- **3C** — workout OS MVP (EPIC-42, absorbs EPIC-28 strength/PR) + device/BLE core (EPIC-43,
  *minus* vitals-BLE copy). Largest remaining chunk.
- **3D** — widgets + ambient wave-1 (EPIC-33/44). Needs a new widget extension target + app group.
- **3E** — lab notebook MVP (EPIC-41) — local only: manual entry, PDF vault, four-concept reference
  ranges, on-device OCR.
- **3F** — cycle module *core* (EPIC-39: logging, prediction windows, anomaly, phase-conditioned
  baselines, consent architecture). **Draft `docs/legal/reproductive-threat-model.md` first** — the
  plan makes it a prerequisite (§28.1 action 13).

### 🚫 DO NOT BUILD — founder/legal gated (plan §28.1 explicit do-not-build list)

| Item | Gate |
|---|---|
| **Any pregnancy surface** (EPIC-40) | **A18** + a *retained clinical advisor* + GCC/Oman legal review |
| Fertile-window estimates | **A17** |
| Glucose / CGM integrations | **A21** |
| Vitals-BLE copy surfaces (BP/SpO2/thermometer) | **A25** (clinical advisor) |
| Garmin API | **A20** (license budget) |
| Lab cloud-OCR / FHIR connectors | **A19** |
| Watch app, Wear OS | **A22** (Phase 4) |
| Partner/caregiver sharing of any kind | — |
| Any backend | **A4** (supersedes ADR-0002 "no backend") |

These require real-world founder actions (retaining an advisor, commissioning a legal review) that
you cannot take. **Report them as decisions waiting on the founder. Never stub them to look done.**

---

## 6. Environment gotchas that will waste your time

**The simulator name changed.** `iPhone 17` no longer exists; the available device is
`iPhone 17 Pro Max`. The founder was also playing with simulators, so **list them first**:

```bash
xcrun simctl list devices available | grep iPhone
```

Then build/test (adjust the name to what actually exists):

```bash
cd apps/ios && xcodegen generate && \
xcodebuild -project BADAN.xcodeproj -scheme BADAN -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath build -quiet test
```

`.github/workflows/ci.yml` pins a simulator name too — an earlier audit flagged it as stale
(`iPhone 16`). Worth fixing to select the newest available rather than naming a model.

**The machine OOM'd** running many concurrent agents that each invoked `xcodebuild`. Cap parallel
lanes at **2–3**, and tell every agent: **one build at a time, never two `xcodebuild` processes at
once.** Prefer `-only-testing:` while iterating, one full run at the end.

**Background workflows get killed** (sleep, network switches, process exit). This is normal and
recoverable — `Workflow({scriptPath, resumeFromRunId})` replays completed agents from cache and
re-runs only what didn't finish. If it says "still running" but nothing is writing, `TaskStop` the
stale task first, then resume. Check progress with:

```bash
python3 -c "
import json
p='<transcriptDir>/journal.jsonl'
print(sum(1 for l in open(p) if json.loads(l).get('type')=='result'), 'agents banked')"
```

**Verify a lane's work landed even if it never returned a report.** One lane died mid-response but
had already written all its files correctly — check the code, not just the report.

**Staging:** commits so far used `git add -A -- apps packages scripts docs .github`, which
**silently skips repo-root files** (that's how `DATA_DICTIONARY.md` went untracked and would have
failed CI on a fresh clone). Check `git status` for root-level files before committing.

---

## 7. Standing known debts (carry them forward; they're in the commit messages too)

- **No destination manager UI on either platform** — so folder destinations and every
  non-share-sheet template destination are unreachable. A Phase-1 EPIC-14 gap. REST is gated off on
  top of that.
- **EPIC-18 restore has no on-device commit path for any log family** — preview + verify only since
  Phase 1. The `import_batches` committer and a JSON→domain decoder are net-new work.
- **Metric flow is 21 on both platforms** vs the plan's ≥25 Phase-0 success metric. iOS defers
  wrist temperature (needs the baseline engine to express it as a deviation); Android defers
  total-calories (registry has no metric for the total). **Do not pad the registry to hit a number.**
- **The 14-day background soak has never been run end to end.** `docs/runbooks/background-soak.md`
  says so honestly. It is now genuinely runnable — the entitlement and `UIBackgroundModes` are
  correct and the app is installed on the founder's device ("AJR", iPhone 15 Pro).
- **`AutomationSetupWizardScreen.swift:535`** swallows a storage failure with `try?` and still
  announces "enabled".
- **iOS `AppEnvironment`** has two `reference to captured var 'self'` warnings that become hard
  errors under Swift 6.
- Aggregated (bucketed) delta runs emit no `deletions`/`corrections` — limit is named in-code.

---

## 8. The non-negotiables

These are what make this product different from WHOOP. Protect them in every review:

- **Raw data is never paywalled.** Every export format and destination that moves the user's own
  data is free.
- **I2 — derivation is append-only.** A recompute writes a *new* row; old rows keep their old
  algorithm id. That is what makes scores auditable.
- **I7 — sensitive data** (journal, cycle, symptoms, meds) lives in `badan_sensitive.db`, gates
  independently, exports only under `includeSensitive`, and is removed by the purge.
- **No false precision.** Sleep need is a *range* when confidence is low. Temperature is a
  *deviation*, never an absolute — and it should be structurally impossible to render otherwise.
  A phone-only user gets a *labelled* reduced-input variant, never a demoralizing zero.
- **No silent failure.** Three consecutive automation failures visibly pause the schedule *and*
  notify. Every export attempt writes an `ExportRun` row.
- **Honest scheduling.** Never "cron", never "guaranteed", never an un-caveated wall-clock time.
  The reliability-tier labels are in plan §13.7 and are load-bearing.
- **Wellness-safe copy, en + ar, RTL-correct, real natural Arabic** (not transliteration, and mind
  Arabic dual agreement — 2 takes the dual form).
- **Statistical honesty** (the correlation engine): min-n gates *suppress* rather than caveat; "no
  clear association" is a first-class rendered result; non-parametric only (Cliff's delta +
  deterministically-seeded bootstrap); "association, not cause" on every card.
