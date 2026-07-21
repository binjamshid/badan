# Assumptions & decision journal

Dated, externally-checkable assumptions formed while working in this repo. Every entry that can
only be *verified* against something outside this session (a live CI run, real hardware, another
person's follow-through) is marked **UNVERIFIED** with the exact command or step that would
confirm it. Format follows `ClassTranscriber/classtranscriber/docs/assumptions.md`.

## 2026-07-22 — Android export encryption parity + reachability ratchet + decision log

- **UNVERIFIED — `ubuntu-latest` GitHub Actions runners ship `python3` on `PATH` with no setup
  step.** The new `reachability-ratchet` CI job (`.github/workflows/ci.yml`) invokes
  `python3 scripts/check-reachability.py` directly, with no `actions/setup-python` step, on the
  assumption that `python3` is already present and on `PATH` on the `ubuntu-latest` image (true of
  every GitHub-hosted Ubuntu runner image as of this writing, per `actions/runner-images`, but not
  independently confirmed against a real Actions run in this session — only run locally with the
  repo's own macOS `python3`). **Confirm by:** letting the next push/PR trigger CI and checking the
  `reachability-ratchet` job's log for a clean `python3 scripts/check-reachability.py` run rather
  than a "command not found."

- **UNVERIFIED — the Android `ExportEncryptor`'s 600,000-round PBKDF2-HMAC-SHA256 KDF stays well
  under ADR-0008's 1.5-second re-evaluation ceiling on real Android hardware, not just a desktop
  JVM.** `ExportEncryptor.kt`'s own doc comment on `DEFAULT_ITERATIONS` already records ~110-120ms
  measured on a JVM host with no Android device attached; this session's
  `./gradlew :app:testDebugUnitTest` run exercised the same JVM path and did not change that. The
  ADR-0008 Android-parity addendum this session added states the gap explicitly rather than
  quietly assuming a phone will be at least as fast. **Confirm by:** running
  `ExportEncryptorTest.fullIterationCountEncryptionStaysWithinTheRegressionCeiling` (or a dedicated
  benchmark) via `./gradlew :app:connectedDebugAndroidTest` on a real Pixel-a-class device, and
  recording the observed wall-clock time in ADR-0008.

- **UNVERIFIED — the pre-existing uncommitted working-tree changes present at the start of this
  session (journal/correlation engine, `behaviors.json` contract mirrors, hydration/stress
  surfaces, and the rest of the modified/untracked files `git status` showed before this session's
  first commit) are in-progress work the repo owner intends to commit separately, and are safe to
  leave uncommitted alongside this session's own commits rather than something this session broke
  or should have absorbed.** This session deliberately isolated its own commits (item 1's
  `ADR-0008` addendum, item 2's `docs/DECISIONS.md`, item 3's reachability ratchet) from that
  pre-existing diff — including hand-splitting a single shared file
  (`.github/workflows/ci.yml`) via a targeted patch so only the reachability job's hunk was staged
  — on the assumption that committing someone else's in-progress, unreviewed work under this
  session's authorship would be a bigger mistake than leaving it uncommitted a while longer.
  **Confirm by:** asking the repo owner directly, or checking `git log` after they commit those
  files themselves to confirm they land intact (not silently dropped by a later `git reset --hard`
  or similar) under their own authorship.
