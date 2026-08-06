# BADAN — Monetization & premium feature draft

**Status: draft for owner decision. Nothing here is built.**
Written 2026-07-16, against `main` @ `b1a3934`.

This is the feature-gating proposal requested alongside the optional-account and subscription
work. It is deliberately a decision document, not a plan of record: the line it draws determines
what BADAN is, and that is not a call to make inside a commit.

---

## 1. The line

BADAN's guardrail (`CLAUDE.md`) is **"raw data is not paywalled."** That is not in tension with a
subscription — it is what makes one honest. The line it implies:

> **You never pay to see, keep, or leave with your own data.**
> **You pay for BADAN's interpretation of it.**

Concretely, these stay free **forever**, and should be stated as such in the paywall copy:

- Every raw reading, at full resolution, with full provenance and lineage.
- The metric browser, the anatomy sheets, and the "how this was worked out" methodology.
- Export — CSV and JSON, sensitive included, with checksums and manifest. **SUPERSEDED BY D-33
  (2026-07-28):** the free tier now exports the last 7 days; beyond that is subscriber-only.
  Viewing, keeping, logging and deleting records stay free and uncapped. The rest of this
  document still stands — you pay for interpretation, not for access.
- Deletion, the sensitive-records gate, and everything the privacy policy promises.
- Manual logging of everything BADAN can log.

If a feature answers *"what did my body do?"* it is free. If it answers *"what should I make of
it?"* it is a candidate for premium. A user who cancels must lose interpretation, never records —
and their export must keep working, or the subscription becomes a hostage situation rather than a
purchase.

**Recommendation:** the free tier must remain genuinely useful, not a demo. The pitch is "your
health repository is yours and free; pay if you want BADAN to think about it for you."

---

## 2. The blocker nothing on this list survives without

**Only 4 of the ontology's 44 metrics are actually ingested today.** `HealthKitAdapter.readTypes`
reads sleep, heart rate, resting heart rate and step count. That is the whole set.

That means, right now:

| Family | Metrics in ontology | Ingested |
|---|---|---|
| sleep | 10 | partial (sessions + stages) |
| heart | 7 | 2 of 7 (`hr`, `rhr`) — **no HRV, no VO2 max, no BP, no HRR** |
| activity | 7 | 1 of 7 (`steps`) — no energy, distance, floors, walking speed |
| nutrition | 7 | **0 of 7** |
| body | 5 | **0 of 5** — no weight from Health, no body fat, no BMI |
| respiratory | 2 | **0 of 2** |
| subjective | 4 | manual only |
| symptoms | 2 | manual only |

Every headline premium idea below — biological age, nutrition coaching, fitness trends — is
computed from metrics BADAN does not currently receive. **The ingestion expansion (`PERF-181`) is
not a nice-to-have on the monetization path; it is the whole foundation.** Selling a subscription
whose features depend on absent data would recreate, at the till, exactly the class of dishonesty
this codebase has spent three audits removing.

**Sequencing consequence:** widen ingestion → accumulate real user history → *then* sell
interpretation of it. A premium tier shipped before the data exists would be empty for every
subscriber on day one, and worse for new users (who have no history to interpret at all).

---

## 3. Candidate premium features

Ranked by defensibility. "Cost" is engineering effort; "Needs" is the prerequisite that must land
first.

### Tier A — strong candidates (real work, honest to charge for)

