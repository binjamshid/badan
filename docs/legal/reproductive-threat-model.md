# Reproductive-data threat model

**Status:** Engineering/product draft, commissioned per `BADAN_WHOOP_HAE_EXECUTION_PLAN.md` §28.1
action 13, written before any EPIC-39 (cycle intelligence) code ships, per that same plan's
explicit prerequisite. **This document is not a legal opinion and does not substitute for one.**
It is the threat-model half of a two-part prerequisite — the plan's own words: "Commission
`docs/legal/reproductive-threat-model.md` **and** the GCC/Oman legal review scope... independent
of engineering." This file is the engineering side: what data would exist, who could want it, what
could go wrong, and what BADAN's architecture already does or must newly do about it. The GCC/Oman
legal review itself — retaining counsel, scoping the actual regional legal exposure, and producing
a sign-off — is a separate, founder-only action this document cannot perform and does not attempt
to. **A18** (pregnancy) and the fertile-window/ovulation portions of EPIC-39 (**A17**) stay blocked
on that legal review regardless of what this document says; nothing here closes those gates.

Grounded in `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` (existing prior research in this repo,
particularly §9 "Privacy and safety architecture") and the plan's own framing at
`BADAN_WHOOP_HAE_EXECUTION_PLAN.md:1200`: *"the post-Dobbs pattern (subpoenaed cycle data, Flo/FTC
signal-sharing, broker sales)... local data needs a warrant; cloud data a subpoena."*

---

## 1. Why cycle data is different from every other health-data family BADAN handles

Every other sensitive-plus family in BADAN (medications, symptoms, journal behaviors) can embarrass
or inconvenience a user if exposed. Reproductive-cycle data — period dates, whether a period was
missed, contraceptive-context intervals, fertile-window/ovulation signals if ever built — carries a
category of risk the others do not: in some jurisdictions, this data can be used as *evidence* in a
criminal or civil proceeding (most acutely, post-*Dobbs* US abortion-related prosecutions built in
part on period-tracker and search data; less-publicized but real precedent also exists around
miscarriage prosecutions). It can also be weaponized by an abusive partner specifically *because*
it reveals pregnancy status, a missed period, or contraceptive use — information someone may have
strong, safety-critical reasons to keep from a partner, family member, or employer. This is not a
hypothetical: it is the documented reason several competing period-tracking apps (Flo, most
visibly, via FTC enforcement) have faced regulatory action for exactly the data-sharing patterns
this document exists to make sure BADAN never has the architecture to repeat.

Two properties of BADAN's existing design are unusually well-suited to this threat, and this
document's job is partly to make sure the cycle module doesn't accidentally erode them:

- **BADAN has no backend (ADR-0002).** There is no BADAN-operated server that could receive a
  subpoena, be breached, or be compelled to hand over reproductive data en masse, because BADAN
  never has custody of it in the first place. This is the single strongest mitigation available and
  the cycle module must not be the feature that reverses it (reversing ADR-0002 needs **A4**, an
  entirely separate, explicit, ADR-documented decision — see `docs/adr/`).
