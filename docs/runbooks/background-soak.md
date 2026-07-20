# Runbook — 14-day background soak (iOS)

Scope: **the iOS background substrate only** (EPIC-04) — HealthKit observer wakes,
`BGAppRefreshTask`, `BGProcessingTask`, and the `background_runs` log that records all three.
Android's `WorkManager` equivalent is EPIC-05 and needs its own protocol; nothing here transfers,
because the failure modes are different (Doze and OEM battery managers, not a three-strikes
revocation).

Written 2026-07-20, alongside the substrate itself. **Never yet run end to end.** The pass/fail
numbers below are derived from the constraints in ADR-0009 §A2 and plan §13.3/§13.7, not from an
observed baseline — the first soak establishes the baseline and this document should be corrected
against it rather than treated as already-validated.

---

## 0. Why a soak exists at all

Almost nothing in this substrate can fail in a way a test catches.

- `HKObserverQuery` background delivery is **silently revoked** after 3 wakes whose completion
  handler is not called promptly. HealthKit does not report this, there is no API to query it, and
  `enableBackgroundDelivery` keeps returning success while delivering nothing. The app cannot tell
  the difference between "the OS has not woken us lately" and "the OS will never wake us again."
- `BGTaskScheduler` never promises to run anything. A task that is never scheduled and a task that
  is scheduled but deprioritised look identical from inside the app.
- A locked device makes parts of the HealthKit store unreadable. That is correct behaviour, it
  happens constantly, and it must never be mistaken for a bug — by us or by the user.

`BackgroundSubstrateTests` covers every decision BADAN makes. This runbook covers the half BADAN
does not control: whether iOS actually wakes it, and whether the wakes it gets are spent within
budget. Fourteen days is the shortest window that contains a realistic mix of charging patterns,
overnight idle periods, low-power-mode days, and at least one system-initiated
`BGProcessingTask` — which is the rarest of the three events.

## 1. Preconditions

| Requirement | Why |
|---|---|
| A **real device**, not the simulator | The simulator delivers no HealthKit background wakes and runs no BG tasks on the OS's own initiative. A simulator soak measures nothing. |
| An Apple Watch paired and worn, including overnight | Sleep, HRV and respiratory-rate rows only exist if something writes them. Without a watch the soak exercises step count and little else. |
| A **development build with a real `DEVELOPMENT_TEAM`** | `com.apple.developer.healthkit.background-delivery` is an entitlement; an unsigned or wrongly-signed build silently gets no wakes. |
| `UIBackgroundModes` in the built `Info.plist` contains **`fetch` and `processing`** | Separate mechanism from the entitlement above, and the one BUG-BG-01 got wrong. Without them `BGTaskScheduler.submit(_:)` throws on every call and the soak measures observer wakes only. Verify before starting — 14 days is a long time to spend on a build that could never have passed: `plutil -p <BADAN.app>/Info.plist \| grep -A3 UIBackgroundModes`. |
| Apple Health connected in BADAN, with the initial backfill finished | Observers are only registered once `isHealthKitConnected` is true. |
| The device used **normally** for the full period | BG scheduling is driven by the OS's model of how you use the app. A phone left on a desk produces a soak result that does not describe any real user. |
| Console.app (or `log stream`) available for at least the first day | The subsystem is `net.binjamshid.badan`; categories `HealthKitObservers`, `BackgroundTasks`, `Background`. |

**Do not** attach the Xcode debugger for the duration. A debugger-attached process is not
suspended the way a released app is, which suppresses exactly the failure this soak looks for.

## 2. What to run

There is nothing to run on a schedule. The soak is: **install, connect, use the phone normally for
14 days, and read the log.** The only deliberate actions are the checkpoints in §3.

Day 0 setup:

1. Install the build, complete onboarding, connect Apple Health, let the 90-day backfill finish.
2. Open **Settings → Diagnostics** and confirm the **Background activity** section renders. On day
   0 it will read "None recorded yet" apart from the foreground sync that just ran — that is
   correct, not a failure.