**A1. Trends & correlations**
Long-window trend decomposition and cross-metric relationships ("your resting heart rate runs
higher in the weeks you sleep under 6h"). Baselines are free; *trends over time and relationships
between metrics* are BADAN's own analysis.
*Needs:* wider ingestion + ≥8 weeks of history. *Cost:* Medium. *Honest?* Yes — pure
interpretation, nothing withheld from the raw record.

**A2. Full history & unlimited retention windows**
Free tier interprets a rolling window (say 90 days); premium interprets all of it.
*Needs:* nothing new — this is a policy knob on existing engines.
*Cost:* Small. *Honest?* **Only if raw data older than the window stays visible and exportable.**
Paywalling *analysis depth* is fair; hiding a user's own old readings is not, and would breach the
guardrail outright.

**A3. Advanced sleep architecture**
Stage-level analysis, sleep-debt modelling, midpoint/consistency scoring, chronotype drift.
*Needs:* sleep is BADAN's best-covered family — closest to shippable. *Cost:* Medium.
*Honest?* Yes.

**A4. Nutrition analysis**
Macro balance over time, protein adequacy against body mass, caffeine-vs-sleep-latency,
hydration patterns.
*Needs:* **nutrition ingestion (0 of 7 today)** + body mass. *Cost:* Large (ingest + engine).
*Honest?* Yes, but far out — this is a roadmap item, not a launch feature.

**A5. Readiness, deepened**
Readiness exists free (a composite score). Premium: per-input contribution breakdown,
personalised weighting, and "what moved this today."
*Needs:* HRV ingestion (absent today). *Cost:* Medium. *Honest?* Yes — the score stays free;
the explanation deepens.

### Tier B — plausible, but weaker

**B1. Multi-source reconciliation controls** — let power users choose which source wins dedup.
*Cost:* Small–Medium. *Concern:* this is arguably a correctness feature, not a luxury.

**B2. Custom goals beyond N** — free gets a few goals, premium unlimited.
*Cost:* Small. *Concern:* cheap gating; feels petty and invites "why is a number a product?"

**B3. Widgets / complications** — *Concern:* platform convention treats these as table stakes;
charging reads as hostile.

**B4. Export scheduling / automated backups** — recurring exports.
*Concern:* export itself must stay free (guardrail). Scheduling is a genuine convenience on top,
so this is defensible — but see §5, it needs a backend.

### Tier C — do not gate

- **Anything raw**: readings, provenance, lineage, the metric browser, anatomy sheets.
- **Export in any format.** The guardrail's hard edge.
- **Deletion, privacy controls, the sensitive gate.** Never charge for privacy.
- **Arabic, RTL, accessibility, Dynamic Type.** Never charge for access.
- **Medication reminders.** Charging to be reminded of medication is indefensible in a health app
  and would be the single most reputationally damaging line item on this list.

---

## 4. "Biological age" — flagged, not recommended for launch

It was named explicitly, so it deserves a direct answer rather than a slot on the list.

**What it would take:** VO2 max, resting HR, HRV, blood pressure, body composition, activity —
**BADAN currently ingests two of those, partially.** It is the most data-hungry feature proposed
and the furthest from shippable.

**Why it is riskier than it looks:**

1. **It is a health claim.** "Your biological age is 34" asserts a clinical assessment of the
   user's body. BADAN's entire copy discipline is wellness-safe hedging ("a gentler pace may suit
   you today") specifically to stay out of that register. This feature is the opposite.
2. **App Review 1.4.1.** Health apps get scrutiny; a paid age-of-your-body number is exactly the
   shape reviewers probe, and the audit already notes 1.4.1 exposure.
3. **It is not falsifiable.** There is no ground truth. The number would be BADAN's invention
   presented with a precision it cannot support — the same category error as the fabricated sample
   data attributed to Apple Health, only sold rather than seeded.
4. **Charging for it compounds all three.** A hedged wellness estimate given away is defensible.
   The same estimate sold implies a confidence BADAN cannot back.

**If you want it anyway**, the conditions I would insist on: name it something that is not a
medical claim ("vitality trend", not "biological age"); publish the formula in the anatomy sheet
like every other derived value; show its inputs and coverage; and refuse to compute it below a
data threshold rather than degrading silently. That is buildable — but it should not be the thing
the paywall is *sold on*, because it is the least defensible item and the most likely to define
BADAN as the app that charged for a made-up number.

**Recommendation: build Trends (A1) and Sleep architecture (A3) as the launch premium. They are
real, defensible, and BADAN already has the data for A3.**

---

## 5. What the subscription actually requires

The account is **optional** (per your decision): the app must remain fully functional, offline,
and complete for a user who never signs in. That is a hard constraint on every design below.

**Sign in with Apple (optional).** Gives a stable identifier without a password. Note SIWA alone
does not need a backend — but a *subscription that follows the user across devices* does.

**Two viable shapes:**

| | On-device only (StoreKit entitlement) | Backend-verified (your choice) |
|---|---|---|
| Account | none needed | SIWA → user record |
| Entitlement source | `Transaction.currentEntitlements` | App Store Server Notifications v2 → your DB |
| Cross-device | via Apple ID, same store only | yes, and cross-platform |
| Android parity | separate Play Billing entitlement | one entitlement, both stores |
| Fraud/refund handling | Apple-managed | you handle webhooks |
| Ops burden | **zero** | real: hosting, auth, secrets, uptime, breach surface |
| Privacy posture | policy stays nearly intact | **materially changes** |

**The honest note on the backend:** it reverses `ADR-0002` ("No backend in MVP"), which is
Accepted and load-bearing — `backend/` and `infra/` are literally empty by decision, the export
module is lint-forbidden from importing networking (D-8), and "zero network calls" is a verified
claim in the privacy policy, the hosted policy, and the App Store record. Reversing it is a
legitimate product decision, but it needs a superseding ADR, a policy rewrite, a Data Safety /
privacy-nutrition update on both stores, and it introduces the breach surface ADR-0002 was written
to avoid — for a health repository.

**My recommendation:** ship the subscription **StoreKit-only first** (no backend, no accounts, no
policy reversal — Apple handles payment and entitlement), and add the backend + SIWA only when a
concrete requirement demands it (cross-platform entitlement, or sync). That gets you revenue
without betting the privacy posture on it. If you want the backend regardless, say so and I will
write the superseding ADR and scope it properly rather than bolt it on.

### RESOLVED — 2026-08-07 (ADR-0014 / D-44)

Both halves of the recommendation above happened, in order. StoreKit-only shipped first (D-32/D-33,
2026-07-28). Accounts followed on 2026-08-07 for the concrete requirement this section names:
**cross-platform entitlement**. The founder confirmed the direction after the reversal was stated
in full, and ADR-0014 is the superseding ADR this section asked for.

Three corrections to the table above, now that it is built rather than proposed:

- **"Entitlement source: App Store Server Notifications v2 → your DB" — not what shipped.** There
  is no server-side receipt validation and no webhook. Each platform reports what its *own signed
  local cache* says and the service relays it; the server never talks to Apple's or Google's
  billing APIs. That deliberately keeps purchase *history* off the server — the account holds one
  current product id per platform, not a ledger.
- **"Fraud/refund handling: you handle webhooks" — no.** Refunds and revocations are still
  Apple-managed and still arrive through `Transaction.currentEntitlements`, which excludes them
  automatically. The account learns about a lapse on the next push from the device that owns it.
- **"Privacy posture: materially changes" — correct, and it did.** BADAN now declares a collected
  `UserID` in `PrivacyInfo.xcprivacy`, both hosted and in-app policies were rewritten, and in-app
  account deletion became mandatory under App Review 5.1.1(v). What did *not* change is the thing
  this document exists to protect: no health datum reaches the account, and D-33 is still the only
  gate on a user's own records.

**Referrals** ride the same account (`ReferralPolicy`): a code grants both sides 30 days of
premium, one claim per account within 30 days of signup, referrer rewards capped at 10. Worth
stating against §1's line: a referral grants premium **time** and gates nothing new, so a user who
never refers anyone loses nothing they would otherwise have had.

---

## 6. Suggested sequence

1. **Widen ingestion (`PERF-181`)** — nothing here is sellable without it.
2. **Ship A3 (sleep architecture) free-tier-adjacent** to prove the engine on the best-covered data.
3. **StoreKit supporter/premium tier**, gating A1 + A3.
4. **Optional SIWA + backend** only if cross-platform entitlement or sync is actually required.
5. **A4 (nutrition)** once nutrition ingestion lands.
6. Revisit "biological age" under §4's conditions, if at all.

---

## 7. Open questions for the owner

1. Free-tier interpretation window — 90 days? (Raw stays unlimited and exportable regardless.)
2. Price and cadence; is there a lifetime option?
3. Does Android launch with parity, or does iOS lead? (Android is weeks from Play as of the last
   audit.)
4. Do existing TestFlight users get grandfathered?
5. Backend now, or StoreKit-only first (§5)?