- **Local data needs a warrant; cloud data (typically) needs only a subpoena, and often not even
  that if a vendor's own privacy policy already permits sharing.** Keeping cycle data device-local
  by default means the legal bar for a third party to compel access is categorically higher (a
  warrant requiring probable cause and judicial sign-off, served on the *device owner*, not a
  subpoena served on a company that holds thousands of users' data at once).

## 2. Assets in scope

Per `docs/BADAN_PERIOD_TRACKER_RESEARCH.md`'s own data-model matrix, the cycle module's eventual
full scope includes: `CycleRecord` (period start/end/ongoing), `FlowLog`, cycle-linked
`SymptomLog` entries, `BasalTemperatureLog`, `OvulationSignalLog`, `ContraceptiveContextLog`,
derived `CyclePrediction`/`CyclePhaseEstimate`/`AnomalyEvent` rows, `ModuleVisibilitySetting`, and
(explicitly gated, not in this phase's scope) `SharingConsentRecord`.

**This phase (3F, per `docs/HANDOFF.md`'s own scoping) covers only:** period/flow logging,
history-based prediction windows, the anomaly engine, phase-conditioned baselines, and the consent
architecture underneath all of it. **Explicitly out of scope for this phase, tracked separately:**
fertile-window/ovulation estimation (gated on **A17**), BBT/signal-assisted refinement, sexual-
activity logging, and sharing of any kind (on the founder's standing do-not-build list regardless
of approval state). The threats below are analyzed for the FULL eventual scope, since a threat
model written only against the narrower current slice would need rewriting the moment the next
slice landed — but the mitigations section states plainly which protections are already load-
bearing today versus needed before a later slice ships.

## 3. Threat actors and what each one can actually get

| Threat actor | Realistic access vector | What they'd learn | Severity |
|---|---|---|---|
| **Law enforcement / court order, in a jurisdiction that criminalizes some pregnancy outcomes** | A warrant served on the device (requires possession or forensic extraction) — *not* a subpoena to BADAN, because BADAN has no server holding this data | Full local cycle history, if the device itself is seized/unlocked | High impact, but the *access mechanism itself* (a warrant against a specific device, not a subpoena against a company holding many users' data) is the correct, hardest-to-abuse channel — this is the whole point of local-first |
| **Abusive intimate partner / family member with device or account access** | Shoulder-surfing, a shared/known device passcode, an unlocked phone, a Lock Screen widget, a shared Apple ID/iCloud backup | Period dates, a missed period, contraceptive context, cycle anomalies | High — this is arguably the MOST LIKELY real-world harm scenario for this data family, more common than law-enforcement access, and needs to be designed against explicitly (see §5) |
| **Data broker / ad-tech SDK, if one were ever integrated** | A third-party analytics/ad SDK with read access to app data or network traffic | Aggregate or individual reproductive-health signals sold onward (the Flo/FTC pattern) | High if it ever happened; BADAN's answer is structural exclusion (§5), not a policy promise |
| **Device thief / opportunistic access to a lost/stolen unlocked phone** | Physical device access | Whatever the Lock Screen/widget/notification surfaces without unlocking, plus full access if the device itself is unlocked | Medium — bounded by the same Lock Screen/widget redaction rules already built for Phase 3D |
| **Cloud sync provider / iCloud backup, if cycle data is ever synced** | A compelled disclosure to Apple/Google, or a breach of the sync provider | Cycle data ONLY if the user has explicitly opted into sync for this family | Contingent — zero exposure while sync consent is off (the shipped default); this is why the consent stack in §5 keeps sync as its own explicit, separate toggle rather than inherited from a general backup setting |
| **BADAN itself / a future engineering mistake** | A future feature (an SDK integration, an ambient/widget surface, an export default) that leaks reproductive-plus data somewhere it shouldn't | Any of the above, accidentally, at BADAN's own hand | The threat this document's mitigations section is written to prevent by construction, not by review |
| **Employer / insurer** | Indirect — e.g., a workplace-managed device, or (in some markets) health-insurance data requests | Cycle/pregnancy status | Low today (no B2B/insurer integration exists or is planned in this plan), but worth naming so a future integration decision revisits this table |

## 4. Regional context: do not assume US/EU norms apply

Per the plan's own explicit instruction, this document must not assume Oman/GCC legal and cultural
context is equivalent to US or EU norms, and this draft does not attempt to. What follows are
**engineering-relevant open questions for actual retained GCC/Oman counsel** — this document poses
them, it does not answer them:

- Whether local law imposes any data-residency requirement that would affect where an export file
  or a future sync destination could lawfully be stored (relevant only if/when sync or cloud
  destinations are ever built for this family — today there are none).
- Whether local law creates any disclosure obligation on BADAN (a company) that differs from the
  "no server, no data to disclose" posture this document leans on — i.e., confirm the local-first
  architecture's legal protection actually holds under Omani/GCC law the way it's understood to
  under the US/EU frameworks this document's research draws on.
- Cultural and social context: in the GCC region, reproductive-health data (unmarried pregnancy,
  contraceptive use) can carry social/family risk distinct from — and in some respects more acute
  than — the legal risk this document otherwise focuses on. The abusive-partner/family-member
  threat-actor row above should be read as *elevated*, not equivalent, in this regional context;
  retained counsel and, ideally, a regional clinical/cultural advisor (the plan already calls for a
  clinical advisor under **A18/A25**) should weigh in on copy, defaults, and discoverability
  choices (e.g., how easy the module is to hide, whether a neutral "cycle" vs. explicit "period"
  default language choice — already a stated option in the research doc — should default one way
  or the other for this market).
- Any local telecom/app-store-level content or data-protection regulation specific to reproductive
  health that could affect App Store listing, in-app copy, or the module's very availability in
  this market.

**This document explicitly does not answer these questions.** They are the scope of the
"GCC/Oman legal review" half of plan action 13, which needs a retained lawyer, not an engineering
draft.

## 5. Mitigations — what's already load-bearing today, and what this phase must add

### Already true of BADAN's existing architecture (not new to this phase)

- **No backend (ADR-0002).** Nothing to subpoena, breach at scale, or be compelled to hand over —
  see §1.
- **Sensitive-plus namespace (I7).** Every sensitive-plus family already lives in a physically
  separate `badan_sensitive.db`, purged by a literal file deletion
  (`Database.purgeSensitiveNamespace()`) rather than a row-by-row sweep that could miss something.
  The cycle module's tables must land there from the start, never in `badan.db`, exactly like
  journal/medication/lab data already do.
- **No cloud AI / analytics SDK boundary (plan's §41 "SDK data-access boundary").** BADAN has no ad
  or analytics SDK with access to app data at all today. This phase must not be the one that
  introduces the first such SDK for any reason — the plan's own answer to the Flo/FTC pattern is
  that this boundary is enforced structurally (a compile-time/module boundary + CI lint per
  EPIC-43's own SDK boundary work), not a policy promise nobody checks.
- **Structural sensitive-plus exclusion from ambient surfaces.** Phase 3D's widget/ambient system
  already established the precedent this module must follow exactly: a sensitive-plus family gets
  no Lock Screen/StandBy widget variant *at all* (not a redaction toggle that could be missed) —
  see `MedsDueWidget`'s `.supportedFamilies` restriction as the template. Cycle data must never
  appear in `AmbientSnapshotDto` under any circumstance in this phase; if a future phase ever wants
  a cycle-aware ambient surface, it needs its own explicit design and its own audit, not an
  inherited assumption that the existing snapshot pattern already covers it safely.
- **Default-off, non-sticky sensitive export.** BADAN's export system already requires an explicit
  `includeSensitive` scope per run, never a saved "always include" default — the cycle module rides
  this existing convention, it does not need a new one.

### New, specific to this phase — must be built, not assumed

- **A dedicated, cycle-specific consent screen**, not folded into general HealthKit/platform
  permission copy, following the layered stack `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §9 already
  specifies: (1) platform read/write explanation, (2) BADAN cycle-module explanation with the
  local-first default stated plainly, (3) an OPTIONAL, separate sync-consent toggle for the cycle
  family alone (off by default; today there is no sync destination for this data at all, so this
  toggle should not even be offered until a real sync capability exists to gate — do not build a
  consent toggle for a capability that doesn't exist yet, that is exactly the kind of stub this
  codebase's standing principle forbids).
- **Retain-vs-purge on module disable, and purge must actually cascade.** Turning the cycle module
  off must offer a real choice (keep the data, hidden, vs. delete it), and choosing purge must
  delete the rows, invalidate every derived prediction/phase-estimate/anomaly row that depended on
  them (never leave a stale prediction rendering from data that was supposedly deleted — this is
  exactly the class of bug this session's Phase 3D audit caught in the widget snapshot/purge
  interaction, and the cycle module must not repeat it), and go through the same
  `purgeSensitiveNamespace()` mechanism (or an equally real, tested deletion path) as every other
  sensitive family.
- **Never a single-date confidence claim.** Predictions render as a range with a stated method and
  confidence, never a bare date presented as fact — this is both a false-precision violation (this
  codebase's standing non-negotiable) and specifically a safety property here: a falsely-confident
  "your period is due on X" is a worse harm surface than an honestly-uncertain range, both for the
  user's own trust and for anyone who might see the screen over their shoulder.
- **Contraceptive-context awareness pauses/broadens predictions rather than confidently predicting
  through it** (CYCLE-07 in the plan) — a wrong prediction during, say, hormonal contraceptive use
  is not just inaccurate, it can misinform a real decision.
- **Anomaly copy stays calm and non-diagnostic**, per the existing anomaly-matrix research (e.g.
  never implying hemorrhage, deficiency, or a named medical condition from a flow-intensity
  deviation) — this is a wellness-safety concern independent of the legal/privacy threat model, but
  it compounds it: alarming copy about a missed period is exactly the kind of screen content an
  abusive partner glancing at a phone would find most exploitable.
- **Neutral-by-default language choice.** `docs/BADAN_PERIOD_TRACKER_RESEARCH.md` already names
  "cycle" vs. direct "period" as a real, user-facing choice (echoed in the plan's own EPIC-39 card
  language, "neutral 'cycle' vs direct 'period' language choice"). Given §4's regional-context
  caveat, default to the more neutral framing pending the actual legal/cultural review, and make
  the choice user-adjustable rather than hard-coded either way.

## 6. What this document deliberately does not do

- It does not authorize shipping the pregnancy module (**A18**), fertile-window estimation
  (**A17**), or sexual-activity logging — those stay blocked on their own named approvals
  regardless of anything above.
- It does not constitute the "GCC/Oman legal review" plan action 13 requires alongside this
  document — that needs retained regional counsel, and §4's open questions are for that counsel,
  not answered here.
- It does not claim BADAN's architecture makes reproductive data invulnerable. Per
  `docs/BADAN_PERIOD_TRACKER_RESEARCH.md`'s own "Trust messaging" guidance, the honest claims are
  "stored on this device by default," "excluded from cloud AI unless you turn that on," and
  "sensitive data is off in exports unless you choose otherwise" — never "fully private,"
  "unhackable," or "impossible for anyone else to access." Any user-facing copy this phase writes
  must stay inside that same honesty boundary.

## 7. Open items, tracked explicitly rather than silently

1. **Commission actual GCC/Oman legal review** (founder action, plan §28.1 action 13's other
   half) — this document's §4 is the starting scope for that engagement, not a substitute for it.
2. **Decide the default language framing** ("cycle" vs "period") with input from that legal review
   and, ideally, a regional cultural/clinical advisor once retained (**A18/A25**'s advisor search is
   already a standing founder action per plan §28.1 action 11).
3. Revisit this document before EPIC-39 tasks CYCLE-09 through CYCLE-14 (symptom overlay through
   sharing) ship, and explicitly before EPIC-40 (pregnancy) starts — new data types and a sharing
   feature each change this threat model's asset inventory and threat-actor table materially enough
   to need a fresh pass, not an assumed extension of this one.