3. Tap **Copy diagnostics** and paste it somewhere durable. This is the day-0 baseline.
4. Background the app (do not force-quit — see §5).

Then use the phone.

## 3. What to watch

Read **Settings → Diagnostics → Background activity** at these checkpoints: end of day 1, day 3,
day 7, day 14. Copy the diagnostics text each time; the run log is pruned at 90 days but the
14-day rollup window means day-1 evidence is gone from the *summary* by day 15.

The six numbers that matter, all from the copied text:

```
background_last_run:        <timestamp>
background_last_kind:       hkObserverWake | bgAppRefresh | bgProcessing | foregroundSync
background_outcomes_14d:    completed=… ,storeLocked=… ,expired=… ,throttled=… ,error=…
background_handler_ms_p50:  <ms>
background_handler_ms_p99:  <ms>
background_handler_ms_max:  <ms>
```

### Reading the outcome mix

| Outcome | What it means | Expected share |
|---|---|---|
| `completed` | A wake ran the anchored re-query to completion. Zero counts is still `completed` — "nothing changed" is success. | The majority. |
| `storeLocked` | The device was locked and the HealthKit store was unreadable. **Normal.** iOS Data Protection working as designed; the next wake picks it up. | Anything up to roughly a third, higher for a user who locks their phone a lot. Not a defect at any level. |
| `throttled` | The wake arrived while another ingest held the lock — usually the user opening the app at the same moment. The in-flight run did the work. | A handful. |
| `expired` | A BG task hit its time limit, checkpointed, and exited cleanly. Expected occasionally for `bgProcessing`; should be rare for `bgAppRefresh`. | A few at most. |
| `error` | Either the work threw, or `BGTaskScheduler` **declined the submit** so no work was ever attempted (BUG-BG-01). Tell them apart by the row: a declined submit has a zero duration and no work counts. The only genuinely bad outcome here. | Zero. Anything above zero is a bug, and the OSLog line names the failing step (category `Background`) or the refused identifier (category `BackgroundTasks`). |

## 4. What "green" means

A soak passes when **all** of these hold at day 14:

1. **Three strikes never tripped.** `background_handler_ms_p99 < 5000` (5s) — the budget
   ADR-0009 §A2 makes binding. In practice the handler is called synchronously before any work is
   scheduled (`ObserverCompletionGate`), so a healthy device should report single- or low
   double-digit milliseconds; a p99 in the hundreds means something is blocking the HealthKit
   callback thread and should be investigated even though it is nominally inside budget.
2. **Wakes are still arriving at day 14.** `background_last_run` is within the last 24 hours and
   `background_last_kind` is `hkObserverWake` or `bgAppRefresh` — not `foregroundSync`. A log whose
   only recent entries are `foregroundSync` is the signature of revoked background delivery: the
   app still syncs when opened, and nothing else ever happens. **This is the single most important
   thing the soak exists to detect.**
3. **The wake count is not collapsing.** Compare the day-7 and day-14 copies. A count that drops
   toward zero over the second week, with no change in phone usage, is the revocation appearing
   gradually rather than at once.
4. **`error = 0`** over the whole window. Note that a declined `BGTaskScheduler` submit now lands
   here too (BUG-BG-01) — including the one legitimate cause, a tester who has Background App
   Refresh switched off. That invalidates the soak per §5 rather than counting as a defect, so
   check the setting before filing an `error` count; a decline is otherwise a build problem, not a
   device one.
5. **At least one `bgProcessing` run** occurred, or the device never had heavy work pending (no
   interrupted backfill), in which case none was ever requested and its absence is correct. Check
   which by confirming the Sources screen shows data — if it does, no backfill resume was pending.
6. **No user-visible complaint about a locked device.** `storeLocked` runs appear in Diagnostics as
   "Device locked (normal)" and nowhere else in the app. If any surface presented one as an error
   or a failure, the soak fails regardless of the numbers.
