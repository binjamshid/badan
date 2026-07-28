# ADR-0011 — Opt-in methodology telemetry (learning footprints only)

**Status:** Accepted — 2026-07-28
**Context:** Every entry in `packages/contracts/algorithms/algorithms.json` is `provisional: true`;
the constants are seeded defaults, not validated ones — the file's own `paramNotes` say so
("PROVISIONAL, pending A3. BADAN's OWN launch weights … deliberately NOT WHOOP's claimed weights").
D-36 adds on-device calibration from user feedback, which produces — locally — the first evidence
BADAN has ever had about whether a derived number matches lived experience. That evidence is useless
to the shared methodology while it stays on one device. This ADR decides whether, and on exactly
what terms, an aggregate of it may leave.
**Decider:** Founder.

## The boundary — learning footprints only

**Decision:** Approved, narrowly. A footprint may carry **which metric, which method, the direction
of disagreement, a bucketed event count, and whether a calibration was in force.** It may carry no
reading, no offset magnitude, no date or period key, no identifier, no locale or region, and no
device model. The illustrative line the founder drew is the rule: "user rejected readiness;
method=v2; bucketed direction=over" is permitted; "user rejected readiness 72, calibrated −8" is
not.

**Supersession — this narrows `CLAUDE.md`'s "Never: Send user health data off device."** The Never
survives and is not deleted: no health datum leaves the device under this decision. What leaves is a
statement about a *method*, and the schema is closed (`additionalProperties: false`) so that
"footprint" cannot quietly widen into "reading" without a failing test and a CI gate.

Explicitly omitted, and named as omitted in the schema doc: every reading; every offset magnitude;
every `periodKey`, date or timestamp of an underlying value (a period key is a date the user had a
reading — health-adjacent); any count below 10; any device or install identifier; locale, region and
timezone (with a small user base, region is an identifier); device model; OS version. `osMajor` was
considered and dropped — no analytic use was identifiable, and a field with no use is pure risk.

## Hosting — the existing service, not a second surface

**Decision:** `backend/api` hosts it, on a new `POST /v1/footprints`. ADR-0010 forbids a second
backend surface without a new decision; **this is that decision, and it declines to create one.** A
second service would mean a second vhost, systemd unit, TLS chain and attestation path to hold data
strictly less sensitive than what the coach already proxies.

**Concrete parameters (this review):**
- Separate SQLite file `footprints.db` in the same `DATA_DIR`, not joinable to `device_tokens.db`
  in one query.
- Retention 400 days, pruned on write; `received_day` at day granularity, never a receive timestamp.
- G8 unchanged: the content-free access log (`main.py:84-96`, which logs only request id, method,
  path, status and elapsed ms) stays, with a `caplog` test proving no body is logged — in the style
  of the existing `test_attestation_blob_never_reaches_the_log`.
- The existing rate-limit layers apply; the payload is size-capped by nginx as today.

## Identity — none, and the cost is stated

**Decision:** No install or device identifier rides along. Flood control uses an App Attest
assertion per submission — `appattest.py:322`'s `verify_assertion`, which is written and unit-tested
but has never been wired to a route. This is its first caller. After verification the key id is
discarded and never written beside the payload.

**Consequence — this is enforced by code, not by cryptography.** Verifying an assertion requires
looking the key up in `attested_keys`, so the server learns a key id at verification time. The
non-join is a code boundary with a test behind it. Claiming unlinkability would be an overclaim and
this ADR does not make it.

**Consequence — aggregates cannot be deduplicated.** One user submitting repeatedly is
indistinguishable from many users. This is accepted deliberately in exchange for carrying no
identifier.

## Opt-in only, default off

**Decision:** `methodologyTelemetryEnabled` ships `false`, decodes `false` when absent, and is
offered only in Settings → Privacy & Security and only after the user has used the feedback
feature — asking for consent to something they have no concept of is itself a dark pattern. Not in
onboarding, never pre-checked, never labelled recommended, no repeat nag. A "What has been sent"
screen shows every submitted payload verbatim.

This copies `showValuesInNotifications`' established reasoning (`Customization.swift:127-133`):
silence on the question is read as "no", never as consent.

## Consequences

- BADAN acquires its **second** network-reaching surface. The CI network-free gate widens: the
  socket-API pattern (`IOS_NET_API`) goes from `Sources/Export/` to all of `Sources/`, with an
  allowlist of exactly four files — `Platform/AICoach/AICoachClient.swift`,
  `Export/Destinations/RESTDestination.swift`, `Export/Destinations/RESTDestinationAvailability.swift`,
  and the new `Platform/Telemetry/FootprintClient.swift`. The remote-URL-construction pattern
  (`IOS_REMOTE_URL`) stays scoped to export generation, where it proves no remote read is possible;
  repo-wide it would fire on legitimate `shortcuts://`, App Store and `openSettingsURLString` uses.
- `PrivacyInfo.xcprivacy` and `PrivacyPolicyScreen.swift` both currently claim BADAN makes no
  network calls and sends no telemetry. Both are already stale — ADR-0010 §A9 required this
  correction "before ship" and it never landed. They must be corrected in the same commit.
- App Store privacy declaration moves from `NSPrivacyCollectedDataTypes: []` to declaring
  `NSPrivacyCollectedDataTypeOtherUsageData`, purpose Analytics, `Linked: false`, `Tracking: false`.
  Under-declaring is an App Review risk; over-declaring is not.
- `backend/api`'s existing pytest suite, which no CI job runs today, gets a `backend-tests` job.
  Adding a route to that service without running its tests is not acceptable.

## Not decided here

- **That footprints can clear any metric's `provisional` flag.** They cannot, on their own. The
  self-selected opt-in population and the absence of an identifier mean aggregate counts cannot
  establish that a constant is right. Clearing `provisional` for a metric still requires a stated
  validation method, per metric, and this data is at most an input to one.

  **Dissent recorded at approval:** the pipe is sound but the analytics probably will not work at
  BADAN's current scale. The users who opt into telemetry *and* use the feedback feature *and*
  switch methods are a heavily self-selected minority of an already small base, and with no
  identifier 200 footprints from 200 users are indistinguishable from 200 from four enthusiasts —
  exactly the failure mode for validating a constant. The boundary work is judged valuable on its
  own terms, and footprints are cheap to start collecting early.
- Any second telemetry category. This ADR authorises footprints about derived-metric feedback and
  nothing else; a new category is a new decision.
- Accounts, sync, or server-side history. Unchanged and still prohibited.