7. **No copy anywhere promises a time.** Re-read the Diagnostics background section and any
   automation surface shipped since the last soak against plan §13.7: "best-effort background" is
   the language; a wall-clock promise, "guaranteed", or the word "cron" is a fail.

## 5. Things that invalidate a soak

- **Force-quitting the app** (swiping it out of the app switcher). iOS stops delivering
  `BGAppRefreshTask` and `BGProcessingTask` to a force-quit app until it is launched again by hand,
  and HealthKit background delivery is affected too. One force-quit does not ruin the run, but note
  the date — a wake gap starting there is explained, not a defect. Repeated force-quitting makes
  the whole soak unreadable.
- **Low Power Mode for extended periods.** Background refresh is heavily curtailed. Note the days.
- **Background App Refresh switched off** (Settings → General → Background App Refresh).
  `BGAppRefreshTask` stops entirely. HealthKit observer delivery is a separate mechanism and
  continues, so a log with observer wakes but no `bgAppRefresh` rows is this, not a bug — check the
  setting before filing anything.
- **Restoring the device from backup mid-soak.** Anchors and observer registration both change
  underneath the run.
- **Attaching the debugger**, per §1.

## 6. If it fails

| Symptom | First thing to check |
|---|---|
| Only `foregroundSync` rows for several days | Suspected three-strikes revocation. There is no way to confirm from inside the app and no way to reverse it short of reinstalling. Delete and reinstall the app, redo §2, and watch the handler latency from day 0 — if the p99 was already high, that is the cause. |
| `p99` above 5s | Something between entering the observer handler and calling the completion handler is blocking. Read `HealthKitObserverRegistrar.handleWake`: the completion call must remain the first statement, and nothing may be inserted above it. |
| `error` rows | OSLog, subsystem `net.binjamshid.badan`, category `Background`. The line names the failing processing step and the error's *type* only — no values, by contract — so reproduce against a debug build for detail rather than expecting the log to carry it. |
| No `bgAppRefresh` rows at all | **`UIBackgroundModes` in the built `Info.plist` first** — it must contain `fetch` (for `BGAppRefreshTask`) and `processing` (for `BGProcessingTask`). Without them every `submit(_:)` throws `BGTaskSchedulerError.unavailable`, registration still succeeds, and no BG task ever runs. This shipped once (BUG-BG-01) and is the likeliest cause of a log with observer wakes but nothing else. Then the Background App Refresh setting (§5), then confirm `BGTaskSchedulerPermittedIdentifiers` matches `BackgroundTaskIdentifier` exactly — a mismatch raises at registration, so also check the `BackgroundTasks` category log line from launch. |
| No `bgProcessing` rows at all | Same three checks as the row above, `processing` mode included. Then §4.5 — with no interrupted backfill, none is ever requested and the absence is correct. |
| `error` rows with `durationMs` 0 and no work counts | A **declined submit**, not a failed run: `BGTaskScheduler` refused the request outright. The OSLog line (category `BackgroundTasks`, error level) names the identifier and says `unavailable` or `transient`. `unavailable` is standing, not transient — check `UIBackgroundModes`, then Background App Refresh, then whether this is a simulator (which schedules nothing). `transient` is usually `.tooManyPendingTaskRequests` and clears itself. |
| `storeLocked` is nearly everything | Not a failure — but if it is close to 100%, the user's data is only ever fresh when they open the app, which is a product-copy question (are we promising more than that?) rather than a code fix. |

## 7. Known gaps

- **No automated soak.** Everything above is manual reading of a screen. A device-farm harness that
  drove this and diffed the run log would be strictly better and does not exist.
- **Revocation is undetectable in-app.** §4.2 is a heuristic — "no non-foreground wakes recently" —
  not a signal. If Apple ever exposes background-delivery state, this runbook's most important
  check becomes a real one.
- **The thresholds are derived, not measured.** See the preamble. Correct them after the first
  real soak.
- **The soak covers one device shape.** A phone-only user (no watch) exercises a different and
  much sparser wake pattern, and has not been soaked at all.
