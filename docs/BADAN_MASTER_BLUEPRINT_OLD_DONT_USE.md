# BADAN Master Product Blueprint

**BADAN بدن — The Body's Own Ledger**
A long-lived product, design, engineering, data, analytics, compliance, and roadmap blueprint for a next-generation personal health intelligence platform.

- **Document status:** v1.0 master blueprint (living document)
- **Date:** July 2026
- **Inputs consumed:** (1) "Health Analysis Apps: A Developer's Deep Report" — full market, feature, architecture, open-source, testimonial, and strategy analysis benchmarked against Bevel, WHOOP, and Oura; (2) a ~6-minute screen recording of Bevel (July 2026 build, Bevel Intelligence V2 era) analyzed frame-by-frame across all tabs, detail screens, settings trees, paywall, and customization systems.
- **Scope:** wellness and personal health tracking, interpretation, logging, reporting, and user-controlled data workflows. This document does not describe a medical device, does not make diagnostic or treatment claims, and treats all clinical-adjacent capability as regulatory-aware future potential, explicitly labeled as such.

---

## Table of Contents

1. Executive framing
2. Product philosophy
3. User archetypes
4. Jobs to be done
5. Product positioning
6. Competitive benchmark against Bevel and adjacent apps
7. Principles for surpassing Bevel
8. Experience architecture
9. Complete feature universe
10. Health metric ontology
11. Data ingestion and interoperability
12. HealthKit and Android equivalent capability map
13. Device ecosystem compatibility strategy
14. Information architecture
15. Navigation model
16. Screen-by-screen app blueprint
17. Casual-user mode design
18. Power-user mode design
19. Personalization and customization system
20. Raw data, reports, and export system
21. Food, exercise, symptoms, medications, and issues logging
22. Analytics and longitudinal intelligence
23. AI and interpretation layer
24. Notifications, widgets, watch, and ambient experiences
25. Visual design system
26. Interaction design system
27. Learning curve and education system
28. Privacy, consent, trust, and responsible UX
29. Compliance and regulatory-aware architecture
30. Data architecture and domain modeling
31. Backend architecture
32. On-device architecture
33. Cross-platform mobile architecture
34. Offline, sync, and conflict-resolution strategy
35. Search, filtering, and query experience
36. Observability, analytics, and experimentation
37. Failure modes, edge cases, and resilience planning
38. Growth, retention, and habit formation
39. Monetization and packaging strategy
40. Team structure and execution model
41. Phased roadmap
42. Detailed backlog seed
43. Open-source and third-party build strategy
44. Risks, traps, and anti-patterns
45. Future expansions
46. Final synthesis

---
---

## 1. Executive framing

### 1.1 What BADAN is

BADAN (بدن — Arabic for "body") is a **personal health repository and interpretation layer**: a single place where every health signal a person can practically collect — wearable biometrics, sleep, workouts, nutrition, glucose, cycle data, symptoms, medications, body composition, lab biomarkers, subjective mood and energy — is ingested, normalized, stored with provenance, interpreted in plain language, and returned to the user in whatever form they want: a one-line morning summary, a trend chart, a narrative PDF, or a raw CSV.

BADAN is simultaneously two products sharing one data model:

1. **For the casual user:** an app that requires *near-zero interaction* to be useful. Connect a data source once, glance at one screen each morning, read one honest sentence about your body. Never forced to log anything, never punished for passivity, never confronted with a wall of numbers.
2. **For the power user:** the most inspectable, exportable, longitudinally deep consumer health platform on the market. Every score decomposable to its inputs. Every input traceable to its source sample. Every dataset exportable in machine-readable form. Every algorithm documented in-app.

This dual nature is not a compromise; it is the core product thesis. The market report is explicit that casual users "pay for the interpretation of data, not the raw data itself" while power users churn precisely when interpretation is opaque, unexportable, or contradicts how they feel. Both problems have the same solution: **an interpretation layer built on radical data transparency**, where the same underlying truth is rendered at two altitudes.

### 1.2 Why now — the strategic window

The report identifies a second-wave market inflection: step counters and dashboards are commoditized; the frontier is *connected health intelligence* — fusing wearables, nutrition, clinical data, and AI coaching. Bevel currently leads this direction, but the report and community evidence document five simultaneous gaps that **no current leader has closed together**:

| # | Documented gap | Who fails | BADAN's answer |
|---|---|---|---|
| 1 | Genuine device agnosticism | WHOOP (own hardware), Oura (ring), Bevel (Apple Watch–primary, iOS only) | All wearables as equal citizens; iOS + Android at parity from architecture day one |
| 2 | Female physiology as a covariate in all scores | WHOOP (documented luteal-phase false alarms), Bevel (cycle as a bolt-on module) | Cycle phase modeled inside every baseline and score, not beside them |
| 3 | Private, on-device AI | All (cloud-first AI) | Tiered AI with an on-device path and an explicit "nothing leaves the phone" mode |
| 4 | Raw data export / user API | WHOOP ❌, Oura ❌, Bevel ❌ | CSV/JSON/PDF/FHIR-shaped export as a *free, first-class* feature, plus a personal data API |
| 5 | Non-punitive pricing | WHOOP ($30/mo, most-criticized attribute), Bevel (core interpretation paywalled) | Generous free tier where the *repository* is never paywalled; premium is depth-of-interpretation |

The video analysis adds a sixth, subtler gap: **Bevel's new-user experience is a field of locked rings, dot-scrambled paywalled numbers, "Calibrating," and empty states.** A brand-new Bevel user in the recording sees "No data" or a padlock on roughly half the surfaces they visit in the first six minutes. BADAN's day-one experience is designed in Section 27 and 37 to be the opposite: honest about calibration, but always giving something real immediately.

### 1.3 What BADAN is not

- Not a medical device, a diagnostic tool, or a treatment recommender. Wording guardrails are engineered into the interpretation layer (Section 23.9, 28).
- Not a hardware company. BADAN never privileges its own sensor because it has none.
- Not a Bevel clone. Bevel is the benchmark for metric coverage and interpretive tone; BADAN must **match its coverage floor** (Sections 9–10 define that floor precisely from the recording) and then diverge structurally where Bevel is weak: export, Android, community, offline-first data ownership, medications/symptoms/conditions as first-class citizens, and Arabic/RTL internationalization from day one.
- Not a social network first. Community features arrive in Phase 3, carefully scoped (Section 38), because the report shows they matter for retention — but they are additive, never load-bearing.

### 1.4 The one-paragraph pitch

> Your body produces data all day. Today that data is scattered across a watch app, a ring app, a food app, a pharmacy bag, and a lab PDF — each fragment interpreted by a different company, none of it truly yours. BADAN gathers all of it into one private repository you actually own, explains it in one honest sentence a day (or a 40-page report, if that's who you are), works in your language, on your platform, with your devices — and lets you take every byte with you, forever.

### 1.5 Success criteria for this blueprint

A serious product and engineering organization should be able to use this document to:

- staff and sequence 36 months of work (Sections 40–42);
- build the canonical data model before the first screen ships (Section 30);
- pass privacy review in the EU, GCC, and US wellness contexts (Sections 28–29);
- meet or exceed Bevel's observed feature surface (checklists in Sections 6, 9, 16);
- and resolve, repeatedly and explicitly, the central tension: **broad + deep + calm**. Every section below returns to that tension and solves its local version of it.

---
---

## 2. Product philosophy

### 2.1 The seven laws of BADAN

Each law is stated, justified strategically and from user evidence, and given engineering consequences. These laws are decision-arbiters: when two designs conflict, the lower-numbered law wins.

**Law 1 — The repository is sacred; the interpretation is a service.**
The user's data — raw samples, logs, provenance — is the permanent, free, exportable core. Interpretations (scores, insights, AI narratives) are a layer BADAN adds on top and may monetize. Consequence: no design may ever hold *raw user data* hostage behind a paywall, a subscription lapse, or an account deletion flow. Bevel gates the Nutrition Score ring and Biological Age number behind Pro (observed as padlocked rings and particle-scrambled values); BADAN may gate *derived intelligence*, never *ingested data or manual logs*. Engineering consequence: the storage layer is architecturally separated from the scoring layer (Section 30), so that entitlement checks physically cannot intercept raw reads.

**Law 2 — Honesty over reassurance, but kindness over alarm.**
The single most-cited churn driver in the report is "the algorithm disagrees with how I feel." The correct response is not softer numbers; it is *explained* numbers with *confidence levels*. Every score ships with: (a) its top contributing inputs, (b) a confidence/quality indicator, (c) a "why am I seeing this" affordance, and (d) non-alarmist phrasing rules (Section 23.9). During calibration, BADAN says "I'm still learning your baseline — this number will wobble for ~2 more weeks" rather than presenting a confident wrong number.

**Law 3 — Zero-effort utility; opt-in depth.**
A user who does nothing but grant permissions must receive daily value indefinitely. Logging (food, symptoms, meds) multiplies value but is never a precondition. Consequence: every feature is designed twice — a passive variant fed by ambient data, and an active variant enriched by logs. Bevel's "Log 776 kcal to unlock today's Nutrition score" is the anti-pattern: it makes passive users feel deficient. BADAN's nutrition surface shows *whatever exists* (even just active-energy context) and invites, never demands.

**Law 4 — One data model, two altitudes.**
Casual and power modes are *renderings*, not forks. The same canonical metric record powers the one-ring glance and the 90-day rolling-delta table. Consequence: there is no "advanced database" — there is one database and a progressive-disclosure system (Sections 17–18). This is the recurring tension of the whole product, and the answer is always: depth exists everywhere, but is *reached*, never *imposed*.

**Law 5 — Provenance or it didn't happen.**
Every stored value carries: source device, source app, ingestion path, timestamp(s), timezone, algorithm version (for derived values), and quality flags. Consequence: dedup and conflict resolution become tractable (Section 34); exports become trustworthy (Section 20); "why does my sleep differ from my ring app?" becomes answerable in-product. Bevel exposes an impressive Data Sources screen (per-metric source counts, device lists, hide-sources); BADAN matches it and extends it to per-*sample* lineage.

**Law 6 — The body is one system; the app must feel like one app.**
The most damning power-user critique of Bevel in the report: "Bevel can occasionally feel somewhat fragmented" versus WHOOP's "cohesive roadmap." Consequence: cross-pillar links are mandatory. Sleep detail references last night's late meal; recovery references yesterday's strain and cycle phase; the timeline interleaves all event types on one axis. Section 8 defines the "connective tissue" systems (Timeline, Correlations, Daily Narrative) that stitch pillars together.

**Law 7 — Built for the world, not for one platform or one language.**
iOS + Android at feature parity (Section 33), full RTL and Arabic localization at launch (BADAN's name is Arabic; the Gulf market is underserved by every competitor and the recording itself shows a Muscat-based user running an English-only app), metric/imperial and local units (mmol/L vs mg/dL both first-class), and cultural awareness in nutrition (regional food databases, Ramadan-aware fasting context as a neutral "schedule context," prayer-time-quiet notification windows as generic quiet hours).

### 2.2 Emotional register

BADAN must be **not boring, not sterile, not intimidating, not clinical** — the explicit brief. The design register (fully specified in Section 25):

- **Warm-serious.** Think "trusted personal notebook," not "hospital chart" and not "gamified toy." Bevel's scenic hero illustrations (dusk hills behind the Recovery ring, night cliffs behind Sleep) are the single best emotional device observed in the recording — they make biometrics feel human. BADAN adopts the *principle* (evocative, calm art tied to metric state) with its own visual language (Section 25.4: a generative "inner landscape" that subtly reflects the day's state).
- **Confident, plain language.** Bevel's coaching sentences ("Your Resting HRV (25.4 ms) is near its average of 31.4 ms") are the right altitude: concrete numbers embedded in humane prose. BADAN standardizes this as the *Narrative Voice* (Section 23.8) with tone controls.
- **Delight in the details, never in the way.** Micro-animations on ring fills, haptic ticks on chart scrubbing, celebratory moments for streaks that the user opted into — but no confetti storms, no shame mechanics, no red badges for missed logs.

### 2.3 The trust ladder

Trust is the product's actual currency. BADAN's trust ladder, each rung a designed system:

1. **Accuracy trust** — data matches the source apps (dedup pipeline, Section 30.6; reconciliation UI, Section 37).
2. **Interpretation trust** — scores match lived experience or explain why not (confidence bands, context statuses like Bevel's Active/Sick/Injured/On-a-Break — adopted and extended in Section 10.13).
3. **Privacy trust** — visible, revocable, local-first (Sections 28, 32).
4. **Ownership trust** — export everything, delete everything, verifiable (Section 20).
5. **Longevity trust** — the repository outlives devices, subscriptions, and platform switches (cross-platform sync, Section 34; open export formats, Section 20).

### 2.4 What we copy, improve, and reject from Bevel — philosophy level

| Dimension | Copy | Improve | Reject |
|---|---|---|---|
| Interpretive tone | Plain-language coaching sentences with real numbers | Add confidence + "why" affordance to every one | Overclaiming certainty during calibration |
| Progressive disclosure | Detail-sheet template (value → status vs personal range → chart → trends table → resources → definition) | Make the template universal across *all* metric types incl. labs, meds, symptoms | Burying core value behind Pro locks on the first screen |
| Contextual status | Activity Status (Active/Sick/Injured/On A Break) propagated to trends | Extend to richer context taxonomy (travel, fasting, medication change, cycle phase) feeding scoring as covariates | Treating context as a manual-only afterthought |
| Data controls | Calculations settings (HRV method, RHR method, source windows), Data Sources with hide/merge | Expose per-metric algorithm docs and per-sample lineage | Hiding algorithm behavior entirely |
| Visual system | Dark-first, pillar accent colors, band-charts with personal ranges | Add full light theme, accessibility-first palettes, RTL mirroring | Single-theme lock-in; decorative charts without axes |
| Monetization | Free trial, yearly discount | Repository-free / intelligence-paid split | Locking the day-one hero number (Bio Age particle-scramble) — teasing is fine, but BADAN teases with *a real limited version*, not an obfuscated one |

---
---

## 3. User archetypes

Twenty archetypes, each with: profile, devices, motivation, behavior pattern, value proposition, danger (how BADAN could fail them), depth setting (default rendering altitude), and key features. Archetypes are not market segments for exclusion — they are *design test fixtures*: every major screen in Section 16 must pass "would archetype X understand this / would archetype Y respect this?"

### 3.1 Rania — the passive casual user
- **Profile:** 34, project manager, Apple Watch worn daily "because it came with the phone plan." Never opens Apple Health.
- **Motivation:** vague desire to "be healthier"; zero appetite for logging.
- **Behavior:** opens BADAN 3–5 mornings/week for <30 seconds. Never customizes. Never exports.
- **Value prop:** the One True Sentence — a single honest daily summary ("Slept 6h10m, below your usual. Body's fine; take it easy on caffeine after 3pm.") plus three glanceable rings.
- **Danger:** intimidation (a wall of biomarkers), guilt mechanics (red "you didn't log" states), paywall resentment.
- **Depth setting:** Casual (default). Health Monitor grid collapsed to 3 tiles. No nutrition module visible until she logs once or connects a source.
- **Key features:** Daily Narrative, morning widget, auto-everything, empty-state suppression (modules with no data self-hide, unlike Bevel's persistent 0g/0g/0g macros row).

### 3.2 Omar — the lightly engaged wellness user
- **Profile:** 41, gym twice a week, walks the dog, wants gentle guidance.
- **Motivation:** "Am I doing okay? What one thing should I change?"
- **Behavior:** opens daily, taps into one detail screen/week, logs food "sometimes for a week after New Year's."
- **Value prop:** weekly digest with one actionable theme; forgiving streaks (streak "freezes"); habit nudges he configured himself.
- **Danger:** noise (too many notifications), fragmentation (five scores that don't cohere).
- **Depth:** Casual+, weekly report enabled.
- **Key features:** Weekly Report, single-focus recommendations, notification throttling (Section 24.8).

### 3.3 Ayesha — the Apple Watch heavy user
- **Profile:** 29, closes rings religiously, owns AirPods, sleeps with the watch.
- **Motivation:** wants what the report's testimonial called "the app Apple should have built": interpretation of the data Apple Health leaves raw.
- **Behavior:** checks after every workout; cares about HR zones, HRR, VO₂ Max trend.
- **Value prop:** full HealthKit depth — every quantity type read, workout segments, HR recovery post-workout, watch app + complications.
- **Danger:** discrepancies vs Apple's own numbers without explanation (dedup/lineage must be visible).
- **Depth:** Balanced.
- **Key features:** watchOS app, live workout strain, HealthKit calculation-method controls (BADAN adopts Bevel's "HRV method: RMSSD-from-raw-beats vs Apple's field; sample window: entire sleep vs deep sleep" and documents each choice in-line).

### 3.4 Tariq — the Android / Health Connect user
- **Profile:** 37, Samsung Galaxy Watch 7 + Pixel phone; burned twice by iOS-only health apps.
- **Motivation:** parity. He reads "iOS-first" as "Android-never."
- **Behavior:** will test export and permission granularity within the first hour.
- **Value prop:** Health Connect as a first-class citizen — every read/write BADAN does on iOS has a mapped equivalent or documented fallback (full matrix in Section 12); Wear OS tile + complications.
- **Danger:** silent feature gaps (a nutrition write-back that exists on iOS only), background-sync death by OEM battery managers (Section 37.6).
- **Depth:** Balanced/Power.
- **Key features:** Health Connect integration incl. background reads, OEM battery-optimization onboarding flows, direct Samsung Health path where Health Connect lacks types.

### 3.5 Dmitri — the quantified-self enthusiast
- **Profile:** 33, software engineer; Oura + Garmin + smart scale + spreadsheet of everything since 2019.
- **Motivation:** the repository itself. Wants BADAN to be the canonical store he's been building badly in Google Sheets.
- **Behavior:** exports monthly; audits dedup decisions; files precise bug reports; evangelizes if respected.
- **Value prop:** raw sample explorer, per-sample provenance, CSV/JSON/SQLite export, personal API token, import of historical archives (Apple Health export ZIP, Garmin/Oura/Fitbit takeouts).
- **Danger:** any opaque number; any export that omits fields; any "we know better" resistance to his corrections.
- **Depth:** Power (full).
- **Key features:** Raw Data Explorer (Section 20.4), correlation lab, algorithm changelog, import connectors (Section 13.9).

### 3.6 Lena — the hybrid athlete
- **Profile:** 27, CrossFit + 10k races; Garmin Forerunner + chest strap.
- **Motivation:** balancing strength and cardio load; avoiding overtraining while progressing both.
- **Behavior:** 2 workouts/day peaks; reviews strain vs target after each; plans deloads.
- **Value prop:** Bevel-grade training load system (acute:chronic cardio load with Detraining→Overtraining statuses, Target Strain ±band, breakdown tables — all observed in the recording) *plus* an honest muscular-load channel so strength work isn't invisible to recovery.
- **Danger:** cardio-only load models that call her strength days "rest."
- **Depth:** Power (fitness-forward preset).
- **Key features:** dual-channel load (cardio + muscular), Muscle-group radar (Volume/Frequency/Load switcher, as Bevel), HR zone editor with per-sport zones (exceeding Bevel's single Max-HR method), race/deload calendar context.

### 3.7 Yusuf — the strength trainee
- **Profile:** 24, 5 gym sessions/week, tracks lifts in a notes app.
- **Motivation:** progressive overload evidence: e1RM trends, volume per muscle group, plateaus.
- **Value prop:** full resistance logging (exercise DB, sets×reps×weight×RPE, rest timers, supersets, templates — Bevel's "Strength Builder" equivalent), Strength Progression per exercise (total reps, volume, e1RM, heaviest lift — matching Bevel's stated coverage), muscular breakdown radar.
- **Danger:** cardio-centric scores telling him he "did nothing" on leg day; clunky logging (>3 taps per set).
- **Depth:** Balanced (strength preset).
- **Key features:** ultra-fast set logger with plate math, template reuse, Apple Watch/Wear OS set logging, muscular recovery estimates clearly labeled heuristic.

### 3.8 Ingrid — the endurance user
- **Profile:** 45, marathoner; Garmin Fenix; trains by plan.
- **Motivation:** training load periodization, sleep as recovery input, race readiness.
- **Value prop:** cardio load with ACWR grounding (the report validates acute:chronic ratio), VO₂ Max trajectory, Cardio Focus distribution (Low Aerobic / High Aerobic / Anaerobic — Bevel's taxonomy, adopted), HRR trend as fitness signal.
- **Danger:** double-counted workouts (Garmin + Watch both reporting — dedup criticality), naive load models ignoring heat/altitude context.
- **Depth:** Power.
- **Key features:** Garmin direct integration, workout-file-level detail (laps/splits if available), context tags (heat, altitude, illness) as covariates.

### 3.9 Faisal — the longevity-focused biohacker
- **Profile:** 38, follows Attia/Huberman content; quarterly blood panels; sauna, zone 2, supplements.
- **Motivation:** slow aging measurably. Cares about ApoB, hs-CRP, HbA1c, VO₂ Max as mortality proxies.
- **Value prop:** the Biology pillar: 390+ biomarker catalog (matching Bevel's observed alphabetical registry from ApoB to WBC), manual + PDF lab entry, biological-age model *with full explainability* (unlike Bevel's paywalled particle-scramble, BADAN shows the inputs and their weights), longevity-mode dashboard preset.
- **Danger:** pseudo-precision (bio-age to two decimals with no confidence interval), clinical-claim wording that erodes credibility.
- **Depth:** Power (longevity preset).
- **Key features:** lab timeline with reference ranges, biomarker↔lifestyle correlation views, wellness-framed (non-diagnostic) interpretation, export for physician visits.

### 3.10 Mariam — the cycle-aware user
- **Profile:** 31, tracks her cycle; wears Oura; frustrated that her old app "panicked every luteal phase" (the exact WHOOP failure documented in the report).
- **Motivation:** scores that understand her physiology; phase-aware training and sleep guidance.
- **Value prop:** cycle phase as a **covariate inside every baseline** — temperature, HRV, RHR, sleep, recovery all computed against phase-conditioned personal norms; cycle logging (period, symptoms, flow) or passive inference from temperature where quality permits; complete opt-out with data locality guarantees.
- **Danger:** false "sickness" flags in luteal phase; privacy anxiety around reproductive data (Section 28.7: cycle data gets the strictest storage class, on-device by default, excluded from cloud AI by default).
- **Depth:** Balanced.
- **Key features:** phase-conditioned normal bands (visually: the band itself shifts with phase), phase overlay toggle on any chart, cycle module fully hideable (Bevel's visibility switches, adopted).

### 3.11 Salim — the chronic symptom tracker
- **Profile:** 52, managing IBS and migraines with his GP; keeps a paper diary.
- **Motivation:** find patterns ("do migraines follow poor sleep? certain foods?") and produce a clean record for appointments.
- **Value prop:** first-class symptom logging (custom symptoms, severity scales, duration, triggers, body location), symptom↔metric correlation views with honest statistics ("7 of your 9 migraines followed nights under 6h sleep — association, not cause"), physician-visit PDF report.
- **Danger:** vocabulary chaos (five spellings of the same symptom — solved by canonical symptom dictionary + user synonyms, Section 21.6), overclaiming causation.
- **Depth:** Balanced (logging-forward preset).
- **Key features:** 2-tap symptom re-log of recents, recurrence detection, exportable symptom journal, attachment support (photo of a rash, wellness-framed).

### 3.12 Huda — the medication-heavy user
- **Profile:** 60, six daily medications on three schedules; caregiver daughter helps set up.
- **Motivation:** adherence without shame; seeing whether regimen changes coincide with how she feels.
- **Value prop:** medication repository (name, dose, schedule, prn vs scheduled), gentle adherence tracking (skip-with-reason, not red X's), "regimen change" markers on all charts (a med change becomes a vertical annotation line on any metric chart), interaction-free zone: BADAN never advises on dosing, only records and reflects.
- **Danger:** anything resembling medical advice; alarm fatigue; tiny tap targets.
- **Depth:** Casual (large-type preset).
- **Key features:** HealthKit medications sync (iOS 16+ medications type), reminder system with quiet hours, caregiver-assisted setup flow (device-local, no account sharing in v1), physician report.

### 3.13 Karim — the recovery-focused user
- **Profile:** 35, returning from ACL surgery; cleared for progressive loading.
- **Motivation:** not overdoing it; objective reassurance during a psychologically fragile period.
- **Value prop:** Injured status (Bevel's Activity Status, adopted) with a **recovery-context mode**: strain targets suppressed or re-based, gentle progress framing ("4th consecutive week of rising step counts"), symptom + pain logging tied to activity.
- **Danger:** the app cheering "Overtraining risk!" or "Detraining!" at someone medically required to rest (Bevel's Cardio Load would happily show "Detraining" to a post-surgical user — a wording failure BADAN's status-aware phrasing engine prevents, Section 23.9).
- **Depth:** Casual.
- **Key features:** status-conditioned phrasing, milestone journaling, clinician-shareable progress PDF (future, Section 45).

### 3.14 Noor — the sleep optimization user
- **Profile:** 28, shift-work-adjacent job; poor sleep is her #1 complaint.
- **Motivation:** understand and fix sleep; loves Bevel-style depth (she was drawn by exactly the metrics in the recording: sleep continuity, HR dip, sleep debt/bank, chronotype consistency).
- **Value prop:** the full sleep suite: stages, latency, continuity/fragmentation, HR dip, respiratory rate overnight, temperature deviation, Sleep Bank (debt/surplus ledger — Bevel's "Sleep Bank 2h24m Surplus" adopted with clearer semantics), wind-down and target-bedtime planner (Bevel's 24-hour clock dial adopted), weekly sleep-distribution strip, social-jetlag metric (beyond Bevel).
- **Danger:** orthosomnia — anxiety caused by sleep tracking itself. Mitigation: a "gentle sleep mode" that hides nightly scores and only reports weekly trends (a deliberate anti-Bevel option).
- **Depth:** Balanced (sleep preset).
- **Key features:** bedtime consistency coaching, environmental correlates (late meals, alcohol, caffeine logs vs sleep), smart alarm via watch (future).

### 3.15 Diego — the nutrition/macro-focused user
- **Profile:** 30, recomposition goal; weighs food; MyFitnessPal refugee (ad fatigue, database distrust).
- **Motivation:** accurate macros with minimal friction; nutrition↔training↔recovery links.
- **Value prop:** four logging pathways at parity with Bevel (photo AI, natural-language description, barcode, database search) plus verified regional databases, recipe builder, macro/micro targets with g/% views (Bevel's toggle, adopted), Net Energy view (consumed vs burned diverging bar, adopted), food-quality scoring with visible rubric (vs Bevel's opaque score), and honest portion-uncertainty flags on AI estimates.
- **Danger:** database garbage; AI hallucinating portions; score opacity.
- **Depth:** Power (nutrition preset).
- **Key features:** food logging in ≤10 seconds for repeats (favorites/recents/meals), micronutrient dot-matrix (Bevel's visual, adopted), water/caffeine/alcohol tracking with HealthKit/Health Connect write-back toggles (exactly mirroring Bevel's write-back switches: macros, micros, water, caffeine, alcohol).

### 3.16 Aziza — the CGM-aware lifestyle tracker
- **Profile:** 44, prediabetic per her doctor, wears a Libre/Lingo-class sensor during focus periods; explicitly *not* seeking treatment advice from an app.
- **Motivation:** see how foods, walks, sleep, and stress move her glucose; build intuition.
- **Value prop:** CGM ingestion (Dexcom/Libre/Lingo via HealthKit/Health Connect writes or vendor APIs per Section 13), glucose day-strip with meal/activity/sleep overlays, Bevel-parity derived metrics (Morning Fasting Glucose, Average Glucose, Glucose Variability, Glucose Impact per meal after calibration threshold), post-meal response cards ("2h response to this lunch: +2.1 mmol/L, back to baseline in 95m") — always wellness-framed, never dosing or diagnosis.
- **Danger:** anything that reads as medical management; unit confusion (mmol/L vs mg/dL must follow locale + user override, both rendered correctly everywhere incl. exports).
- **Depth:** Balanced.
- **Key features:** meal-response library, threshold lines user-configurable (Bevel shows 3.9/7.8 mmol/L defaults with a gear — adopted), sensor-gap honesty (compression lows flagged as artifacts, Section 37).

### 3.17 Sven — the privacy-maximalist user
- **Profile:** 39, security engineer; refuses cloud health apps; found BADAN through its local-first marketing.
- **Motivation:** full functionality with zero cloud dependency.
- **Value prop:** Local-Only Mode (Section 28.5): no account required, all processing on-device, on-device AI tier only, encrypted local backups + user-controlled file export, complete network-traffic transparency page ("what BADAN sends and when" — with local-only mode: nothing).
- **Danger:** dark patterns pushing him to create an account; silent telemetry.
- **Depth:** Power.
- **Key features:** account-optional architecture (Section 31.2), analytics opt-out that is real (Section 36.2), open export formats, reproducible score documentation.

### 3.18 Priya — the export-focused data nerd
- **Profile:** 36, epidemiology PhD; wants her n-of-1 in Jupyter.
- **Motivation:** clean, documented, machine-readable data; stable schemas.
- **Value prop:** schema-versioned JSON/CSV/Parquet/SQLite exports with a published data dictionary, per-metric/per-range/per-source filtered exports, scheduled recurring exports (e.g., monthly ZIP to Files/Drive), personal REST API with token scopes (read-only), derived-vs-raw clearly separated with algorithm version stamps.
- **Danger:** schema churn without versioning; exports that silently drop provenance.
- **Depth:** Power.
- **Key features:** Export Center (Section 20), data dictionary in-app and on web, changelog of schema versions.

### 3.19 The Haddad family — caregiver / partner-sharing scenario
- **Profile:** adult son (48) loosely supporting his father (74) who uses BADAN with medications and BP cuff readings.
- **Motivation:** peace of mind without surveillance.
- **Value prop (future-phase, consent-first):** *outbound sharing only* — the account owner explicitly shares selected summaries (e.g., weekly digest, medication adherence overview) with a named recipient; recipient sees only what was shared; sharing is revocable and visibly logged. No silent monitoring, no default-on location, no covert modes — this is a sharing feature the *data owner* drives.
- **Danger:** anything resembling surveillance; elder-consent ambiguity. Ship late (Phase 4), design with a consent researcher.
- **Depth:** Casual for the father; recipient view is read-only summaries.

### 3.20 Kenji — the international / multilingual user
- **Profile:** 33, Japanese national in Dubai; phone in Japanese, work in English; local foods in three cuisines.
- **Motivation:** an app that doesn't assume an American diet, US units, or English.
- **Value prop:** launch languages EN + AR (full RTL) with JA/ES/FR/DE/UR/HI in the first year; unit system per-metric override; regional food databases (GCC, Levantine, South Asian, East Asian at minimum via localized DB partners); date formats, week-start, and number formatting honored everywhere *including charts and exports*.
- **Danger:** half-localized UI (translated labels, English AI insights); RTL-broken charts.
- **Depth:** any.
- **Key features:** AI narrative generation in UI language, localized metric education content, RTL-mirrored navigation and charts (time axes remain LTR per convention, with mirrored chrome — Section 25.9).

### 3.21 Archetype coverage matrix

| Archetype | Primary pillar(s) | Log burden tolerated | Export need | AI appetite | Default preset |
|---|---|---|---|---|---|
| Rania (passive) | Sleep, Recovery | None | None | 1 sentence/day | Casual |
| Omar (light wellness) | Activity, Sleep | Low | None | Weekly digest | Casual+ |
| Ayesha (Watch-heavy) | Fitness, Recovery | Low | Low | Contextual | Balanced |
| Tariq (Android) | All | Medium | Medium | Contextual | Balanced |
| Dmitri (QS) | All | High | Critical | Skeptical/on-demand | Power |
| Lena (hybrid athlete) | Strain, Strength, Recovery | Medium | Medium | Training-focused | Power-fitness |
| Yusuf (strength) | Strength | High (workouts) | Low | Program feedback | Balanced-strength |
| Ingrid (endurance) | Cardio load, Sleep | Medium | Medium | Plan-aware | Power |
| Faisal (longevity) | Biology, Recovery | Medium | High | Deep-dive | Power-longevity |
| Mariam (cycle-aware) | Cycle, Recovery, Sleep | Low–Medium | Low | Phase-aware | Balanced |
| Salim (symptoms) | Symptoms, Sleep | Medium (symptoms) | High (reports) | Pattern-surfacing | Balanced-logging |
| Huda (medications) | Medications, Vitals | Medium (meds) | Medium (reports) | Minimal | Casual-large-type |
| Karim (recovery) | Activity, Symptoms | Low | Medium | Gentle | Casual |
| Noor (sleep) | Sleep | Low | Low | Sleep-focused | Balanced-sleep |
| Diego (nutrition) | Nutrition, Body comp | High (food) | Medium | Meal feedback | Power-nutrition |
| Aziza (CGM) | Glucose, Nutrition | Medium | Medium | Response insights | Balanced |
| Sven (privacy) | All | Medium | High | On-device only | Power-local |
| Priya (export) | All | Medium | Critical | Analytical | Power |
| Haddad family | Meds, Vitals | Low | Medium (shared) | Minimal | Casual / read-only share |
| Kenji (i18n) | Nutrition, All | Medium | Low | Localized | Any |

Design rule derived from the matrix: **the intersection of all archetypes is the daily glance + honest narrative**; the union is the full feature universe of Section 9. Everything between is progressive disclosure.

---
---

## 4. Jobs to be done

Formal JTBD statements, grouped, each with acceptance-of-done from the user's perspective, the mechanism in BADAN, and the depth split (casual/power rendering).

### 4.1 Awareness jobs

**J1. "When I wake up, I want to know how my body is doing, so I can shape my day without thinking hard."**
- Done when: <10 seconds from open (or widget glance) to an answer they trust.
- Mechanism: Today screen hero (three-score glance + One True Sentence); morning widget; watch complication.
- Casual: sentence + rings. Power: same, plus tappable input attribution (which inputs moved each score).

**J2. "When something feels off, I want to check whether my data agrees, so I can decide whether to rest, push, or see someone."**
- Done when: user can see today's vitals vs *their* normal bands in one screen, with deviations flagged calmly.
- Mechanism: Health Monitor grid (Bevel's RR/RHR/HRV/SpO₂/Temp/Sleep vertical-range pills — adopted) + "unusual today" digest; wording guardrails route "see someone" phrasing to neutral "consider consulting a professional if this persists" only under strict rules (Section 23.9).

**J3. "When my score surprises me, I want to know exactly why, so I keep trusting the system."**
- Done when: every score answers "why" in ≤2 taps with named inputs and their contributions.
- Mechanism: universal Score Anatomy sheet (Section 22.5). This is the single most important anti-churn job per the report's testimonial analysis.

### 4.2 Optimization jobs

**J4. "When I train, I want to know if my load is productive, so I progress without burning out."** → Cardio Load (acute/chronic + statuses), Target Strain band, muscular load channel; casual sees a status word, power sees the ACWR-style curve and breakdown tables (Bevel's Below/Within/Above days table — adopted).

**J5. "When I change a habit (earlier dinner, no alcohol, new bedtime), I want evidence it's working, so I keep or drop it."** → Experiments feature (Section 22.8): tag a date range as an experiment, get honest before/after comparison with confidence caveats. Bevel has nothing like this; the report's "counterfactual suggestions" ambition lands here.

**J6. "When I plan sleep, I want a realistic target for tonight, so I can pay down debt."** → Sleep Bank ledger + wind-down/target-bedtime clock (Bevel-parity) + "tonight's need" figure.

**J7. "When I eat, I want to know what this meal does to *me*, so I choose better next time."** → meal response cards (glucose if CGM present; else next-morning recovery/sleep correlates with honest weak-signal framing).

### 4.3 Record-keeping jobs

**J8. "When I experience symptoms, I want to capture them in seconds, so my record is complete when I need it."** → 2-tap recents, severity slider, voice log via assistant/Shortcuts.

**J9. "When I take medications, I want a truthful adherence record without being nagged, so I can review it with my doctor."** → med schedules, skip-with-reason, quiet reminders, physician PDF.

**J10. "When I get lab results, I want them in the same place as everything else, so trends across years are visible."** → Biology pillar; manual entry, PDF import (on-device parsing first), reference-range visualization, biomarker catalog matching Bevel's observed 390+ registry.

**J11. "When I see a doctor, I want a clean summary of relevant history, so the visit is productive."** → Report Composer: date-range + topic-filtered narrative PDF (Section 20.6).

### 4.4 Ownership jobs

**J12. "When I invest years of data, I want certainty I can take it all with me, so I never feel locked in."** → Export Center, personal API, scheduled exports, account-deletion with verifiable data package first.

**J13. "When I switch phone platforms, I want my history intact, so the repository outlives my hardware."** → cross-platform sync (Section 34), import connectors for the other platform's stores.

**J14. "When I grant access to my health data, I want to see and revoke exactly what's used, so I stay in control."** → Permission dashboard with per-type status, last-read timestamps, and in-app revocation guidance (Section 28.3).

### 4.5 Understanding jobs

**J15. "When I see a metric I don't know, I want a plain explanation *right there*, so I learn without leaving."** → universal (i) definition footers (Bevel-parity: e.g., its wrist-temperature footer explaining 5-second sleep sampling and 1–2 °C offset vs core — that specificity level is the bar), glossary, "explain this chart" AI action.

**J16. "When I've used the app for a year, I want to see the story of my year, so the accumulation feels meaningful."** → Year in Body annual report (Section 22.9); monthly retrospectives.

**J17. "When two metrics might be related, I want the app to check honestly, so I don't invent patterns."** → Correlation Lab with multiple-comparison honesty, minimum-n gating, and "association ≠ cause" framing baked into every output (Section 22.7).

### 4.6 Job → feature traceability

Every feature in Section 9's catalog carries a J-reference; any feature that cannot cite a job is cut. (This traceability discipline is itself an anti-pattern guard: Bevel's paywall lists 13 feature families; the report's community analysis shows users experience them as fragmented. Jobs are the connective logic features must snap into.)

---
---

## 5. Product positioning

### 5.1 Category definition

BADAN positions in the category the report names as most underserved: **the device-agnostic health interpretation layer** — "the platform wins not by capturing device data first, but by being where the user wants to understand all their data." BADAN sharpens this with the ownership axis: *interpretation layer + personal repository*.

**Positioning statement:**
> For people who collect health data across any device or app, BADAN is the private health repository and interpreter that turns every signal into honest, personal understanding — unlike hardware-locked platforms (WHOOP, Oura), single-ecosystem apps (Bevel: Apple-first, iOS-only), and dashboards that show data without meaning (platform health apps), BADAN works with everything, explains everything, and lets you keep everything.

### 5.2 The four positioning pillars

1. **Yours.** The repository is free forever; export is total; deletion is real; local-only mode exists. (Attacks: WHOOP/Oura/Bevel all score ❌ on export in the report's differentiation matrix.)
2. **Everything.** All practical devices, both mobile platforms, wearable + manual + lab + subjective data in one model. (Attacks: hardware lock-in and iOS-onlyness.)
3. **Honest.** Explainable scores, confidence levels, calibration transparency, context-aware phrasing. (Attacks: the #1 churn driver — "algorithm disagrees with how I feel.")
4. **Human.** One warm sentence a day if that's all you want; your language, your units, your culture's food. (Attacks: sterile-clinical UX and Anglo-centric assumptions.)

### 5.3 Naming, brand, and voice

- **BADAN بدن** — short, pronounceable in English and Arabic, means "body." Render the Arabic form as a first-class brand element (logo lockup supports both scripts; app name localized).
- Voice: second-person, concrete, calm. Never "Warning!" — instead "Worth a look." Never "You failed your goal" — instead "Short of your target; here's what got in the way."
- Tagline candidates: "Know your body." / "اعرف بدنك" ; "Every signal. One story." ; "Your body's ledger."

### 5.4 Competitive frame (summary; full benchmark in Section 6)

| Axis | WHOOP | Oura | Bevel | Apple Health / Google | **BADAN target** |
|---|---|---|---|---|---|
| Hardware required | Yes | Yes | No (BYO wearable) | No | No |
| Platforms | iOS/Android | iOS/Android | **iOS only** | One each | iOS + Android parity |
| Interpretation depth | High (recovery) | High (sleep) | High (broadest) | Low | ≥ Bevel breadth, higher explainability |
| Nutrition | ❌ | ❌ | ✅ strong | Partial | ✅ + regional DBs |
| Labs/records | ❌ | Partial | ✅ (3.0) | Partial (US) | ✅ manual+PDF now, FHIR-aware later |
| Meds/symptoms/conditions | ❌ | ❌ | Partial (Journal/habits) | Partial | ✅ first-class |
| Cycle as covariate | ❌ (documented failures) | ✅ | Module | Partial | ✅ inside all baselines |
| Export/API | ❌ | ❌ | ❌ | Raw only | ✅ flagship |
| Community | ✅ | Partial | ❌ | ❌ | Phase 3, opt-in |
| Free tier durability | ❌ ($30/mo) | ❌ (sub) | Limited (core scores free-ish, intelligence paid) | Free | Repository free forever |
| On-device AI mode | ❌ | ❌ | ❌ | N/A | ✅ tiered |
| RTL/Arabic | ❌ | ❌ | ❌ | OS-level only | ✅ launch |

### 5.5 Go-to-market wedges (ranked)

1. **The export wedge:** "the health app you can leave" paradoxically retains best; target r/QuantifiedSelf, r/Biohackers, spreadsheet-keepers (Dmitri/Priya archetypes) as vocal early adopters.
2. **The Android wedge:** Bevel's entire feature class is absent on Android; Health Connect users (Tariq) have no Bevel-equivalent. First-mover among "interpretation layer" apps on Android.
3. **The regional wedge:** Arabic-first market (GCC + broader MENA): zero localized competitors at this depth; App Store featuring potential; the brand itself signals it.
4. **The trust wedge:** cycle-aware scoring + privacy-maximalist mode as public commitments, each addressing a documented, quotable competitor failure.

### 5.6 What BADAN does *not* compete on

- Sensor accuracy (we have no sensor; we are honest brokers of others' accuracy, including surfacing their disagreement).
- Medical care delivery (no diagnosis, no treatment, no telehealth in scope).
- Social-fitness gamification depth (Strava's job; we interoperate rather than replicate).

---
---

## 6. Competitive benchmark against Bevel and adjacent apps

This section converts the screen recording and report into a precise benchmark: what Bevel demonstrably ships (observed), what it implies, where it excels, where it simplifies, and where BADAN matches/exceeds/diverges. This is the coverage floor referenced throughout the document.

### 6.1 Bevel's observed structure (from the recording)

**Top-level shell.** Three tabs in a floating pill dock — **Home, Fitness, Biology** — plus a persistent circular **"+" FAB** (global logging). The dock collapses to a single contextual circle + FAB on scroll. Settings is a modal (X-close) reached from the avatar, not a tab.

**Home tab (observed order):** date-pager header (calendar picker with per-day score rings; share icon; avatar) → Activity Status pill (Active/Sick/Injured/On A Break, with retroactive apply) + weather/location pill → triple-ring hero (Strain % amber, Recovery % lime, Sleep % indigo) → COACHING sentence card → rotating promo card slot → Stress card (Highest/Lowest/Average + semicircular gauge "30 Low") → Energy bar (body-battery style, 46%) → Nutrition teaser (Today's foods, locked score ring, 0g macros, blood glucose row) → **Health Monitor** grid (RR/RHR/HRV/SpO₂/Temp/Sleep tiles with vertical range-pill gauges and Normal/Higher/Lower chips) → Timeline (typed events, e.g., "Primary sleep… score 67") → **Edit Home** + **View All Categories** buttons.

**Pillar detail pages (Strain/Recovery/Sleep):** scenic hero art + ring → two key stat cards (e.g., Resting HRV 25.4 ms / Resting HR 83.5 bpm with baseline-deviation badges) → coaching paragraph → Timeline events → **Trends list** (each metric: value, status chip vs personal normal band, band-chart sparkline, chevron drill-in). Sleep adds: wind-down/target-bedtime 24-hour clock dial, Sleep Bank (surplus/deficit ledger), weekly sleep-distribution heat strip, sleep/wake time normality, Time to Fall Asleep.

**Universal metric detail sheet (the strongest single pattern observed):** big value + date → status vs *personal* normal range (e.g., "Above normal, 74.0–82.2 bpm") → horizontally scrollable metric-switcher chips → band chart with dotted personal average → period control (30D/3M/6M/1Y + calendar + paging chevrons) → **Trends Analysis table** (3/7/14/30/90-day rolling deltas with mini sparklines and directional coloring; "based on 7-day rolling averages") → Resources (education cards) → plain-language definition footer with genuinely specific physiology notes.

**Fitness tab:** "Last 30 days" header → dual mini-month activity heatmap calendar (1/2/3+ activity legend) → Activity Summary (current-vs-prior comparison chart, activity-type filter chips, metric picker) → Strain Performance (deviation-% vs target, ±10% band, tri-color line, Below/Within/Above breakdown table, 30D→1Y) → Cardio section: Cardio Load (acute/chronic envelope, statuses Calibrating/Detraining/Maintaining/Peaking), Cardio Focus (Low Aerobic/High Aerobic/Anaerobic stacked bars + breakdown), HRR → Strength section: muscle-group radar with metric switcher (Total Volume/Workout Frequency/Muscular Load; Chest/Arms/Back/Core/Legs/Shoulders), Strength Progression, Workout Templates ("Strength Builder") → per-tab **edit-layout mode** (remove badges, drag grips, Add card, Reset to default).

**Biology tab:** starfield aesthetic → Biological Age semicircular tick dial (value Pro-locked via particle scramble; "18+" eligibility; chronological-age anchor on dial) → Other Biomarkers curated list (Weight, HRV Baselines, RHR Baselines, Body Fat %, Lean Body Mass, VO₂ Max — with status words like Poor/High/Decreasing and mini trend thumbnails; "Edit" curation) → **full Biomarkers registry**: alphabetical, ~390+ entries spanning wearable-derived (VO₂ Max, RHR baselines) and blood-panel biomarkers (ApoB, AST, BUN, cortisol, DHEA-S, eGFR, HbA1c, hs-CRP, homocysteine, IgA, insulin, IGF-1, magnesium, MCH/MCHC/MCV/MPV, mercury, RDW, SHBG, sodium, free testosterone, uric acid, VLDL, B12, vitamin D, WBC…), each with status • value • sparkline or "No data" skeleton, A–Z index rail, bottom search.

**Nutrition detail:** "Log 776 kcal to unlock today's Nutrition score" gate → My Foods (favorites/recipes/foods) → Goals (calorie bar + fat/carb/protein rings) → Nutritional Details (g/% toggle, dot-matrix macros) → Net Energy (diverging burned-vs-consumed bar, −2,342 kcal "Deficit") → Food Quality Contributors → Blood glucose chart (3.9/7.8 mmol/L threshold lines, gear for settings) → Timeline (+ add) → Trends (Nutrition Score, Macro Balance).

**All Categories:** searchable, pillar-grouped registry of every metric card (incl. Morning Fasting Glucose, Average Glucose, Glucose Variability) — the full-catalog browser behind the curated Home.

**Settings tree (observed):** Bevel Pro / Manage Subscription (Free-vs-Pro entitlement checklist) · referral + Rewards (30-day guest pass) · Account · Appearance (three app-icon families incl. seasonal specials) · Notifications (Daily Summary, Activity completed, Target bedtime reminder, Target strain reached, Food processed, Glucose processed) · **Customization hub** (Goals; Units; Heart Rate Zones editor — Max-HR method, 6 zones with %/bpm; **Calculations** — HRV method Bevel-RMSSD-from-raw-beats vs Apple Health field, HRV/RHR/SpO₂/RR sampling window "Entire sleep," temperature method Wrist, calories display, merge-manual-sleep toggle; Data Loading Window "sync >1 year"; Social Sharing; module visibility switches with live preview mockups for Nutrition/Cycle/Strength Builder/Journal/Biology, each warning "hiding X disables all related features and UI") · Shortcuts (Apple Shortcuts: "Sleep alarm + sleep focus") · Language · **Data** (Data Sources: per-metric source counts → device-level lists with dates → hide sources; Resync Health; Restore from backend; Manage CGM; iCloud Sync status/last-sync) · Resources (What's new; Getting started 4-page story incl. a Recovery explainer teaching interpretation + calculation; Knowledge base → help site) · Request a feature / Report a bug / Rate.

**Monetization observed:** $99.99/yr (framed "Save 44%," $8.33/mo) vs $14.99/mo; 7-day trial with "No payment due now" and a trial-end-reminder promise screen; Pro gates: Bevel Intelligence (check-ins, meal planning, training plans, custom analysis), Biological Age, Health Records import, Nutrition score; rotating in-feed promo cards; referral guest passes.

**Bevel Intelligence V2 (observed via What's-New):** persistent-memory coach; proactive check-ins; web search + chart generation + "custom data analysis" on user data; photo/describe food logging; training plans; "Ask Bevel anything" composer.

### 6.2 What Bevel does well (adopt the principle)

1. **The universal metric-detail template** — one learnable grammar for every metric. BADAN adopts and extends it to labs, meds, symptoms (Section 16.6).
2. **Personal normal bands everywhere** — status is always relative to *you* ("Above normal 74.0–82.2 bpm"), not population cutoffs. This is the correct default; BADAN adds cohort context only as an explicit optional overlay (Section 22.6).
3. **Rolling-delta Trends Analysis table** (3/7/14/30/90d) — compact longitudinal literacy. Adopt verbatim as a pattern.
4. **Calculation-method transparency** — user-selectable HRV/RHR derivation with plain-language explainers. Rare, excellent, adopt and go further (per-metric algorithm pages, Section 27.5).
5. **Context statuses** (Active/Sick/Injured/On A Break) with retroactive application propagated to trends — adopt, extend taxonomy, and make it feed scoring covariates (Section 10.13).
6. **Module visibility switches with live previews** — users can turn whole pillars off (Cycle disabled in the recording). Perfect chaos-control instrument; adopt as the backbone of BADAN's customization (Section 19.2).
7. **Data Sources management** — per-metric source inventories, hide-source, resync, restore. Adopt; extend to per-sample lineage and priority ordering UI.
8. **Empty states that teach** ("No workouts — Start using Strength Builder by creating a workout template") and skeletons that show *shape* of future value.
9. **Scenic emotional art** on pillar pages; **app-icon personalization**; story-style Getting Started explaining both *interpretation* and *calculation* of each pillar.
10. **Education woven in-line:** Resources cards + definition footers of genuine specificity (temperature sampling cadence, wrist-vs-core offset).

### 6.3 What Bevel simplifies or omits (BADAN's openings)

| Observation | Implication | BADAN response |
|---|---|---|
| iOS only; Apple Watch primary; Garmin + CGMs as the only direct integrations | Android market abandoned; multi-device users partially served | Dual-platform parity; broker + direct integrations (Section 13) |
| No export anywhere (Social Sharing ≠ data export) | Power users' top unmet demand (report: Medium-High frequency) | Export Center as flagship free feature |
| No medications, limited symptoms (Journal/habits module; "Track Habits & Symptoms" is a paywall bullet) | Chronic/med-heavy users unserved | Meds/symptoms/conditions as first-class pillar (Section 21) |
| Nutrition score gated by kcal-logging threshold and Pro | Passive users see locks and zeros | Passive-value nutrition surface; scores unlock by data presence, not payment for basics |
| Bio Age paywalled via obfuscation on day one, 18+ | Teasing without value; trust cost | Free coarse Bio-Age band with explanation; paid = full model + decomposition |
| New-user experience dominated by "No data / Calibrating" | Cold-start trust gap (report: calibration complaints) | Historical backfill on connect (import up to years of history; Sahha-style 30-day instant baseline; Section 11.7) |
| Single Max-HR zone method | Athletes want LTHR/HRR%/per-sport zones | Multi-method zone editor (Section 19.6) |
| Community absent | Report: Bevel's biggest gap vs WHOOP | Phase-3 opt-in circles (Section 38.6) |
| One language, LTR only | MENA + global users unserved | i18n/RTL at launch |
| Fragmentation critique (report) despite good pieces | Pillars don't reference each other much | Connective-tissue systems: unified Timeline, cross-pillar insight cards, Correlation Lab (Section 8.5) |
| AI is cloud-bound | Privacy-sensitive users excluded | Tiered AI with on-device mode (Section 23.4) |

### 6.4 Adjacent benchmarks (report-sourced)

- **WHOOP:** best-in-class cohesive narrative + community/trophies; worst-in-class pricing resentment and female-physiology failures. Lesson: cohesion and community matter; hardware-tied subscriptions and unexplained scores burn trust.
- **Oura:** best sleep-staging credibility (79% PSG agreement) and calm brand; ring-locked, limited export. Lesson: algorithmic credibility can be a brand pillar — BADAN earns it via transparency rather than proprietary sensors.
- **Gentler Streak / Athlytic / Training Today (Apple-ecosystem interpreters):** prove demand for HealthKit interpretation; all iOS-only, none repository-grade. Lesson: the interpretation-layer category is validated; nobody has claimed the cross-platform repository position.
- **Longevity One / Rejuve:** bio-age depth (PhenoAge-style blood models; NHANES-trained hallmarks) and local-compute privacy marketing. Lesson: bio-age needs scientific framing + explainability; privacy claims are retention drivers when verifiable.
- **MyFitnessPal (nutrition incumbent):** database breadth with quality distrust + ad fatigue. Lesson: verified-entry quality signaling beats raw entry count.
- **Apple Health / Google's stack:** the free default repositories — but raw, uninterpreted, single-platform each. They are BADAN's *substrate and rival simultaneously*; BADAN must always answer "why not just Apple Health?" with interpretation, cross-platform history, logging depth, and export coherence.

### 6.5 Benchmark verdict

Bevel is the correct benchmark for **breadth of interpreted metrics** and **quality of progressive disclosure**; nobody else combines four pillars + biomarkers + AI at its level. But it is structurally beatable on: platform reach, ownership/export, meds/symptoms, cold-start honesty, cycle-as-covariate depth, community, localization, and privacy architecture. BADAN's mandate: **match the template quality, beat the structure.**

---
---

## 7. Principles for surpassing Bevel

Twelve operating principles, each phrased as "Bevel does X → BADAN does X′," forming the delta-spec that recurs through Sections 8–45.

**P1. Match the metric floor before adding novelty.** Every metric visible in the recording (Section 10 enumerates all of them into the ontology) must exist in BADAN's model by end of Phase 2. New metric classes (social jetlag, mobility, experiments) come after the floor, not instead of it.

**P2. Interpret everything, gate only synthesis.** Bevel gates interpretation (Intelligence, Bio Age, Nutrition Score). BADAN's free tier interprets every individual metric (status vs personal band + definition + trend); the paid tier gates *cross-metric synthesis* (deep AI analysis, long-horizon reports, experiments engine). A free user is never left with a naked number.

**P3. Every score is a glass box.** Score Anatomy sheet: inputs, weights (qualitative), data quality, algorithm version, "what would move this." Bevel explains *concepts* well (Getting Started, footers) but not *today's specific number* beyond one coaching sentence.

**P4. The cold start must feel warm.** On first connect: immediately backfill historical data (HealthKit/Health Connect allow historical reads; Data-Loading-Window equivalent defaults to *on*), compute provisional baselines from history rather than waiting weeks, and label them "provisional" honestly. Where Bevel shows "Calibrating 100%," BADAN shows a provisional value + confidence + countdown.

**P5. Presence-based UI, not placeholder-based UI.** Modules with no possible data self-collapse into a single "what you could add" browser entry instead of rows of 0g and "No data." (Bevel keeps six skeleton surfaces alive for a user with no CGM, no food logs, no workouts.)

**P6. Two platforms, one soul.** No feature ships iOS-first by more than one release train. Platform-specific delights (Live Activities, Shortcuts / Wear tiles, app widgets) are allowed to differ; data capability may not.

**P7. Context is a covariate, not a caption.** Statuses (sick/travel/cycle-phase/meds-change/fasting) enter baseline computation and phrasing selection, not just chart annotations. This is the systematic fix for the luteal-phase false-alarm class of failure.

**P8. Logging is always ≤3 interactions for the repeat case.** Food re-log, symptom re-log, med taken, workout from template: two to three taps or one voice/Shortcut invocation. Novel entries may take longer; repeats may not.

**P9. Export is a feature, not a settings row.** A designed Export Center with previews, templates, scheduling — placed in the main navigation's tools area, marketed on the store page.

**P10. Depth reveals; it never greets.** Default surfaces match Bevel's density ceiling (Home ≈ 6–8 modules); every additional layer is one intentional gesture away (long-press, "More," Power Mode toggle). Power Mode is a persistent, per-user rendering preference — not a separate app personality.

**P11. Localize the whole experience.** Language, script direction, units, food culture, week start, quiet hours, examples in education content. "Localized" means the AI narrative too.

**P12. Trust artifacts ship with features.** Every launch includes its explanation page, its data-dictionary entries, its privacy note, and its failure-mode behavior (what users see when data is missing/conflicting). Definition of Done includes trust collateral (Section 40.5).

---
---

## 8. Experience architecture

The macro-structure of the experience: the layers a user moves through, and the connective systems that prevent Bevel-style fragmentation.

### 8.1 The five experience layers

```
L0  Ambient      — widgets, complications, notifications, watch glances
L1  Today        — one screen: how am I doing now (the daily contract)
L2  Pillars      — Sleep / Recovery / Strain / Fitness / Nutrition / Biology / Cycle / Journal-Logs
L3  Metrics      — universal metric detail (any measurable thing, one template)
L4  Workbench    — raw data explorer, correlations, experiments, reports, export, AI deep analysis
```

- Casual users live in L0–L1, visit L2 occasionally, may never see L4.
- Power users treat L4 as home base; L0–L1 remain their glance layer too.
- Rule: **every element at layer N links coherently to N+1** (tap the ring → pillar; tap a pillar metric → metric detail; every metric detail offers "open in Workbench"). No dead ends; no layer-skipping surprises.

### 8.2 The daily contract (L1)

The Today screen makes a promise: *in under ten seconds you'll know (1) how you slept, (2) how ready you are, (3) whether anything is unusual, and (4) one thing worth doing.* Everything else on Today is optional modules the user (or their preset) curates — mirroring Bevel's Edit Home, but with presence-based defaults (P5) and preset packs (Section 19.3).

### 8.3 Pillar pages (L2) — the Bevel-plus template

Each pillar page follows one grammar (adopted from Bevel's observed pillar pages, extended):

1. Hero (score/state + emotional art + date context)
2. Key facts row (2–4 stat cards with baseline-deviation badges)
3. **Narrative** (the coaching paragraph — with "why" affordance, BADAN addition)
4. Context strip (active statuses affecting this pillar — BADAN addition)
5. Timeline slice (this pillar's events today)
6. Trends list (band-chart cards → metric details)
7. Related-pillar links ("Late meal logged 11:40 PM → see Nutrition" — BADAN addition, anti-fragmentation)
8. Learn (resources + definitions)

### 8.4 The universal metric detail (L3)

One template for *every* metric — biometric, nutritional, lab, medication adherence, symptom frequency, subjective mood:

value+date → status vs personal band → chart (type per metric family) → period controls (D/W/M/6M/Y/custom + calendar) → Trends Analysis rolling-delta table → **Anatomy** (inputs/quality/provenance — BADAN addition) → correlated events overlay toggle (meds changes, statuses, cycle phase — BADAN addition) → resources/definition → actions (log related entry, pin to Home, add to report, export this metric, ask AI).

This template is the single largest engineering-UX investment and the single largest coherence win: learn one screen, understand three hundred.

### 8.5 Connective tissue systems (anti-fragmentation)

1. **Unified Timeline.** One chronological stream of typed events across all pillars (sleep sessions, workouts, meals, meds taken, symptoms, notes, statuses, lab results, device syncs). Filterable; every event opens its native detail. Bevel has per-screen timelines; BADAN also has the master one.
2. **Cross-pillar insight cards.** Insights explicitly cite two+ pillars ("Recovery dipped on the 3 days after late meals this month") and deep-link both ways.
3. **The Narrative spine.** Daily/weekly/monthly narratives are generated from the same insight graph, so the story is consistent at all zoom levels (no "sleep tab says great, recovery tab says terrible" whiplash without the narrative addressing it).
4. **Global search** (Section 35) across metrics, foods, symptoms, meds, settings, education.
5. **Statuses and annotations render on every chart** — a med change or "Sick" span is visible wherever its effect might appear.

### 8.6 Mode architecture (the recurring tension, resolved structurally)

- **Depth dial, not mode fork:** a per-user rendering level (Casual / Balanced / Power) set by onboarding archetype, adjustable anytime in one switch, with per-surface overrides (e.g., Balanced overall but Power on Sleep).
- What the dial changes: module density defaults, chart annotation richness, table visibility, terminology verbosity (e.g., "Readiness" vs "HRV-weighted recovery composite"), notification analytical depth.
- What the dial never changes: the data collected, the truth of statements, navigation topology (so help content and muscle memory stay valid), or access to any screen (Power surfaces are reachable from Casual via explicit links — just not ambient).

### 8.7 First-run experience arc

Connect → backfill → provisional insight *within the first session* ("From your last 90 days of watch data: your typical sleep is 6h50m; RHR trending −2 bpm since spring") → archetype-light onboarding (3 questions max: goal, depth appetite, modules) → Today screen already alive. Full onboarding specification in Section 16.2; education ramp in Section 27.

### 8.8 iOS/Android divergence at the experience layer

Identical: layers, templates, pillar grammar, depth dial, Today contract. Divergent by design: L0 surfaces (WidgetKit/Live Activities/watchOS complications vs Glance widgets/Wear tiles), platform settings idioms (iOS grouped-list vs Material 3 preference panes), share-sheet vs intent flows, and Shortcuts vs app-actions automation. Both platforms' users must be able to describe the app identically to each other.

---
---

## 9. Complete feature universe

The full categorized inventory. Buckets: **M** = must-have now (Phase 1, the Bevel floor + BADAN identity), **S** = should-have soon (Phase 2), **A** = advanced (Phase 3), **V** = visionary (Phase 4+). Each feature lists JTBD references and key dependencies. Anti-features close the section.

### 9.1 Data foundation features

| Feature | Bucket | Jobs | Depends on | Notes |
|---|---|---|---|---|
| HealthKit read integration (full practical type set) | M | J1–J17 | — | Section 12 matrix |
| Health Connect read integration (parity set) | M | J1–J17 | — | Section 12 matrix |
| Historical backfill on connect (multi-year where permitted) | M | J16, P4 | ingestion pipeline | Bevel's "Data Loading Window" made default-on |
| Deduplication + de-overlap engine | M | J2, trust | canonical model | The report calls this "months to get right" — start day one |
| Source reconciliation & priority rules (auto + user override) | M | J14 | dedup | Bevel parity (hide sources) + priority UI |
| Per-sample provenance storage | M | J12, Law 5 | canonical model | Enables lineage UI + honest export |
| Manual entry for any metric | M | J8–J10 | metric registry | incl. BP, weight, glucose, temperature |
| Apple Health / Health Connect write-back (logs → platform stores) | M | interop | logging | Mirroring Bevel's granular write toggles |
| Background sync (observer queries / HC background reads) | M | J1 | platform work | Battery budget: Section 32.6 |
| Broker integration (Terra-class) for Garmin/Oura/Whoop/Fitbit/Polar… | S | J13 | backend | Decision framework Section 13.6 |
| Direct Garmin integration | S | Ingrid | backend | Bevel parity |
| CGM ingestion (Dexcom/Libre/Lingo paths) | S | Aziza | Section 13.5 | "Manage CGM" equivalent |
| Import connectors: Apple Health export ZIP, Google Takeout/Fit, Garmin/Oura/Fitbit/Whoop archives, generic CSV | S | J12, J13 | parsers | The reverse of export; nobody does this well |
| Lab result manual entry + biomarker registry (390+ catalog) | S | J10 | ontology §10.12 | Bevel floor |
| Lab PDF import with on-device extraction assist | A | J10 | OCR/LLM | Human-confirmed field mapping, never silent |
| FHIR-shaped record ingestion (regional availability) | V | J10 | compliance | Section 45 |
| Cloud sync (E2E-encrypted, multi-device) | S | J13 | Section 34 | Account optional |
| Local-only mode (no account, no cloud) | M | Sven | architecture | Cheap if designed first, impossible later |

### 9.2 Interpretation & scoring features

| Feature | Bucket | Jobs | Notes |
|---|---|---|---|
| Sleep score + full sleep metric suite | M | J1, J6 | Floor per §10.2 |
| Recovery/readiness score + inputs | M | J1, J2 | HRV-primary, context-covariate |
| Strain/exertion score + target band | M | J4 | Deviation-% model (Bevel parity) |
| Personal baselines & normal bands (all metrics) | M | J2, J3 | Rolling, phase-conditioned |
| Cardio Load (acute/chronic) + statuses | S | J4 | Calibrating/Detraining/Maintaining/Productive/Fatigued/Peaking/Overtraining — full 6-state Bevel model per report |
| Cardio Focus distribution | S | J4 | Low-aero/high-aero/anaerobic |
| Heart Rate Recovery (HRR) metric | S | J4 | Post-Zone-4 decay model per report |
| Strain Performance (deviation vs target) | S | J4 | Bevel parity incl. breakdown table |
| Stress score (HRV/HR-based daytime) + energy/"battery" | S | J2 | Bevel Home parity |
| Sleep Bank (debt/surplus ledger) | S | J6 | Bevel parity, clearer semantics |
| Nutrition scores (food quality + glucose impact when CGM) | S | J7 | Visible rubric (vs Bevel opacity) |
| Score Anatomy (glass-box decomposition) | M | J3 | BADAN signature |
| Confidence/quality indicators on every score | M | J3, Law 2 | Provisional-baseline honesty |
| Cycle-phase covariate engine | S | Mariam | Inside baselines, not beside |
| Biological Age (explainable, free coarse + paid full) | A | Faisal | With confidence interval + input weights |
| Muscular load / strength-channel recovery heuristic | A | Lena | Labeled heuristic explicitly |
| Experiments engine (before/after honest comparison) | A | J5 | §22.8 |
| Correlation Lab | A | J17 | Multiple-comparison honesty |
| Anomaly detection (calm, thresholded) | S | J2 | Notification-throttled |

### 9.3 Logging features (full detail in Section 21)

| Feature | Bucket | Jobs |
|---|---|---|
| Food: photo AI / description AI / barcode / search; favorites, recents, recipes, meals | S (search+barcode M) | J7 |
| Water, caffeine, alcohol quick-logs | M | J7 |
| Workouts: auto-import; manual add; strength builder (sets/reps/weight/RPE, templates, supersets) | M (builder S) | J4 |
| Symptoms: canonical dictionary + custom, severity, duration, triggers, body map | M | J8 |
| Medications & supplements: schedules, prn, adherence, skip-with-reason, regimen-change markers | M | J9 |
| Conditions/health issues repository (user-declared, links symptoms/meds/metrics) | S | J8–J11 |
| Mood/energy/subjective wellness quick check-in | M | J2 |
| Notes/journal with tags + attachments | S | J8 |
| Cycle logging (period, flow, symptoms) | S | Mariam |
| Body measurements (weight, waist, etc.) + smart-scale ingest | M | J10 |
| Voice/Shortcut/assistant logging | S | P8 |
| Retroactive logging & backdating with clear timestamps | M | J8 |

### 9.4 Presentation & analysis features

| Feature | Bucket | Notes |
|---|---|---|
| Today dashboard with editable modules + presets | M | Edit-Home parity + presence-based defaults |
| Universal metric detail template | M | §8.4 |
| Trends Analysis rolling-delta tables (3/7/14/30/90d) | M | Bevel parity |
| All-metrics browser with search (All Categories parity) | M | §16.7 |
| Unified Timeline (master, filterable) | M | Anti-fragmentation spine |
| Calendar with per-day state rings + month/year zoom | M | Bevel parity + year heat view |
| Chart annotation layers (statuses, meds, cycle, notes) | S | P7 |
| Comparison views (period vs period; metric vs metric overlay) | S | Power |
| Weekly/monthly digests; Year-in-Body annual report | S/A | §22.9 |
| Raw Data Explorer (sample-level table w/ lineage) | S | Power signature |
| Report Composer (topic/date-range narrative PDFs) | S | J11 |
| Widgets, complications, watch apps, Live Activities/tiles | M–S | §24 |

### 9.5 AI features (full detail Section 23)

| Feature | Bucket |
|---|---|
| Daily/weekly narrative generation (grounded, templated) | M |
| "Why am I seeing this" explanations on insights | M |
| Ask-anything chat over own data (grounded, citing data windows) | S |
| Proactive check-ins (user-configured cadence + AI-suggested) | S |
| AI food-logging (photo/description) with correction loop | S |
| Chart generation from natural-language questions | A |
| Training-plan suggestions (wellness-framed) | A |
| On-device inference tier (private mode) | A |
| Memory layer (preferences, goals, anomaly history) with user-visible/editable memory | S |
| Voice interaction / audio summaries | V |

### 9.6 Trust, privacy, ownership features

Consent center with per-type grants + last-read log (M) · Export Center CSV/JSON/PDF (M; Parquet/SQLite S; scheduled exports S; personal API A) · deletion with pre-deletion export (M) · privacy dashboard "what leaves the device" (M) · analytics opt-out (M) · algorithm changelog (S) · data dictionary (S) · E2E-encrypted sync (S) · local-only mode (M).

### 9.7 Growth & engagement features

Onboarding presets (M) · gentle streaks with freezes, opt-in (S) · milestones/quiet celebrations (S) · referral guest passes (S — Bevel parity) · public roadmap + in-app feature requests (S — report cites Bevel's community-roadmap loop as retention driver) · opt-in circles/challenges (A) · share-cards (image summaries, privacy-safe defaults) (S — Bevel's Social Sharing parity).

### 9.8 Hidden enabling features (invisible, load-bearing)

Metric registry service (single source of truth for every metric's identity/unit/family/formatting — enables the universal template) · unit conversion service · timezone/DST resolution engine (sleep-day attribution rules) · reference-range library (labs) with locale variants · food DB abstraction over multiple providers · notification decision engine (throttling/quiet hours/priority, §24.8) · insight deduplication memory (never repeat the same insight within N days) · schema migration framework (local DBs on two platforms + cloud) · feature-flag & kill-switch system · algorithm-version stamping on all derived values.

### 9.9 Feature interaction map (selected critical couplings)

- Statuses ⇄ scoring ⇄ phrasing engine (context changes numbers *and* words).
- Cycle engine ⇄ baselines ⇄ every band chart (bands must re-render per phase).
- Dedup ⇄ export (exports must state the dedup policy applied; raw exports include suppressed duplicates flagged, not deleted).
- Meds logging ⇄ chart annotations ⇄ correlation lab (regimen changes are first-class events in analysis).
- Food logging ⇄ glucose ingestion ⇄ meal-response cards (arrival-order independence: meal logged after CGM data must retro-bind).
- Depth dial ⇄ notifications ⇄ AI verbosity (one preference, many surfaces).
- Import connectors ⇄ dedup (imported archives overlap live syncs by design; idempotency required).

### 9.10 Anti-features (explicitly rejected)

1. Public leaderboards on health scores (shame dynamics; scores aren't comparable across bodies).
2. Ads or data monetization of any kind (Law 1; report: table stakes).
3. Diagnosis-flavored outputs ("you may have X") — hard wording firewall.
4. Punitive streaks (loss aversion on health data breeds anxiety and churn).
5. Dark-pattern paywalls (obfuscated numbers the user "already has"; fake urgency timers).
6. Auto-posting to social networks; any default-public anything.
7. Notification spam as engagement lever (every notification passes the decision engine's value test).
8. Infinite configurable chaos: no user-defined arbitrary formula metrics in v1 (deferred to Workbench-era with sandboxing, §45) — customization is curation, not programming, until the foundation is stable.

---
---

## 10. Health metric ontology

The canonical taxonomy. Every metric carries: **identity** (id, names/localizations, family), **type** (instant sample / interval aggregate / session / event / score), **unit(s)** + display rules, **source classes** (device/platform/manual/derived), **derivation** (if computed: inputs + algorithm id + version), **baseline policy** (rolling window, phase-conditioning eligibility), **quality metadata** (confidence, coverage, artifact flags), and **depth rendering** (casual label vs power label). The families:

### 10.1 Vitals & cardiovascular
Heart rate (continuous, resting, max, workout, sleeping) · HRV (rMSSD primary; SDNN stored where provided; derivation method user-selectable: raw-beat RMSSD vs platform field — Bevel parity) · HRV baseline (long-window) · RHR baseline · blood pressure (systolic/diastolic/pulse, manual + cuff devices) · ECG events (platform-recorded, display + provenance only, no interpretation beyond platform's own labels) · irregular-rhythm notifications (platform pass-through, neutral display) · VO₂ Max (platform-estimated; trend object) · Heart Rate Recovery (1-min/2-min post-exercise decay).

### 10.2 Sleep
Sessions (primary/nap; source-ranked) · time in bed · time asleep · stages (core/light, deep, REM, awake) · latency (time to fall asleep) · continuity/fragmentation index · efficiency · sleep/wake clock times + consistency (social jetlag = midpoint shift workday-vs-free) · HR dip % · overnight RR, SpO₂, wrist temperature (nightly aggregates) · sleep debt/bank ledger · sleep need (personal, adaptive) · wind-down/target-bedtime plan · weekly distribution pattern · snore/audio metrics (only if a source provides; no in-app recording v1).

### 10.3 Recovery & readiness
Recovery score (inputs: HRV vs phase-conditioned baseline, RHR deviation, sleep quality/duration, temperature deviation, RR deviation, prior-day load, status covariates) · readiness sub-states · stress score (daytime HRV/HR composite) · energy/battery (charge-from-sleep, drain-from-strain model; Bevel's Energy Bank parity) · strain-recovery balance view.

### 10.4 Activity & movement
Steps · distance (walk/run/cycle/swim separately where available) · floors/elevation · active energy · resting energy · exercise minutes · stand/idle breaks · MET-minutes · movement consistency (hourly distribution) · walking metrics where platforms provide (speed, steadiness, asymmetry — power-layer only).

### 10.5 Workouts & training
Workout sessions (type taxonomy mapped across HealthKit/HC/vendor types; duration; HR series; zones time; energy; distance/pace/splits; elevation; cadence; power where present) · strength session detail (exercises→sets: reps/weight/RPE/tempo/rest; supersets; templates) · per-exercise progression (volume, total reps, e1RM estimate, heaviest) · muscle-group aggregates (volume/frequency/load: Chest/Back/Shoulders/Arms/Core/Legs taxonomy, extendable) · training load: acute (7d EWMA), chronic (28d EWMA), ratio + status machine (Calibrating/Detraining/Maintaining/Productive/Fatigued/Peaking/Overtraining) · target strain + deviation-% · cardio focus distribution · HR zone definitions (multi-method: %MaxHR, %HRR, LTHR, manual; per-sport override).

### 10.6 Body composition & anthropometrics
Weight · body fat % · lean mass · BMI (computed, deemphasized) · waist/hip/chest/limb circumferences (manual) · height · smart-scale extras stored-with-caveat (impedance-derived water %, bone, visceral rating — quality-flagged "estimate").

### 10.7 Temperature
Wrist/skin temperature (nightly baseline-deviation model — absolute values de-emphasized per sensor reality) · manual body temperature (distinct metric, never merged with wrist) · cycle-relevant temperature shift detection (feeds cycle engine when enabled).

### 10.8 Respiratory & oxygenation
Respiratory rate (sleep; daytime where available) · SpO₂ (sleep aggregate + spot checks) · elevation/travel covariate flag (SpO₂ dips at altitude get context, not alarm).

### 10.9 Glucose (platform-compatible, wellness-framed)
CGM series (mmol/L | mg/dL) · morning fasting glucose · average glucose · glucose variability (CV/SD) · time-in-user-band · meal-response windows (Δpeak, time-to-baseline) · manual fingerstick entries (flagged distinct source class). No dosing, no insulin math, no diagnosis anywhere.

### 10.10 Nutrition & hydration
Energy in · macros (protein/carbs/fat; fiber, sugar, added sugar; sat fat) · micronutrients (platform-standard vitamin/mineral set) · water · caffeine · alcohol (units + timing — a sleep covariate) · meal events (type, time, tags: late-meal, high-added-sugar, etc.) · food quality score (visible rubric) · macro balance · net energy (in − out).

### 10.11 Cycle
Cycle records (period start/end, flow) · phase model (menstrual/follicular/ovulatory/luteal, predicted + logged) · cycle length/period length stats · phase-conditioned baselines for temp/HRV/RHR/sleep/recovery · symptoms linkage · pregnancy/postpartum/contraception modifiers as model flags (affecting predictions honestly — "predictions paused," not wrong guesses).

### 10.12 Biomarkers & labs
The registry mirrors and extends Bevel's observed catalog (~390+): lipid panel (ApoB, LDL/HDL/VLDL, triglycerides, Lp(a)), metabolic (HbA1c, fasting glucose/insulin, HOMA-IR), inflammation (hs-CRP, homocysteine), hormones (testosterone total/free, SHBG, DHEA-S, cortisol, IGF-1, thyroid panel), hematology (CBC family: RBC, WBC, hemoglobin, MCH/MCHC/MCV/MPV, RDW, basophils/eosinophils/lymphocytes…), renal/hepatic (creatinine, eGFR, BUN, AST/ALT), vitamins/minerals (D, B12, ferritin, magnesium, sodium…), heavy metals (mercury…), plus wearable-derived registry members (VO₂ Max, HRV/RHR baselines, body composition) so the Biology surface is one coherent list. Each biomarker: LOINC-style stable id, unit variants, reference-range library (locale/lab-aware, overridable per uploaded result), status vocabulary (In range/Out of range/Borderline + trend words), sampling metadata (fasted?, lab name, specimen date vs entry date).

### 10.13 Context & status (first-class metric family)
Activity status (Active/Sick/Injured/On A Break — Bevel parity) + extended taxonomy: Traveling (timezone-shift auto-suggested), Fasting window, Menstrual phase (auto), Medication change (auto from med log), High stress period (manual), Custom statuses. All are **interval events** that (a) annotate charts, (b) enter scoring covariates, (c) gate phrasing.

### 10.14 Subjective wellness
Mood (valence scale) · energy (subjective) · soreness (global + per-region) · perceived stress · perceived sleep quality (asked rarely, used to calibrate objective-subjective gap — the calibration-trust instrument) · free-text feelings (journal).

### 10.15 Symptoms, medications, conditions
Symptoms (canonical dictionary + user synonyms; severity 1–10 or mild/mod/severe; onset/duration; body location; triggers) · medications/supplements (ingredient, dose, route, schedule; adherence events: taken/skipped+reason/late) · conditions (user-declared labels linking symptoms/meds/metrics; no inference of conditions by the app).

### 10.16 Behavior & adherence
Logging consistency · goal adherence (per goal) · streaks (opt-in) · report/insight engagement (private, local-first analytics inputs for personalization).

### 10.17 Derived/composite registry
Every score and index above is registered as a metric itself (score history is queryable/exportable like any metric — Bevel does this in All Categories; BADAN guarantees it structurally), each carrying algorithm id + version + input snapshot reference.

### 10.18 Confidence, quality, provenance metadata (applies to all families)
Per value: source chain (device→app→platform→BADAN path), measurement vs entry timestamps, timezone, quality flags (gap-filled, artifact-suspected, user-corrected, provisional-baseline), coverage (e.g., "sleep HRV from 43 samples"), and for derived values the input manifest. Rendering rule: casual mode shows a subtle dot (green/amber) with plain tooltip; power mode shows the full chain.

---
---

## 11. Data ingestion and interoperability

### 11.1 Ingestion philosophy

BADAN ingests through **platform stores first** (HealthKit, Health Connect — the user-consented, OS-governed rails), **vendor/broker APIs second** (for devices whose richest data bypasses platform stores), **manual entry always**, and **archive imports** for history. Every path lands in the same normalization pipeline; no path gets private shortcuts around provenance.

### 11.2 The five ingestion paths

| Path | Examples | Latency | Richness | Friction | Reliability risks |
|---|---|---|---|---|---|
| Platform store (HealthKit/HC) | Apple Watch, most BLE apps, Samsung via HC | Minutes (background) | High for standard types | One consent flow | Background limits; type gaps |
| Vendor cloud API (direct) | Garmin Connect, Dexcom, Oura API | Minutes–hours (webhooks/poll) | Highest per vendor | OAuth per vendor | Token expiry; rate limits; ToS churn |
| Broker/aggregator (Terra/Sahha-class) | 500+ devices via one API | Minutes–hours | Normalized (lowest common) | One OAuth per device via broker UI | Vendor lock-in; per-user cost; data path leaves device |
| Manual entry | BP, weight, labs, symptoms, meds, food | Instant | User-limited | Taps | Typos; unit mistakes (guarded inputs) |
| Archive import | Apple Health ZIP, Garmin/Oura/Fitbit takeout, CSV | One-shot | Deep history | File handling | Format drift; massive dedup surface |

### 11.3 Normalization pipeline (order matters)

```
raw payload → source tagging → unit normalization (store SI-canonical + original)
→ timezone resolution (event tz captured; UTC canonical) → type mapping to ontology ids
→ quality flagging (artifacts, physiologic bounds checks) → dedup/de-overlap
→ session assembly (sleep/workout stitching) → aggregate computation
→ baseline/score recompute triggers → insight engine events
```

Implementation notes: pipeline is deterministic and replayable (raw payloads retained per retention policy) so algorithm upgrades can re-derive history; every stage stamps its version; the report's Sahha case (pre-aggregation layer rebuilt for accuracy, steps most improved) is the cautionary precedent — budget real months for dedup/de-overlap correctness, and ship a *reconciliation debug view* (power users see what was merged and why).

### 11.4 Dedup & source-priority rules (user-visible policy)

- Identity heuristics per family: overlapping-interval + same-type + magnitude-similarity for aggregates (steps); session-boundary similarity for sleep/workouts; exact-duplicate hashing for imports.
- Default priority: dedicated wearable > phone sensors > third-party app writes > manual (except: manual *always wins* for weight/BP/labs — deliberate human authority).
- User overrides: per-metric source ranking; hide-source (Bevel parity); per-conflict "keep both / prefer X" resolution memory.
- Nothing is deleted by dedup — suppressed records remain queryable/exportable with `suppressed_by` pointers (Law 5).

### 11.5 Write-back (BADAN as good citizen)

Mirror Bevel's granular write-back switches: food logs (macros, micros, water, caffeine, alcohol), workouts (manual/strength sessions), body measurements, mindfulness/mood where platforms support. Rules: never write derived scores into platform stores; never re-ingest own writes (self-source filtering); write-back off by default for symptoms/meds on Android until HC type support is verified per version (Section 12).

### 11.6 Interoperability outbound

Export Center (Section 20) + personal API (Phase 3) + Shortcuts/intents ("log water," "get today summary") + share-cards. Outbound is a peer of inbound in architecture reviews — the "no dead-end repository" rule.

### 11.7 Cold-start backfill strategy (the calibration fix)

On first connect: request maximal historical window (HealthKit: full history; HC: 30 days by default — request extended range permission where available, else prompt archive import for deep history); compute provisional baselines immediately from history; label provisional until N nights of fresh data confirm (visible countdown). KPI: ≥80% of new users see a personalized (not generic) insight in session 1.

---
---

## 12. HealthKit and Android equivalent capability map

The practical capability matrix. Legend: ✅ direct platform support · 🔶 partial/version-dependent · 🔌 needs vendor/broker integration · ✍️ manual logging path · ❌ not practical now.

### 12.1 Core biometrics

| Capability | iOS (HealthKit) | Android (Health Connect) | Fallback / notes |
|---|---|---|---|
| Heart rate (continuous) | ✅ | ✅ | — |
| Resting HR | ✅ type + 🔶 own derivation from raw (user-selectable method, Bevel parity) | ✅ type; raw-derivation where series present | Method choice documented in-app |
| HRV | ✅ SDNN field; 🔶 beat-to-beat via raw samples (rMSSD derivation) | ✅ HRV RMSSD type | Store both; method switch |
| ECG | ✅ (display + provenance) | 🔶 (not in HC; vendor apps only) | 🔌 vendor; neutral display only |
| Blood pressure | ✅ | ✅ | ✍️ + cuff devices via platform |
| SpO₂ | ✅ | ✅ | — |
| Respiratory rate | ✅ | ✅ | — |
| Wrist/skin temperature | ✅ (sleeping wrist temp) | 🔶 (skin temp type; device-dependent) | 🔌 vendor for some rings |
| VO₂ Max | ✅ | ✅ | Vendor estimates differ — provenance shown |
| HRR | 🔶 derive from workout HR series | 🔶 derive | Own algorithm, documented |

### 12.2 Sleep

| Capability | iOS | Android | Notes |
|---|---|---|---|
| Sleep sessions + stages | ✅ (stages iOS 16+) | ✅ (stages) | Multi-source ranking needed |
| Sleep HR/RR/SpO₂/temp aggregates | ✅ via overlapping samples | ✅ via overlapping samples | Session-window join in pipeline |
| Nap detection | 🔶 source-dependent | 🔶 | Classify by duration/time rules |
| Sleep debt/bank, latency, continuity | derived | derived | Own algorithms |

### 12.3 Activity & workouts

| Capability | iOS | Android | Notes |
|---|---|---|---|
| Steps/distance/floors/energy | ✅ | ✅ | Dedup phone-vs-watch critical |
| Workout sessions + HR series | ✅ (+ segments/laps 🔶 by source) | ✅ ExerciseSession + series | Vendor APIs richer for laps/power → 🔌 |
| Cycling/running power, cadence | ✅ types (iOS 17+) / 🔶 | 🔶 types vary by version | 🔌 Garmin/Polar direct for depth |
| Strength set/rep detail | ❌ platform (only session) | ❌ | ✍️ BADAN Strength Builder is the system of record; write session summary back |

### 12.4 Nutrition, hydration, glucose

| Capability | iOS | Android | Notes |
|---|---|---|---|
| Macro/micro dietary types | ✅ (broad set) | ✅ (Nutrition record, broad) | Write-back toggles per Bevel parity |
| Water / caffeine | ✅ / ✅ | ✅ / 🔶 (caffeine within nutrition) | — |
| Alcohol | ✅ (number of drinks iOS 18-era) 🔶 | 🔶 (log as nutrition/custom) | Store internally regardless; write where supported |
| Blood glucose (CGM → platform) | ✅ (Dexcom/Libre write to HK, device/region dependent) | ✅ HC glucose type (writer availability varies) | 🔌 vendor APIs (Dexcom share/partner, Libre LibreView) where store path absent — Section 13.5 |
| Insulin delivery | ✅ type exists | 🔶 | Display-only if present; no dosing features |

### 12.5 Body, cycle, other

| Capability | iOS | Android | Notes |
|---|---|---|---|
| Weight/body fat/lean mass | ✅ | ✅ | Smart scales usually write to stores |
| Cycle tracking types (flow, symptoms, basal temp) | ✅ rich set | ✅ menstruation types | Sensitive-class storage rules §28.7 |
| Mindfulness/mood | ✅ (State of Mind iOS 17+) | 🔶 | Internal always; sync where possible |
| Medications | ✅ (HK medications iOS 16+; read user-entered) | ❌ HC type today → internal system of record | Export/report covers the gap; revisit per HC releases |
| Symptoms | ✅ HK symptom category types (subset) | ❌ → internal | Internal canonical dictionary is richer anyway |
| Clinical records (FHIR) | 🔶 US-centric HK Clinical Records | ❌ | Phase-4 regional strategy §45 |

### 12.6 Permissions & friction economics

- **iOS:** per-type read/write grants in one HK sheet; users can partially grant. BADAN requests in *staged bundles*: Core (sleep/HR/HRV/activity) at onboarding; Nutrition/Glucose/Cycle bundles only upon module activation. Each request screen states value + what happens if denied.
- **Android:** HC permission screen per record type + separate background-read permission (13+/version-dependent) + battery-optimization exemption ask for reliable sync. Stage identically; treat background-read denial as "foreground-refresh mode" (visible banner, not silent staleness).
- **Denial fallbacks:** every module has a defined denied-state: e.g., no sleep permission → sleep pillar shows education + manual sleep log option + re-request path; never a dead screen. Full matrix maintained as a living QA artifact (seeded in Section 37.3).

### 12.7 Practical vs theoretical

Practical now: everything marked ✅/✍️ above; CGM via platform stores; medications-on-iOS read. Theoretical/deferred: HC medications/symptoms types (watch releases), cross-platform clinical records, BLE-direct sensor connections (BADAN deliberately does not build a BLE stack in v1 — platform stores and vendor bridges cover it with far less maintenance risk).

---
---

## 13. Device ecosystem compatibility strategy

### 13.1 Tiering model

- **Tier 1 (launch, first-class):** Apple Watch (via HealthKit), Wear OS/Pixel Watch + Samsung Galaxy Watch (via Health Connect), phone-sensor-only users (steps/sleep-lite), smart scales writing to stores (Withings/Eufy/Garmin Index…), BP cuffs writing to stores (Omron/Withings/Qardio).
- **Tier 2 (Phase 2):** Garmin (direct API — Bevel parity), Oura (API), Fitbit (API), Polar/Suunto/Coros (broker or direct), CGMs (Dexcom, Libre, Lingo — §13.5), Whoop (API availability permitting; else broker).
- **Tier 3 (Phase 3):** Withings ecosystem direct (sleep mats, thermometers), Eight Sleep-class sleep devices, additional rings (Ultrahuman/RingConn/Circular), rowers/bike trainers (via workout files/partners), continuous BP wearables as they mature.
- **Emerging watchlist:** smart earbuds vitals, cuffless BP, wearable core-temp, smart CGM patches for wellness, UWB presence-based sleep sensing. Architecture rule: new device classes must be attachable as *new source adapters* without schema surgery (ontology extensibility, §10/§30).

### 13.2 Per-ecosystem notes

| Ecosystem | Primary path | Depth notes | Risks |
|---|---|---|---|
| Apple Watch | HealthKit | Fullest standard set incl. wrist temp, stages, HRV | None beyond platform limits |
| Samsung | Health Connect (Samsung Health syncs to HC) | Good vitals/sleep coverage | HC sync toggles confuse users → guided setup screen |
| Garmin | Direct Garmin Connect API + HC/HK companion writes | Richest training files (laps, power, training-load native) | Dual-path duplicates → source-priority default: Garmin-direct wins for workouts |
| Oura | Oura API v2 (+ store writes) | Sleep/readiness granularity, temperature deviation | API subscription-gated fields; degrade gracefully |
| Fitbit | Fitbit Web API | Steps/sleep/HR solid | Google platform migration watch |
| Whoop | API (limited availability) / broker | Recovery/strain native | Access constraints; treat as optional adapter |
| Polar/Suunto/Coros | Broker first | Endurance depth via files | Long-tail maintenance → broker economics |
| Withings | Store writes now; direct later | Scales/BP/mats | Low risk |
| Dexcom | Store write (regional) + partner API | Real-time-ish EGVs | Program approval timelines |
| Libre/Lingo | Store writes / LibreView-Lingo paths | Sensor-session gaps | Compression-low artifacts → quality flags |

### 13.3 Direct vs broker decision framework

Choose **direct** when: data depth materially exceeds broker normalization (Garmin training files, Dexcom), the vendor is strategically core, or broker per-user economics break the free tier. Choose **broker** when: long-tail coverage (500+ devices), speed to market, or maintenance burden dominates. **Hybrid default:** broker for breadth at Phase 2 entry, direct replacements for the top 3–4 volume sources as usage data arrives. Contract requirements for any broker: user-data processing agreement compatible with BADAN's privacy posture (no secondary use), EU/GCC data-residency options, webhook + backfill APIs, and a defined exit path (export of connection inventory so users can re-auth direct integrations if BADAN switches).

### 13.4 Companion vs bridge reality

Many devices already deliver into HealthKit/HC via their own apps. BADAN's setup wizard therefore starts with *detection*: read available sources from the store, recognize signatures (e.g., Oura app writes), and only offer direct/broker OAuth when store data is absent or shallow. This avoids the classic double-ingestion mess and minimizes OAuth friction.

### 13.5 CGM strategy (wellness framing locked)

Paths: platform store reads (preferred; Dexcom & Libre write to HK in many regions; HC glucose type on Android) → vendor APIs where store gaps exist → manual fingerstick always. Features gated to wellness: day-strip, meal responses, variability, personal bands with user-set thresholds (defaults 3.9–7.8 mmol/L as observed in Bevel, editable, unit-localized). Explicit non-features: dosing calculators, alarms marketed for hypo/hyper safety (OS/vendor apps own safety alerting; BADAN states this in CGM onboarding).

### 13.6 Import/export connectors as compatibility multipliers

Historical archive importers (Apple Health ZIP, Google Takeout, Garmin/Oura/Fitbit/Whoop exports, generic CSV mapper with column-mapping UI + unit checks) make BADAN compatible with *the user's past*, not just their present devices — a compatibility class no benchmark app serves.

---
---

## 14. Information architecture

### 14.1 Top-level IA (five destinations + one global action)

```
Today | Journey | Body | Log (+) | Coach | (Profile/Settings via avatar)
```

- **Today** — L1 daily contract + curated modules (Bevel Home parity, presence-based).
- **Journey** — time: unified Timeline, calendar (day rings → month → year heat), digests/reports, experiments. (Answers "what happened / is it working," the layer Bevel scatters.)
- **Body** — the repository: pillars grid (Sleep/Recovery/Strain/Fitness/Nutrition/Glucose/Cycle/Biology/Meds/Symptoms), All-Metrics browser, Raw Data Explorer, Export Center. (Bevel's Fitness+Biology+All-Categories unified under one "your body's data" mental model.)
- **Log (+)** — global logging hub (FAB parity): food, water/caffeine/alcohol, workout, symptom, med-taken, mood, measurement, note, status.
- **Coach** — narratives, insight feed, check-ins, Ask-BADAN chat, education library. (Bevel buries Intelligence behind paywall promos; BADAN gives it an address.)
- Depth dial shrinks the *contents* of destinations, never the destination set (casual users see the same five doors; muscle memory is preserved as they deepen).

### 14.2 IA principles

1. Time, body, and action are orthogonal axes — never mix them in one list.
2. Every entity has exactly one canonical home + unlimited contextual appearances (a workout lives in Journey/Timeline; appears in Strain, Fitness, Coach).
3. Search reaches everything from anywhere (§35).
4. Settings is a modal stack (Bevel parity) — configuration is not a destination.
5. Paywall surfaces live *inside* the features they upgrade, never as interstitials between destinations (anti-pattern from the recording: two paywall interruptions in six minutes).

### 14.3 Entity→surface map (selected)

| Entity | Canonical home | Also appears in |
|---|---|---|
| Sleep session | Journey/Timeline | Sleep pillar, Today hero, Coach narrative, metric details |
| Score (any) | Its pillar hero | Today, calendar rings, digests, All-Metrics, export |
| Food entry | Journey/Timeline | Nutrition pillar, meal-response cards, Coach |
| Medication schedule | Body/Meds | Today (due strip), Timeline (taken events), chart annotations |
| Symptom event | Journey/Timeline | Body/Symptoms, correlations, reports |
| Lab result | Body/Biology | Timeline, biomarker detail, reports |
| Status interval | Journey/Timeline | Every chart annotation layer, scoring covariates |
| Insight | Coach feed | Today (top card), digests, per-metric detail ("insights about this") |

---
---

## 15. Navigation model

### 15.1 Navigation topology

- **Root:** 5-tab bar (Today, Journey, Body, Coach + center-elevated Log). iOS: SwiftUI TabView with floating-style bar; Android: Material 3 navigation bar; Log as a center FAB-in-bar on both. (Bevel's collapsing pill dock is elegant but hides orientation; BADAN keeps persistent labeled tabs — discoverability beats minimalism for a five-destination app — while adopting the *collapse-on-scroll to slim mode* behavior to preserve reading space.)
- **Push stacks** per tab (pillar → metric → anatomy), preserved on tab switch.
- **Sheets** for: metric detail quick-look (swipe up to full push), logging flows, pickers (period calendar, options), Score Anatomy.
- **Modal full-screens** for: onboarding, report composer, paywall (only from feature-context), Settings stack (X-close, Bevel parity).
- **Universal gestures:** edge-swipe back (iOS) / predictive back (Android); pull-to-refresh triggers visible sync state (Bevel's "Syncing…"/"Sync Complete" toast pattern adopted); long-press on any card → context menu (pin, hide, reorder, explain, export this).

### 15.2 Date navigation grammar (one system everywhere)

Header date-pager (‹ day ›) + tap-title calendar sheet with per-day rings (Bevel parity) + "Today" snap-back. Period charts use the same segmented control everywhere: `7D | 30D | 3M | 6M | 1Y | All` + calendar icon + paging chevrons (Bevel's control, plus 7D and All). Consistency rule: a user who learns date control on Sleep can operate every chart in the app, including labs.

### 15.3 Deep links & app intents

Stable URL scheme (`badan://metric/hrv?date=…`, `badan://log/food`, `badan://report/weekly`) powering: widgets, notifications, Shortcuts/Assistant actions, share-cards, and internal cross-links (connective tissue). Every notification must deep-link to the exact evidence it cites (no landing on generic Home — a top annoyance class).

### 15.4 State preservation & cold-start speed

Full state restoration after process death (tab, stack, scroll anchors); Today renders from local cache in <400 ms cold (perf budget §32.6) with sync deltas applied non-jarringly (no full-screen spinners on root surfaces; skeletons only in never-loaded areas).

---
---

## 16. Screen-by-screen app blueprint

Notation per screen: **Purpose · Target · Primary/Secondary actions · Visible data · Hidden/advanced affordances · Charts · Filters · Interactions · Confusion risks · Friction reducers · Power-mode enhancements · Key states (empty/first-run/loading/denied/no-data).** Screens are grouped by area. This inventory is the UX contract; each entry seeds one or more backlog epics (Section 42).

### 16.1 Shell & system screens

**S-01 App shell / tab bar.** Purpose: orientation + global log. States: normal; offline chip (subtle cloud-slash, tap = sync status sheet); syncing shimmer on active tab icon. Power: long-press Log = recents radial (last 4 log types).

**S-02 Global sync status sheet.** Purpose: trust in freshness. Data: per-source last-sync, pending queue, background-permission state. Actions: resync (Bevel parity), open source settings. Confusion risk: "synced" vs "processed" — show both stages explicitly.

### 16.2 Onboarding & setup wizards

**S-10 Welcome.** Value promise + language selector (EN/AR at launch; RTL flips immediately — first trust signal). No account required to proceed (local-first path).
**S-11 Platform connect.** HealthKit/HC staged Core bundle request with plain-language value + denial consequences. Denied state: manual-mode explainer + re-request path.
**S-12 Backfill & first insight.** Progress with live counts ("Reading 214 nights of sleep…") → immediately renders 2–3 provisional personal facts. This screen is the calibration-gap killer (P4).
**S-13 Three-question tuning.** Goal focus (feel better / train smarter / track health issues / understand everything) → maps to preset; depth appetite (keep it simple / show me depth); modules opt-in (nutrition, cycle, meds/symptoms, glucose, biology). Skippable; defaults sane.
**S-14 Notifications opt-in.** Shown *after* first value, with concrete examples of the 2 default notifications only (morning narrative, weekly digest). Never a blank OS prompt.
**S-15 Device/source wizard.** Detection-first (§13.4): recognized sources listed with ✓; offer direct/broker connect for gaps. Per-source setup guides (e.g., Samsung Health→HC toggle walkthrough with screenshots).
**S-16 Account/sync choice (optional).** Local-only vs encrypted sync; explicit tradeoffs table. Deferred freely.
**S-17 Getting-started stories.** 4–6 page story-format explainers per pillar (Bevel parity: interpretation + how-calculated per page), re-openable from Coach/Library.

### 16.3 Today (L1)

**S-20 Today root.** Purpose: the daily contract. Visible: date pager; context strip (statuses + weather chip, Bevel parity); hero (three rings Sleep/Readiness/Strain — labels localized; tap = pillar); **One True Sentence** narrative card with "why →"; then curated modules (defaults by preset): Health Monitor grid (6 vitals tiles with vertical range pills — Bevel parity), Meds due strip (if meds), Stress/Energy card, Nutrition snapshot (presence-based), Timeline preview (3 items), weekly progress chip. Primary: glance; open pillar. Secondary: edit layout; jump to calendar. Hidden: long-press any module (pin/hide/reorder/explain); pull-down search. Confusion risks: three rings must not read as Apple-rings clones — distinct semantics taught once via first-run coach marks. Friction: everything readable without scroll on default preset (5 modules max casual). Power mode: tiles show deltas vs baseline + tap-through density (e.g., ring shows score + top driver word). States: first-run (provisional badges), no-wearable (manual-mode hero variant: subjective check-in + steps from phone), all-denied (education hero), stale (>36h: gentle "data paused" banner with fix path).

**S-21 Edit Today (layout editor).** Bevel Edit-Home parity: drag, remove, add-card gallery (grouped by pillar, with previews), reset-to-default, **preset switcher** (Casual/Athlete/Recovery/Longevity/QS presets — §19.3). Power: per-module size (compact/regular/tall).

**S-22 Calendar sheet.** Month grid with per-day tri-ring minis (Bevel parity) + year heat-map zoom (BADAN addition). Tap day → Today-of-that-day (read-only past mode). Legend + (i).

### 16.4 Journey (time layer)

**S-30 Journey root.** Segmented: Timeline | Calendar | Reports | Experiments.
**S-31 Unified Timeline.** All typed events, day-grouped, filter chips (Sleep/Workouts/Food/Meds/Symptoms/Notes/Statuses/Labs/Sync). Infinite scroll to history. Row grammar: icon + title + key value + score/severity badge + time. Tap → native detail. Power: multi-select → bulk tag/delete (manual entries only) or "send to correlation."
**S-32 Digest viewer (weekly/monthly).** Narrative + key charts + "what changed" table + next-week focus. Actions: share-card, export PDF, adjust digest verbosity.
**S-33 Year in Body (annual).** Story-format annual report (§22.9).
**S-34 Experiments list + S-35 Experiment detail.** Define (variable, start/end, hypothesis) → tracked comparison (before/during, confidence caveats) → verdict card ("suggestive," "no clear change" honesty vocabulary).

### 16.5 Body (repository layer)

**S-40 Body root.** Pillar cards grid (only active modules; inactive shown in a collapsed "Add more" row — P5). Below: All Metrics browser entry, Raw Data Explorer, Export Center, Data Sources.
**S-41 Sleep pillar** (grammar §8.3): ring + art hero; stats (time asleep, in bed, latency); narrative; context strip; wind-down/target clock dial (Bevel parity); Sleep Bank card; stage bars; Trends list (score, time asleep, REM, deep, HR dip, bank, sleep/wake times, latency, continuity — the Bevel floor plus continuity/social-jetlag); weekly distribution strip. Power adds: stage-hypnogram in hero, night-by-night overlay compare.
**S-42 Recovery pillar:** ring + art; HRV/RHR stat cards with deviation badges (Bevel parity); narrative + why; input anatomy strip (mini-bars showing each input's pull — BADAN signature); trends (recovery, HRV, RHR, RR, SpO₂, temp — Bevel floor). Cycle-aware band note when enabled.
**S-43 Strain pillar:** today ring + zones bar (Zone 0–5 durations, Bevel floor); activities list; target-strain band chart; narrative.
**S-44 Fitness pillar:** activity heat-calendar (Bevel parity); Activity Summary comparison card; Strain Performance; Cardio Load (status machine + envelope chart); Cardio Focus; HRR; Strength section (muscle radar with metric switcher — Volume/Frequency/Load, Bevel parity); Strength Progression (per-exercise cards); Templates. Layout editable (Bevel parity).
**S-45 Nutrition pillar:** today plate summary (kcal + macro rings, g/% toggle); My Foods (favorites/recipes/recents); goals card; micronutrient matrix (dot-grid, Bevel parity); Net Energy diverging bar; meal timeline with + ; trends (nutrition score with visible rubric link, macro balance); glucose module if CGM (day-strip with meal markers, thresholds editable via gear — Bevel parity). Passive state (no logs): shows energy-out context + "log first meal" invite, not zeros.
**S-46 Glucose pillar (if enabled):** day strip, overlays (meals/activity/sleep), fasting/average/variability cards, meal-response library, sensor-session status incl. gap honesty.
**S-47 Cycle pillar (if enabled):** phase wheel + prediction confidence; phase-conditioned expectations card ("HRV typically dips ~8% for you in this phase"); log strip; history rows.
**S-48 Biology pillar:** curated biomarker list (Edit — Bevel parity) with status+value+sparkline rows; full registry link; Biological Age card (free: coarse band + drivers; paid: full model) — dial visual (Bevel parity) *without* particle-scramble teasing; lab timeline; add-result CTA.
**S-49 Biomarker registry.** Alphabetical + grouped views, A–Z rail, search, per-row status/value/sparkline or honest "No data" (Bevel parity), filter: has-data / out-of-range / pinned.
**S-50 Medications hub:** active regimen list (dose/schedule/next-due), adherence week-strip (non-punitive), history, per-med detail (S-51: schedule, adherence chart, linked symptoms/metrics annotations, notes; edit/retire). 
**S-52 Symptoms hub:** frequent-symptoms chips, log list, per-symptom detail (S-53: frequency chart, severity trend, co-occurrence panel, correlation shortcuts).
**S-54 Conditions/issues repository:** user-declared condition cards linking meds+symptoms+relevant metrics; per-condition view assembles its own mini-dashboard + report shortcut.
**S-55 All Metrics browser.** Bevel All-Categories parity: search, pillar groups, sparkline rows; plus filters (has-data, pinned, out-of-band) and sort (recency/name/deviation).
**S-56 Metric detail (universal, ~300 instances).** Full template §8.4. Charts by family: band-line (vitals), stacked bars (stages, cardio focus), ledger area (sleep bank), diverging bar (net energy), event-frequency (symptoms), adherence strip (meds), point-with-reference-range (labs). States: no-data (education + how-to-get-data paths), single-point (labs: value + range, no fake trend), provisional (badge), denied-source (permission fix path).
**S-57 Score Anatomy sheet.** Inputs with direction/weight bars, data-quality row, algorithm version + changelog link, "what would move this" bullets, "ask Coach about this."
**S-58 Raw Data Explorer.** Table view per metric: timestamp, value, unit, source chain, flags; day/source filters; row → full lineage sheet (S-59) showing dedup decisions ("suppressed duplicate of…"). Export-this-slice button.
**S-60 Data Sources.** Bevel parity+: per-metric source counts → device lists → hide/prioritize; global source health (last seen, auth status); resync; restore.
**S-61 Export Center.** §20 UX: format cards (CSV/JSON/PDF/…); scope pickers (metrics/date/sources); templates ("physician visit," "full archive," "sleep study self-report"); history of past exports; scheduled exports (Pro).

### 16.6 Log flows (the + hub)

**S-70 Log hub.** Grid of log types with per-user recents row on top. One-handed reach; opens in <300 ms.
**S-71 Food search/entry** (search-first, barcode button, photo button, describe field; portion stepper; meal assignment; favorites star). **S-72 Photo-AI review** (candidate items with confidence chips; tap-to-correct each; portion sliders — corrections train personal aliases). **S-73 Barcode result.** **S-74 Recipe builder.** **S-75 Water/caffeine/alcohol quick sheet** (preset volumes; long-press to customize presets).
**S-76 Workout add/edit** (type picker with recents, duration/intensity or connect-device hint). **S-77 Strength logger** (template start → per-set: weight/reps steppers with plate-math, RPE optional, rest timer, superset grouping; finish summary → write-back). 
**S-78 Symptom log** (recents chips → severity slider + duration + optional body-map + trigger tags + note). **S-79 Medication taken/skip** (due list, one-tap take-all, skip-with-reason chips). **S-80 Mood/energy check-in** (two sliders + optional word chips; 5 seconds total). **S-81 Measurement entry** (weight/BP/temp/waist… with unit-guarded keypads). **S-82 Note/journal** (text, tags, attachment, link-to-day). **S-83 Status setter** (Bevel parity sheet: statuses with icons/descriptions + date-range + retroactive-apply note).

### 16.7 Coach (interpretation layer)

**S-90 Coach root.** Narrative of the day (expanded); insight feed (cards with evidence links + 👍/👎 + "why"); check-ins strip; Ask field. 
**S-91 Chat/Ask-BADAN.** Grounded Q&A over own data; answer cards embed mini-charts + "data used" footnote (window/sources); suggested follow-ups; per-thread history (Pro: deep analysis mode). Guardrail banner on first use (wellness scope).
**S-92 Check-in config.** Cadence, topics, tone (concise/detailed; warm/neutral — §23.8), quiet hours link.
**S-93 Education library.** Pillar explainers, metric glossary (every ontology entry), algorithm pages, "Understanding your data quality" article set (Bevel Resources parity, indexed + searchable).

### 16.8 Profile & settings stack (modal)

**S-100 Settings root:** Account/sync state card · Membership · Referrals · General (Appearance incl. app icons + theme; Notifications matrix; Language & Units; Depth dial; Quiet hours) · Modules (per-module visibility with live previews + per-module settings — Bevel Customization parity: Goals, HR Zones multi-method editor, Calculations/method choices with explainers, Data Loading Window, Cycle lengths, Nutrition write-back toggles, Strength defaults, Journal/water goal) · Data & Privacy (Sources, Consent center, Privacy dashboard, Export, Import, Delete) · Automation (Shortcuts/intents gallery — Bevel parity) · Resources (What's new, Getting started, Knowledge base, Roadmap/feature requests, Report a bug, Rate).
**S-101 Consent center:** per-data-type grants, last-read timestamps, revoke paths (deep-link to OS where required), sensitive-class toggles (cycle/off-cloud AI flags).
**S-102 Privacy dashboard:** plain-language "what leaves this device and why" with live counters; local-only mode switch.
**S-103 Membership:** entitlement checklist Free vs Pro (Bevel's honest ✓/✗ list format adopted), restore, manage.
**S-104 Delete/exit flows:** export-first offer, staged confirmation, verifiable completion state.

### 16.9 Cross-cutting states (every screen must define)

Loading (skeletons mirror final layout; no spinners >600 ms without shape) · Empty-with-path (what this will show + how to feed it) · Permission-denied (value restatement + fix path) · No-data-today (yesterday's context offered) · Provisional (calibration badge + countdown) · Error (retry + support id) · Offline (cached banner; logging always works offline) · Paywalled (feature-context explanation + what free tier shows instead — never obfuscated numbers).

---
---

## 17. Casual-user mode design

### 17.1 The casual contract
≤10 seconds/day for value; zero required input; no guilt; no jargon without inline translation; nothing alarming without confidence + context; the app never visibly "grows" unless invited.

### 17.2 Mechanisms
- **Curated ceiling:** casual preset caps Today at 5 modules; pillar pages hide Trends tables behind "See trends"; metric chips row collapsed.
- **Vocabulary layer:** casual labels ("Readiness," "Sleep," "Effort") map 1:1 to power labels (shown in parentheses on detail screens the first 3 visits — the learning bridge).
- **One-number honesty:** rings carry a one-word driver ("Readiness 62 — short sleep") so the number never floats meaninglessly.
- **Automatic everything:** statuses auto-suggested (travel via timezone, sick via prolonged deviations + gentle confirm), sleep/workouts auto-imported, insights auto-generated. Confirmations are one tap, always optional.
- **Notification floor:** default = morning narrative + weekly digest only. Everything else opt-in.
- **Empty-state suppression** (P5) keeps the surface small for wearable-only users.

### 17.3 Casual failure modes designed against
Overwhelm on first open (staged module reveal over first week — "progressive onboarding"); score anxiety (gentle-mode option hides day scores, keeps weekly trends — the orthosomnia guard); paywall resentment (free tier is complete-feeling: all metrics interpreted individually); death-by-defaults (quarterly "tune your app" 60-second review, skippable forever).

### 17.4 The casual→engaged ramp
Triggered invitations only at value moments: after 3 taps into Sleep details in a week → "want the sleep-focused layout?"; after first food log → nutrition module offer; after export → power-mode tour. Never time-based upsells of complexity.

---
---

## 18. Power-user mode design

### 18.1 The power contract
Every number decomposable (Anatomy everywhere); every sample inspectable (Explorer + lineage); every dataset exportable (Center + API); every algorithm documented + versioned (changelog; recompute notes); every default overridable within the curation model (sources, methods, zones, bands display, units per metric); nothing dumbed down silently.

### 18.2 Power surfaces (beyond casual's)
Raw Data Explorer with lineage · Correlation Lab (§22.7) · Experiments (§22.8) · comparison overlays (metric-vs-metric, period-vs-period) · annotation-dense charts (statuses/meds/cycle layers toggleable) · rolling-delta tables everywhere (Bevel parity) · algorithm pages + Score Anatomy with quantitative weights · scheduled exports + personal API (Pro) · advanced notification rules ("notify me when HRV 7-day delta < −10%") · data-quality dashboards (coverage %, artifact counts per source).

### 18.3 Density mechanics
Power mode swaps: compact card paddings; sparklines gain axes on tap; tables default-open; deviation badges show numbers not just arrows; Today tiles adopt stat-dense variant. All still within the same navigation topology (Law/P10).

### 18.4 Respect protocols
User corrections are authoritative and propagate (edited sleep session recomputes scores with a visible "recomputed" note); disagreement affordance on every insight ("this doesn't match how I feel" → logged, down-weights insight family, feeds calibration); no silent algorithm changes (in-app changelog with per-user "your scores were re-derived" notices — the trust move Bevel's opaque updates miss).

### 18.5 How one data model serves both (the recurring tension, resolved)
The renderer consumes the same metric records + a **presentation policy** object (depth level, label set, density, annotation defaults). Casual and Power are policies, not schemas. QA implication: every feature tests under both policies; design implication: neither mode is an afterthought skin — components are built policy-aware from the start (Section 26.6).

---
---

## 19. Personalization and customization system

### 19.1 Customization philosophy: curation, not chaos
Users customize by *selecting and arranging sanctioned modules*, never by breaking invariants (navigation topology, truthfulness, template grammar). Every customization has a visible reset. Bevel's model (Edit Home, per-tab card editing, module visibility switches with live previews, biomarker list Edit, calculation methods) is the validated backbone; BADAN extends it with presets, per-surface depth, and terminology preferences.

### 19.2 The customization inventory

| Domain | Controls | Default | Notes |
|---|---|---|---|
| Dashboard layout | add/remove/reorder/resize modules per surface (Today, pillar pages) | preset-driven | Bevel parity + size variants |
| Metric pinning | pin any metric to Today/pillar top/watch | preset | long-press anywhere |
| Card visibility | per-module show/hide with live preview | presence-based | Bevel parity |
| Module activation | Nutrition/Cycle/Glucose/Meds/Symptoms/Biology/Strength on-off | onboarding choice | "disables all related UI" warning, Bevel parity |
| Themes | dark/light/auto + accent palettes + app icons | auto | Bevel offers dark-only + icons; BADAN adds full light theme |
| Terminology | casual/precise label sets; per-language | depth-dial-linked | e.g., "Readiness" ↔ "Recovery composite" |
| Chart density | annotations default on/off; band display; axis verbosity | depth-dial | per-chart override remembered |
| Units | global system + per-metric override (kg/lb, mmol/L / mg/dL, °C/°F, km/mi) | locale | exports honor a chosen unit profile |
| Report verbosity | digest length (glance/standard/deep); sections toggle | standard | applies to PDFs too |
| Notifications | per-type on/off, timing, quiet hours, bundling | floor defaults | §24.8 matrix |
| AI tone | concise↔detailed; warm↔neutral; language | warm+concise | §23.8 |
| Daily summary | delivery time, channels (push/widget/none), content blocks | 7:30 push | — |
| Custom tags | free tags on any loggable entity | — | used in filters/correlations |
| Custom symptoms/meds/foods/activities | user-defined entries in each dictionary | — | mapped to canonical where possible |
| Custom issue categories | condition labels + linked entities | — | §21.7 |
| Goals | per-metric targets (sleep duration, steps, weight direction, macro targets, adherence) | optional | multi-method (value/range/direction) |
| Custom metric collections | named sets ("my labs watchlist," "race prep") usable as dashboard module/report scope/export scope | — | power feature with casual payoff |
| Custom widgets | widget gallery with per-widget metric choice | preset | §24 |
| Shortcuts/automations | intents gallery, configurable | — | Bevel parity+ |
| Score visibility | hide any score (e.g., gentle sleep mode) without disabling data | all shown | anti-orthosomnia |
| HR zones | multi-method (%max/%HRR/LTHR/manual), per-sport | %max from est. | exceeds Bevel |
| Calculation methods | HRV/RHR derivation, sampling windows, temp method, merge-manual-sleep | recommended set | Bevel parity with in-line explainers |

### 19.3 Presets (chaos control)
Five starter presets bundle the above: **Essential** (casual), **Athlete** (training-forward), **Recovery** (gentle, status-aware), **Longevity** (biology-forward), **Analyst** (power-everything). Presets are starting points — applying one never deletes user data or custom entities; a diff preview shows what changes. Re-applyable; mixable per-surface.

### 19.4 Sync & portability of customization
Customization state is itself data: exportable (JSON profile), synced across devices, restorable. Prevents the "new phone reset my app" trust break.

### 19.5 Anti-chaos guardrails
Max module counts per surface with overflow into "More" row; layout linting (warn when hiding safety-relevant surfaces like meds-due); global "reset all customization" with export-first prompt; design-system enforcement means user arrangements can't produce broken layouts.

### 19.6 Per-domain notes
HR zone editor ships with method education (why LTHR differs), per-sport overrides, and history (zone changes annotate charts — retroactive strain isn't silently redefined; recompute is explicit and versioned). Terminology preferences never rename exported columns (exports use stable ids + chosen-language display columns).

---
---

## 20. Raw data, reports, and export system

### 20.1 Strategy
Export is BADAN's flagship trust feature and top-of-funnel differentiator (report: universal ❌ across WHOOP/Oura/Bevel; Medium-High demand). Design goal: *the best-documented personal health export in consumer software.*

### 20.2 Formats
- **CSV** (per-metric files, tidy long format: timestamp_start, timestamp_end, metric_id, value, unit, source_app, source_device, quality_flags, algorithm_version, suppressed_by) — spreadsheet-ready.
- **JSON** (schema-versioned, nested by domain; includes dictionaries: metric registry slice, source registry, status taxonomy).
- **SQLite bundle** (single file, indexed, with views mirroring the app's own queries) — the QS crowd's dream artifact.
- **Parquet** (Phase 3, analyst-grade).
- **PDF reports** (human-readable — §20.6).
- **Machine-readable archive** (ZIP: all of the above + manifest + data dictionary + checksums).
- **FHIR-shaped observations** (Phase 4, for clinical hand-off contexts; wellness-labeled).

### 20.3 Scoping model
Any export = format × scope. Scope pickers: metrics (individual/collection/pillar/all) · date range (presets + custom) · sources (include/exclude; include-suppressed-duplicates toggle) · raw vs derived vs both (clearly separated in output) · unit profile · language for display columns.

### 20.4 Raw Data Explorer (in-app)
The pre-export microscope (S-58/59): sample tables, lineage sheets, dedup decisions, artifact flags. Rationale: users who can *see* raw data trust exports sight-unseen; support burden drops ("why is this value X" self-served).

### 20.5 Provenance & explainability in exports
Every derived value exports with algorithm_id + version + link (in manifest) to its methodology page; every raw value with full source chain; manifests include: app version, export schema version, dedup policy description, timezone handling notes, and per-metric row counts (so truncation is detectable). Schema changes follow semver with a published changelog; old schema majors remain readable via documented migration notes.

### 20.6 PDF report system (Report Composer)
Templates: **Physician visit** (date-range vitals/meds/symptoms/labs summary, chronological + tabular, deliberately conservative formatting) · **Sleep self-study** · **Training block review** · **Full annual** · **Custom** (pick sections). Each: cover context (period, sources, data-quality note), narrative (tone: neutral-clinical for physician template), charts print-safe (color-blind-safe, grayscale-legible), and a mandatory footer: "Personal wellness records collected by consumer devices and self-reports; not a medical record; accuracy varies by device."
UX: compose → live preview → share/save. Casual users reach curated one-tap versions of the same engine ("Share this week").

### 20.7 Scheduled & automated exports (Pro)
Recurring exports (weekly/monthly) to Files/Drive/iCloud; Shortcuts/intents ("export last month as CSV"); webhook target (Phase 3, power).

### 20.8 Personal API (Phase 3)
Read-only REST, personal access tokens with scopes (per-pillar), rate-limited, token audit log in Privacy dashboard. Local-only users get a device-local export server alternative (LAN, user-initiated) — parity thinking for the cloudless.

### 20.9 Privacy & deletion interplay
Deletion flow offers final export first; exports are user-initiated artifacts (BADAN doesn't retain copies post-delivery beyond transient generation); shared-report links (if used) are expiring and revocable; sensitive-class data (cycle) requires an extra confirmation toggle to include in any export template that leaves the device.

---
---

## 21. Food, exercise, symptoms, medications, and issues logging

### 21.1 Logging doctrine
Repeat case ≤3 interactions (P8); every log editable/deletable with audit trail; retro-logging first-class (backdate picker on every flow); all flows work offline; every logged entity write-backs to platform stores where supported and toggled.

### 21.2 Food logging (full system)
- **Pathways:** database search (verified-first ranking, regional DBs); barcode; **photo AI** (multi-item detection → per-item confidence chips → correction UI); **describe** (free text/voice → parsed items; fast model for simple, capable model for complex — the report's Bevel pipeline pattern adopted); favorites/recents/meals ("my usual breakfast" one-tap); recipe builder (ingredients → per-serving math); quick-calories fallback (kcal-only entry for low-effort days — logged honestly as low-detail).
- **Data model:** FoodItem (canonical/branded/user) → Portion (unit conversions, density-aware) → MealEntry (items[], meal type, time, tags, confidence, method) → daily aggregates.
- **Corrections loop:** every AI correction stored as personal alias ("my 'toast' = 2 slices whole wheat + butter"), improving future parses locally.
- **Quality honesty:** AI-estimated portions carry ± ranges; daily kcal shows an uncertainty hint in power mode.
- **Auto-tags:** late-meal, high-added-sugar, keto-day, fasting-window-break (Bevel parity) — all visible-rubric.
- **Micros:** platform-standard vitamin/mineral set; dot-matrix visualization (Bevel parity); "top gaps this week" insight.
- **Hydration/caffeine/alcohol:** preset-volume quick logs; caffeine cutoff-time insight hook; alcohol units with sleep-covariate wiring.

### 21.3 Exercise logging
- **Auto:** platform/vendor workout import (dedup vs manual).
- **Manual quick-add:** type/duration/intensity (RPE) — 3 taps.
- **Strength Builder parity+:** template CRUD; session runner (per-set weight/reps steppers, plate math, rest timer, superset grouping, exercise swap mid-session — Bevel's Live-Sync-era feature per report); exercise library (canonical + custom, muscle-group mapped); progression views (e1RM, volume, heaviest, total reps — Bevel floor); watch companion set-logger (Phase 2).
- **Cardio detail:** distance/pace/splits when source provides; zone-time bars; HRR capture post-session.
- **Custom activities:** user-named types with MET estimate mapping (honest energy uncertainty).

### 21.4 Symptom logging
Canonical dictionary (curated ~200 common symptoms, localized) + user customs mapped-or-freeform; recents chips; severity (3-level casual / 0–10 power); onset/duration/ongoing flag; body-map (optional); trigger tags (foods, stress, weather, meds change, custom); notes+photo attachment. Recurrence engine groups episodes ("migraine #7 this quarter"). Vocabulary chaos guard: fuzzy-match suggestions at entry ("did you mean 'light-headed' (used 4×)?"), merge tool in symptom hub.

### 21.5 Medication & supplement logging
Entities: Medication (name via localized drug/ingredient list + free-form, strength, form, route) → Regimen (schedule patterns incl. PRN, cycling, tapers; start/end) → AdherenceEvent (taken/late/skipped+reason). Features: due strip on Today; take-all tap; reminders through the throttling engine with quiet hours; **regimen-change markers auto-annotate all charts**; refill-count nudge (optional); privacy: meds excluded from share-cards by default. Boundary: no dosing advice, no interaction checking in v1 (a future licensed-database decision, flagged in §45 with compliance review) — the app states this boundary plainly in the meds hub.

### 21.6 Conditions / health issues repository
User-declared Condition entities: label (localized vocabulary + custom), onset, status (active/resolved/episodic), linked meds/symptoms/metrics/notes. Per-condition mini-dashboard + report shortcut ("everything about my migraines, last 6 months"). BADAN never infers or suggests conditions.

### 21.7 Journal & subjective
Mood/energy sliders (5-second check-in), free-text notes with tags/attachments, water goal (Bevel Journal parity), gratitude/free prompts optional and off by default (no wellness-app cheese by default).

### 21.8 Subjective↔objective wiring
Every subjective entry is a first-class series for correlations (mood vs sleep; soreness vs muscular load); the perceived-vs-scored gap metric feeds calibration honesty (§18.4, §22.5).

---
---

## 22. Analytics and longitudinal intelligence

### 22.1 The intelligence stack
```
Baselines → Deviations → Trends → Patterns/Correlations → Experiments → Narratives
```
Each layer consumes the one below; every output carries evidence pointers + confidence.

### 22.2 Baseline engine
Per-metric rolling baselines (metric-appropriate windows: 14d vitals, 28d load, 60–90d labs-adjacent), robust statistics (median/MAD default — outlier-resistant), **covariate conditioning**: cycle phase, statuses (sick/travel excluded or separately banded), seasonality guard (winter RHR drift handled by seasonal-window comparison in power views). Provisional flag until coverage thresholds met; backfill-seeded from history (P4).

### 22.3 Deviation & anomaly layer
Daily z-scores vs conditioned baselines; multi-metric composite deviations ("3 vitals off together" → higher salience than any single one); artifact filters run first (a 40-minute HR spike from a compression artifact must not become an "anomaly"). Anomaly outputs are *calm by design*: bundled into the narrative unless composite severity + persistence cross thresholds (then a single respectful notification).

### 22.4 Trend layer
Rolling deltas (3/7/14/30/90d tables — Bevel parity everywhere); slope significance vs noise ("meaningful change" flag uses effect size, not just direction — the report's Trends-Analysis "distinguish meaningful long-term changes from nightly noise" requirement, made explicit); typical-range bands on all charts (Bevel parity); >1-year horizons with decimation-preserving-extremes rendering.

### 22.5 Explainable scores (Score Anatomy)
Every score = documented model (weighted inputs → transforms → output) + per-day input snapshot stored → Anatomy sheet renders contributions ("HRV −14% vs your phase-adjusted baseline pulled Readiness down ~9 points"). Perceived-gap calibration: when user marks "doesn't match how I feel," the gap is tracked per input pattern and surfaces in Anatomy ("you often feel better than this score after short-but-deep sleep").

### 22.6 Comparisons: self-first, cohort-optional
Default: self-referenced everything. Optional cohort context (Phase 3, opt-in, on aggregated anonymized bands): "your HRV is typical for your age band" — never ranked, never leaderboarded, always dismissible-permanently.

### 22.7 Correlation Lab
User picks metric pairs (or accepts suggested candidates); engine computes lagged associations with: minimum-n gating (won't run under ~20 paired observations — shows "keep logging, 8 more days"), multiple-comparison correction when scanning many pairs, confounder warnings (both correlate with weekends?), and mandatory phrasing: association-strength words ("weak/moderate/strong association"), never causal claims. Output cards are saveable to reports and revisitable as data grows.

### 22.8 Experiments engine
Structured n-of-1: define variable (habit tag/med-change/bedtime shift), baseline window auto-selected, minimum duration enforced, interim peeking discouraged (soft lock with explanation), result card with effect estimate + confidence language + "what would make this more reliable." This operationalizes the report's counterfactual-suggestion ambition without pseudo-science.

### 22.9 Reporting cadence
Daily narrative (sentence→paragraph by verbosity) · Weekly digest (what changed, one focus, adherence recap) · Monthly (trend confirmations, experiment results, biomarker updates) · **Year in Body** (story-format: totals, records, turning points, "your body's year in 12 charts") — a retention landmark and share-card generator.

---
---

## 23. AI and interpretation layer

### 23.1 Role definition
The AI is a **data analyst and translator, never an oracle or clinician**: it explains BADAN's deterministic outputs, answers questions grounded in the user's data, drafts narratives, and assists logging. Scores and stats come from the deterministic engine (§22); the LLM renders and converses about them. This division is architectural, not stylistic — the LLM cannot emit a number the engine didn't compute.

### 23.2 Capability ladder (mirrors report Tiers 1–3)
- **Tier 1 (launch):** template-based narrative generation with LLM smoothing (structured daily-context JSON → grounded prose); Ask-BADAN over summarized data windows; AI food parsing. Cloud LLM (vendor with zero-retention agreement) with strict data minimization (§23.5).
- **Tier 2 (Phase 2–3):** memory layer (user-visible/editable: preferences, goals, known patterns, tone); proactive check-ins; RAG over curated sleep/fitness literature for citation-grounded education answers (PH-LLM-informed approach per report); chart generation from questions; fine-tuned small model for domain tone/accuracy.
- **Tier 3 (Phase 3–4):** on-device inference option (Apple Foundation Models / Gemma-class via LiteRT) powering narratives + basic Q&A fully locally — the "nothing leaves the phone" marketing truth the report identifies as unowned territory; cloud remains opt-in for deep analysis.

### 23.3 Grounding architecture
Context builder assembles: today's engine outputs + relevant window summaries (pre-aggregated, token-efficient — the report's Terra-AI-interface lesson: never inject raw sensor JSON) + user memory + locale/tone policy → prompt template per insight type → post-generation **verifier pass** (numeric claims checked against engine values; unverifiable sentences dropped) → render with "data used" footnote.

### 23.4 On-device vs cloud split

| Workload | Default | Rationale |
|---|---|---|
| Food photo/description parse | Cloud (Tier 1) → hybrid | accuracy-critical; on-device fallback for simple items later |
| Daily narrative | Templated+LLM cloud → on-device (Tier 3) | daily cost + privacy showcase |
| Ask-BADAN quick answers | Cloud minimal-context → on-device option | latency + privacy |
| Deep analysis / chart gen | Cloud (Pro) | capability-bound |
| Memory storage | On-device + E2E sync | it's user data |
| Cycle-related AI context | Excluded from cloud by default; on-device only unless explicit opt-in | §28.7 |

### 23.5 Privacy engineering for AI
Minimum-necessary context per query type; pseudonymous sessions (no account identifiers to LLM vendor); no training on user data, contractual + stated; per-request "what was sent" log in Privacy dashboard (power users can open exact payload summaries); global "AI off" switch that removes all AI surfaces cleanly (deterministic narratives remain — the templates work un-smoothed).

### 23.6 Proactive system (check-ins)
User-configured cadences + AI-suggested moments gated by the notification decision engine; every proactive message must cite a concrete trigger ("HRV 7-day trend −12%") and offer an action (view evidence / adjust / snooze topic). Anti-annoyance: topic-level snooze is permanent-until-reenabled, honored forever.

### 23.7 Insight quality system
Insight templates registry (each: trigger conditions, evidence requirements, cooldown, phrasing variants, depth variants); deduplication memory (no repeats within cooldown); usefulness feedback (👍/👎 trains per-user template weights); global kill-switch per template (ops can retire a misfiring insight class in minutes).

### 23.8 Tone & personalization
Tone matrix: length (concise/standard/detailed) × warmth (warm/neutral) × language (full localization — narratives generated in UI language, not translated post-hoc). Reading-level target: plain language (≈B1) for casual; technical vocabulary allowed in power mode. The user's name never overused; no fake enthusiasm.

### 23.9 Wording guardrails (the non-negotiables)
- Banned frames: diagnosis ("you may have…"), treatment ("increase your dose," "take X"), fear ("dangerous," "alarming"), moral judgment ("you failed," "bad day").
- Required frames: possibility + evidence ("often associated with…", "in your data, X tends to follow Y"); confidence qualifiers scaled to data quality; status-aware phrasing (Injured/Sick suppress performance-critique templates — the Karim safeguard); persistent-deviation language routes to neutral "worth discussing with a professional if it persists" only via a reviewed template with strict triggers.
- Enforcement: phrasing linter on template registry + verifier-pass regexes + human review for any template touching symptoms/meds/glucose/cycle; red-team suite in CI (adversarial prompts attempting to elicit medical advice must fail).

### 23.10 Trust affordances
"Why am I seeing this" on every insight (trigger + evidence + template id in power mode); "AI-generated" labeling; correction loop ("that's wrong" → logged, cited data shown for user verification); model/version stamp in power mode.

---
---

## 24. Notifications, widgets, watch, and ambient experiences

### 24.1 Ambient philosophy
L0 surfaces deliver the daily contract without opening the app. Every ambient surface answers one question, deep-links to its evidence, and respects the throttling engine. Ambient ≠ noisy: default footprint is deliberately tiny.

### 24.2 iOS widget suite (WidgetKit)
Small: single ring (choice) / One True Sentence / meds-due count / water quick-log (interactive). Medium: tri-ring + sentence / Health Monitor mini-grid / sleep last-night card / glucose strip (if enabled). Large: Today digest / weekly trend snapshot. Lock Screen: circular ring, inline sentence-fragment, rectangular vitals. StandBy: bedside sleep/wind-down face. Control Center control (log water / start workout note). All widgets configurable (metric choice, depth) and privacy-aware (sensitive metrics require explicit widget opt-in; redaction option when Face ID not passed).

### 24.3 Live Activities (iOS)
Workout-in-progress (zones + strain accrual, from watch/phone session) · wind-down countdown into bedtime (Dynamic Island: moon + minutes) · CGM meal-response window (2h post-logged-meal live strip; wellness framing, opt-in) · export/report generation progress for large jobs.

### 24.4 watchOS app
Glanceable pages: Readiness ring + driver word → last night mini → today strain/zones → meds due (take from wrist) → quick logs (water/caffeine/mood/symptom recents). Complications: rings, readiness number, meds due, water. Strength set-logger companion (Phase 2): rep/weight entry on wrist, rest timer with haptics. Background: watch-side HR/zone display during workouts uses platform workout session APIs; no custom sensor polling (battery discipline).

### 24.5 Android ambient suite
Home-screen widgets (Glance): parity set with iOS smalls/mediums + interactive water/meds actions. Wear OS: tiles (readiness, last night, meds due), complications, quick-log app; ongoing-activity chip for workout/wind-down parity with Live Activities where platform allows. Quick Settings tile: water log. App shortcuts (long-press icon): top 4 log actions.

### 24.6 Notification taxonomy

| Class | Examples | Default | Channel rules |
|---|---|---|---|
| Daily anchors | Morning narrative; weekly digest | ON (time-configurable) | Never more than one anchor/day |
| Care tasks | Med reminders; refill nudge | ON when meds exist | Quiet-hours aware; escalate once max |
| State changes | "Recovery unusually low + explanation"; sensor disconnected; sync broken | Selective ON | Composite-severity gated (§22.3) |
| Encouragement | Streak milestones; goal proximity | OFF by default | Opt-in only |
| Coach | Check-ins; insight follow-ups | Configured cadence | Topic-snooze honored |
| System | Export ready; import finished; permission expiring | ON | Transactional, minimal |

### 24.7 Smart timing
Anchors delivered relative to wake detection (post-wake narrative beats fixed 7:00 when the user slept in); bedtime-related nudges relative to target bedtime; workout summaries within minutes of session end; no notification within N minutes after the user was just *in* the app viewing that content.

### 24.8 The anti-annoyance engine (notification decision layer)
Every candidate notification passes: value test (new information? actionable?) → dedup (same insight recently?) → budget (per-day cap by class; global cap ~3 default) → quiet hours/prayer-time-configurable windows → channel routing (push vs in-app-only vs digest-fold). Weekly self-audit surface: "BADAN sent you 9 notifications this week; tune here." Opt-outs are one-tap from every notification (long-press → "fewer like this" maps to topic-snooze). KPI: notification-driven disable rate < 2%/month.

---
---

## 25. Visual design system

### 25.1 Design language: "Warm Instrument"
A precision instrument with human warmth: dark-first but fully dual-theme, generous radii, tactile cards, evocative-but-quiet artwork, data-forward typography. Bevel's observed strengths (dark elegance, pillar accents, scenic pillar heroes, band-charts) are adopted as principles and re-expressed originally — no visual cloning.

### 25.2 Color system
- **Neutral core:** true-dark surface stack (#0C0E11 base → elevated #16191E → #1E2228) and light equivalents (#FAFAF8 → #FFFFFF cards) — full light theme at launch (Bevel gap; accessibility + outdoor legibility + user preference data all demand it).
- **Pillar accents:** Sleep indigo, Readiness green-lime, Strain amber, Nutrition coral, Glucose teal, Biology violet, Cycle rose, Meds cyan, Symptoms ochre. Each with dark/light variants + colorblind-safe alternates (palette validated with CVD simulation; semantic state never encoded by hue alone — always icon/label redundant).
- **State semantics:** in-band green, out-of-band amber, informational blue, critical-rare red (reserved: almost never used, preserving its power). Deviation direction uses arrows+text, not red/green moralizing (a *low* RHR isn't "good" universally).
- **Arabic/RTL variants:** accent usage identical; artwork mirrored where directional.

### 25.3 Typography
iOS: SF Pro (+ SF Arabic); Android: platform sans (+ Noto Sans Arabic); numerics: tabular lining everywhere data lives; scale: hero numerals 40–48pt, section headers ~20pt bold, body 15–16pt, caption 12–13pt; Dynamic Type / font-scale support to XXL with layout-tested reflow (large-type preset for Huda archetype).

### 25.4 Artwork system: "Inner landscape"
Each pillar hero carries a subtly generative landscape whose palette/weather reflects state (calm dawn for good recovery; soft rain for low) — evocative, never alarmist, reduced-motion-aware, and disable-able (pure-data mode for the sterile-averse *and* the art-averse). This is BADAN's answer to Bevel's scenic heroes: same emotional job, original and state-aware execution.

### 25.5 Chart language (the grammar users learn once)
- **Band-line:** metric line over personal-normal band + dotted average pill (the workhorse — Bevel parity).
- **Rings:** scores only (never quantities), with driver word.
- **Vertical range pill:** today-vs-band position (Health Monitor tiles — Bevel parity).
- **Stacked bars:** compositions (stages, cardio focus, macros).
- **Ledger area:** cumulative banks (sleep debt) with surplus/deficit shading.
- **Diverging bar:** in-vs-out (net energy — Bevel parity).
- **Event strips:** meds adherence, symptoms occurrences, statuses.
- **Point+range:** labs vs reference ranges.
- **Radar:** muscle groups only (Bevel parity; capped at one use to avoid radar abuse).
- **Heat calendars:** activity/sleep consistency (Bevel parity + year view).
Rules: axes always available (tap-to-reveal in casual); glowing endpoint marks "now" (Bevel parity); annotations (statuses/meds/cycle) as a consistent layer; every chart exports as image with title/period/units baked in (share-safe).

### 25.6 Iconography & shape
Rounded-square metric glyph set (lungs/heart/waveform/droplet/thermometer/bed/flame/fork…) consistent across app, widgets, settings (Bevel-style settings squircles adopted); 20pt radius cards; 4pt spacing grid; elevation via subtle borders in dark, shadow in light.

### 25.7 Motion philosophy
Purposeful only: ring fills on appear (300ms, once), sheet springs, chart scrub with haptic ticks at band edges, number roll on value change; no idle loops, no parallax excess; Reduce Motion honored globally.

### 25.8 Anti-boredom / anti-intimidation balance
Anti-boredom: inner-landscape art, milestone moments (opt-in), seasonal app icons (Bevel parity), narrative voice with personality within tone policy. Anti-intimidation: progressive axis reveal, plain-word chips before numbers, education one tap away, empty states that show *future shape* not absence, and the depth dial governing density everywhere.

### 25.9 RTL & localization rendering
Full mirroring (navigation, chevrons, layout); charts: time axes remain LTR (convention), surrounding chrome mirrors; Arabic numerals per locale preference (Eastern/Western digits toggle); date formats/week-start localized; string expansion tested (German +30%) and Arabic script metrics in all components.

### 25.10 Accessibility
WCAG AA contrast both themes; VoiceOver/TalkBack: charts expose summary + data-point navigation ("audio graph" on iOS); touch targets ≥44pt; colorblind-safe simulations in CI screenshots; captions/transcripts for any future audio.

---
---

## 26. Interaction design system

### 26.1 Component behavior contracts
Every card: tap = detail, long-press = context menu (pin/hide/explain/export/ask), consistent everywhere (learn once). Every chart: scrub = value readout tooltip with date, pinch = period zoom (power), two-finger tap = annotation toggle. Every list: pull-refresh = sync with state toast (Bevel parity), swipe on log rows = edit/delete.

### 26.2 Input mechanics
Steppers with press-and-hold acceleration (weights, portions); unit-guarded keypads (BP validates systolic>diastolic; glucose range sanity by unit); sliders with haptic detents at meaningful points (severity, RPE); voice dictation on all text fields; time pickers default to "now" with one-tap backdating chips (−1h, this morning, yesterday).

### 26.3 Progressive disclosure patterns
Chips → sheets → pushes (quick-look sheet expandable to full push — one motion); "More" rows collapse advanced blocks; first-3-visits helper labels then auto-retire; density toggle per table (compact/comfortable) remembered per surface.

### 26.4 Feedback & confirmation
Optimistic UI on logs (instant visible entry + background write, undo snackbar 5s); destructive actions: confirm with consequence statement ("deletes 34 entries; export first?"); sync/processing states always visible somewhere consistent (status sheet), never mystery spinners.

### 26.5 Error interaction
Inline recoverable errors (field-level); banner-level for source issues with one-tap fix path; error IDs surfaced for support without stack traces; never blame language ("we couldn't read…" not "you failed to…").

### 26.6 Policy-aware components
Every display component accepts the presentation policy (depth, labels, density, annotations) — the §18.5 mechanism made concrete: one component library, two altitudes, zero forks.

---
---

## 27. Learning curve and education system

### 27.1 Ramp architecture
Three ramps, all optional, all resumable: **Orientation** (first-run: 4-page pillar stories — Bevel Getting-Started parity: each page teaches *what it is, how to interpret, how it's calculated*); **Deepening** (triggered micro-lessons at feature-first-touch: first band-chart → 15-second band explainer overlay; first lab entry → reference-range primer); **Mastery** (library: algorithm pages, data-quality guides, methodology changelog — the power curriculum).

### 27.2 The "explain this" system
Universal (i) affordances: metric definitions (Bevel-footer quality bar: concrete, physiological, specific — e.g., sampling cadence and known device offsets); chart explainers; **score anatomy** as the deepest layer; "explain this to me" AI action rephrases any screen conversationally at chosen depth.

### 27.3 Glossary & terminology bridge
Full glossary (every ontology term, localized, cross-linked); casual↔precise label bridging shown contextually during the user's first weeks (§17.2); search reaches glossary entries.

### 27.4 Just-in-time education triggers
Calibration status ("why numbers wobble early"); first out-of-band reading ("what 'above your normal' means — and what it doesn't"); first cycle-phase band shift; first AI insight ("how BADAN generates these"); device-added ("what your Oura adds beyond your Watch"). Each ≤20 seconds, dismiss-forever available, never blocking.

### 27.5 Algorithm transparency pages
Per derived metric: inputs, method summary (plain + technical tabs), version history with change notes, known limitations, references. This is Bevel's Calculations-explainer instinct industrialized — and the antidote to the report's #1 churn driver.

### 27.6 Education content ops
All content in a localized CMS (versioned, reviewable, updatable without app release); reading-level linting; clinical-claims review checklist on every article; per-article usefulness telemetry (privacy-safe counts).

---
---

## 28. Privacy, consent, trust, and responsible UX

### 28.1 Posture
Privacy is a product feature with UI, not a policy PDF: local-first architecture, minimum collection, explicit purpose per data class, no third-party data sale/advertising ever, verifiable user control (export/delete/inspect), and marketing claims that engineering can prove.

### 28.2 Data classes & handling

| Class | Examples | Storage | Cloud default | AI default |
|---|---|---|---|---|
| Standard health | steps, sleep, HR, workouts | local + optional E2E sync | opt-in sync | summarized context allowed |
| Sensitive-plus | cycle, symptoms, meds, conditions, glucose | local, sensitive store | opt-in sync (separately consented) | excluded from cloud AI unless explicit opt-in; on-device allowed |
| Identity | account (optional), email | cloud if account | — | never |
| Derived | scores, insights | local + sync | follows source class | evidence-linked |
| Telemetry | product analytics | §36.2 privacy-preserving | opt-out (or opt-in per region) | n/a |

### 28.3 Consent model
Layered, granular, revocable: platform permissions (staged bundles, §12.6) + BADAN-level purposes (sync, AI processing, analytics — each separate, none bundled with ToS acceptance) + sensitive-class gates (cycle/meds cloud participation individually consented). Consent center (S-101) shows grant dates, last-use timestamps, and one-tap revocation with consequence preview. Consent versioning: purpose changes require re-consent, never silent expansion.

### 28.4 Trust-building UX
Privacy dashboard with live "what left this device" counters; per-AI-request payload visibility (§23.5); "no account needed" honored prominently; deletion that states its scope and confirms completion; security page (encryption at rest/in transit, E2E sync design summary); no growth hooks inside privacy surfaces (no "invite friends" on the consent screen — ever).

### 28.5 Local-only mode
First-class configuration: no account, no cloud, on-device AI tier only, local encrypted backups (user-exported files), full feature set minus multi-device sync/cloud-AI depth — and the settings screen says exactly that tradeoff.

### 28.6 Responsible-UX guardrails
Non-diagnostic wording enforcement (§23.9); anxiety-aware design (gentle mode, score-hiding, calm anomaly bundling); no dark patterns (no confirm-shaming, no fake urgency, no obfuscated numbers as paywall bait); age gating (16+ general, 18+ for Bio-Age-class composites, mirroring Bevel's observed gate; no child accounts in scope).

### 28.7 Reproductive-data special handling
Cycle data: sensitive-plus class, on-device by default, excluded from cloud AI by default, excluded from exports unless explicitly toggled per export, purge-on-module-disable option (delete vs retain choice made by user), and regional threat-model documentation maintained (jurisdictional data-demand risk assessed in §29).

---
---

## 29. Compliance and regulatory-aware architecture

### 29.1 Regulatory stance
BADAN ships as a **general wellness product**: tracking, logging, interpretation-for-awareness; no diagnosis, treatment, or disease-management claims. Feature review board (product+legal) gates any feature/copy that could cross into medical-device territory (per FDA general-wellness guidance logic, EU MDR intended-purpose logic). The architecture, however, is built *audit-ready* so stricter regimes are adoptable later without rewrite.

### 29.2 Jurisdiction map (launch-relevant)

| Regime | Applies | Key obligations BADAN meets by design |
|---|---|---|
| GDPR (EU/UK) | any EU/UK users | Art. 9 explicit consent for health data; minimization; erasure; portability (Export Center *is* Art. 20 compliance); DPIA maintained; EU data residency option |
| HIPAA (US) | **not** by default (no covered-entity flows) | architecture holds HIPAA-grade controls anyway (encryption, audit logs, access controls) so future clinical partnerships don't require re-platforming |
| GCC frameworks (Oman PDPL, KSA PDPL, UAE) | launch markets | consent-based processing, residency options, Arabic-language notices |
| App-store health rules | both stores | health-data usage declarations, no ads from health data, sensitive-data policies |

### 29.3 Audit-ready architecture ingredients
Field-level encryption for sensitive classes; audit logging on all cloud data access (admin access near-nil by design — E2E sync means the server usually *can't* read); data-residency-aware storage partitioning; retention policies per class with automated enforcement; vendor register with DPAs (LLM, broker, analytics); incident-response runbook with notification timelines; records-of-processing maintained from day one.

### 29.4 Claims & copy governance
Marketing/store/App-UI copy passes the same wording linter class as AI output (no cure/treat/diagnose verbs); science pages cite sources and state consumer-device accuracy limits; "not a medical device" placements standardized (onboarding, reports, CGM surfaces) without becoming wallpaper (specific, contextual disclaimers beat blanket ones).

### 29.5 Future-stricter readiness
If/when clinical features arrive (§45): FHIR module isolated behind its own consent + storage domain; BAA-capable infrastructure list pre-identified (the report's AWS/GCP/Azure health options); QMS-lite documentation habits (design history, risk logs) started early on scoring algorithms so a future regulated module inherits provenance, not chaos.

---
---

## 30. Data architecture and domain modeling

### 30.1 Canonical entity map

```
UserProfile ─┬─ SourceConnection (platform|vendor|broker|import) ── SourceDevice
             ├─ MetricDefinition (registry; ~350 seeded)          ── AlgorithmVersion
             ├─ Sample (instant)            ┐
             ├─ IntervalRecord (aggregate)  ├─ all carry Provenance + QualityFlags
             ├─ Session (sleep|workout)     ┘      └─ suppressed_by (dedup pointer)
             ├─ EventRecord (meal|symptom|medAdherence|note|status|labResult|cycleEvent|measurement)
             ├─ DerivedValue (scores, baselines, deltas) ── InputManifest (snapshot refs)
             ├─ Baseline (metric × window × covariateContext)
             ├─ Insight (templateId, evidenceRefs[], feedback)
             ├─ Goal / ExperimentDefinition / MetricCollection
             ├─ MedicationRegimen ── AdherenceEvent
             ├─ Condition (links meds, symptoms, metrics)
             ├─ CustomizationProfile (layouts, presets, policies)
             └─ ConsentRecord / ExportJob / ImportBatch
```

Key modeling decisions: **Provenance is a struct on every record** (source chain, tz, measured-at vs recorded-at, ingestion path, batch id) — not a join table afterthought. **DerivedValue never overwrites**: recomputation appends with new AlgorithmVersion; UI reads latest, history remains (auditability + "your scores were re-derived" notices). **EventRecord is a closed union** with typed payloads (schema-versioned per type) — extensible without table sprawl. **Baselines are materialized entities** (queryable, exportable, explainable), keyed by covariate context (e.g., cycle phase) so band rendering is a lookup, not a runtime model run.

### 30.2 Timeseries strategy
On-device: SQLite with metric-partitioned tables + composite indexes (metric_id, start_ts), pre-computed daily/weekly aggregate tables for chart speed, decimation tiers (raw → minute → hour → day) for multi-year rendering. Cloud (sync tier): the server stores **encrypted opaque records** (E2E model) — server-side timeseries analytics do not exist by design; all computation is client-side. (This is the privacy-architecture fork: BADAN chooses client-compute + E2E over server-compute; consequences handled in §31.)

### 30.3 Event sourcing consideration (decided)
Full event sourcing rejected (complexity, mobile constraints); adopted instead: **append-only ingestion log** (raw payload retention, replayable per §11.3) + immutable derived-value versioning. This yields the reprocessing benefits without CQRS overhead.

### 30.4 Schema governance
Single schema source-of-truth (shared KMP models, §33); migration framework on both platforms with forward-only migrations + migration tests against seeded fixture DBs of every prior version; export schema decoupled (versioned mapping layer) so internal refactors don't break the published dictionary.

### 30.5 Identity & keys
ULIDs everywhere (sortable, offline-generatable); deterministic identity for platform-imported records (source UUID + type) enabling idempotent re-sync; import batches carry batch ids for one-tap undo of an entire import.

### 30.6 Deduplication engine (the hard piece, per report)
Pipeline stage with per-family strategies (§11.4), a decision journal (per merge: rule fired, records touched, reversible), tunable thresholds shipped server-side as config (fixable without release), and a **conformance suite**: fixture library of real-world overlap cases (phone+watch steps, double sleep sources, Garmin+HK workout dupes, import-over-live overlaps) run in CI; accuracy regressions block release.

---
---

## 31. Backend architecture

### 31.1 Principle: the thin, blind backend
Because computation is client-side and sync is E2E-encrypted, the backend is deliberately small: auth, encrypted-blob sync, vendor-integration webhooks, food-database proxy, AI gateway, content CMS, push, billing, telemetry intake. It cannot read health data. This shrinks compliance surface (GDPR/HIPAA-grade posture cheaply), cost, and breach blast-radius — the structural moat behind the privacy marketing.

### 31.2 Services

| Service | Responsibility | Notes |
|---|---|---|
| Identity | optional accounts, OAuth, device keys | account-less local mode never touches it |
| Sync | E2E blob store + vector clocks / change feeds | §34; zero-knowledge |
| Integration hub | vendor OAuth flows, webhook receipt (Garmin/Dexcom/broker), normalization to transport schema, delivery to device queue | health payloads pass through encrypted-at-rest, short-retention (delivered-then-deleted) |
| Food data proxy | provider abstraction (multi-DB), caching, regional routing | user queries pseudonymized |
| AI gateway | prompt assembly guardrails, vendor routing, zero-retention enforcement, cost metering | §23.5 payload logging hooks |
| Content CMS | education, insight templates, metric registry updates | versioned, staged rollout |
| Push | APNs/FCM routing of *triggers* (content rendered on device where possible — push payloads carry references, not health values) | privacy-in-transit |
| Billing | store-kit/play-billing server verification, entitlements | — |
| Telemetry | privacy-preserving analytics intake | §36 |

### 31.3 Stack (report-aligned)
FastAPI (Python) or Kotlin services; PostgreSQL (+ Timescale only for *service* metrics, not user health data); Redis queues; object storage for encrypted sync blobs; IaC from day one; regions: EU + GCC at launch (residency), US as demanded.

### 31.4 Integration-hub resilience
Webhook idempotency keys; replay buffers (7d) for missed deliveries; vendor-token refresh daemons with user-visible auth-health (S-60); rate-limit budgeting per vendor; contract tests against vendor sandboxes in CI; kill-switches per integration.

---
---

## 32. On-device architecture

### 32.1 Layered design (both platforms)

```
UI (SwiftUI / Compose)
ViewModels (per-screen, policy-aware)
Domain layer  ── scoring engine, baseline engine, insight engine, phrasing engine (shared KMP)
Data layer    ── repositories, SQLite (SQLDelight), ingestion pipeline, sync client (shared KMP)
Platform adapters ── HealthKit / Health Connect / notifications / widgets / files (native)
```

### 32.2 The ingestion daemon
iOS: HKObserverQuery + enableBackgroundDelivery per type; anchored queries for deltas; BGProcessingTask for nightly heavy recompute (baselines, insights) and BGAppRefresh for light top-ups. Android: Health Connect changes API polled via WorkManager periodic + expedited jobs; foreground service only during explicit long imports; OEM battery-exemption onboarding (documented per-manufacturer quirks — the §37.6 playbook).

### 32.3 Compute scheduling
Score recompute triggers: new-data events (debounced), day rollover (tz-aware), settings changes (explicit "recomputing…" state), algorithm updates (staged backfill recompute with progress). Heavy jobs chunked + resumable; thermal/battery-aware yielding.

### 32.4 On-device AI runtime (Tier 3 path)
iOS: Foundation Models framework / Core ML for the small-model tier; Android: LiteRT/MediaPipe GenAI with Gemma-class models; shared prompt/template layer in KMP; capability detection gates features (older devices gracefully fall back to templated narratives — never a worse *truth*, only plainer prose).

### 32.5 Storage & crypto
SQLCipher-encrypted DBs; iOS Data Protection classes / Android EncryptedFile+Keystore; key hierarchy: device key → sync key (user-held recovery phrase for E2E) → export encryption optional passphrase; sensitive-plus class in separate DB namespace (enables purge-on-disable, §28.7).

### 32.6 Performance & battery budgets (CI-enforced)
Cold start to Today < 400 ms (cached) / < 1.5 s (first-ever); chart render < 100 ms for 1-year decimated series; background battery < 2%/day attributable; DB size projection ~[50–150 MB]/multi-year heavy user with decimation tiers; memory ceilings for import jobs (streamed parsing, never whole-archive in memory).

---
---

## 33. Cross-platform mobile architecture

### 33.1 Options evaluated

| Option | Health-API depth | UI quality | Team velocity | Risk profile | Verdict |
|---|---|---|---|---|---|
| Fully native ×2 | Best | Best | Slowest (2× logic) | Logic drift between platforms | Rejected: drift kills parity promise |
| React Native | Bridged (community modules for HK/HC lag platform releases) | Good | Fast UI | Health-API lag + perf on big charts | Rejected for health-heavy core |
| Flutter | Bridged similarly | Good (own renderer) | Fast | Same health-API lag; non-native a11y/idiom cost | Rejected |
| **KMP: shared core + native UI (SwiftUI/Compose)** | Native adapters (day-one API access) | Native | Shared logic once | KMP iOS toolchain maturity (acceptable 2026) | **Chosen** |

Rationale: BADAN's competitive core is *logic* (ingestion, dedup, scoring, insights, phrasing, sync) — exactly what KMP shares — while its trust surface is *native platform fidelity* (HealthKit/HC day-one, widgets, watch, accessibility, RTL) — exactly what native UI preserves. The report's own stack recommendation (SwiftUI + Kotlin/Compose) is upgraded with a shared-core layer to prevent the two-brains problem.

### 33.2 Repository structure

```
/core        (KMP: domain models, ontology registry, scoring, baselines, insights,
              phrasing templates, dedup, sync client, export engine, SQLDelight schemas)
/adapters    (KMP expect/actual: health stores, files, crypto, notifications)
/ios         (SwiftUI app, WidgetKit, watchOS, Live Activities, HK adapter impl)
/android     (Compose app, Glance, Wear OS, HC adapter impl)
/backend     (services per §31)
/content     (education, templates, localization pipeline)
/tooling     (fixture DBs, dedup conformance suite, schema dictionary generator)
```

### 33.3 Module boundaries & contracts
Health adapters expose a platform-neutral `HealthStorePort` (typed reads/writes/observe) with capability descriptors (so core logic can query "does this platform have medication types?" — driving the §12 fallbacks programmatically); scoring engine consumes only canonical records (never platform types); UI consumes ViewState objects (policy-applied) — enforcing §26.6.

### 33.4 Where divergence is beneficial
Ambient surfaces (§24), settings idioms, paywall presentation per store rules, haptics, and platform-exclusive delights (Shortcuts vs App Actions). Divergence forbidden: metric math, phrasing truth, export output, dedup behavior (byte-identical fixtures across platforms in CI).

### 33.5 Testing strategy
Core: pure-Kotlin unit tests (scoring golden files; dedup conformance; phrasing linter; export schema snapshots). Adapters: contract tests against HK/HC test stores + recorded fixtures. UI: snapshot tests both themes × RTL × 3 type sizes; critical-flow UI tests (log food, view metric, export). Cross-platform parity suite: same fixture DB → assert identical scores/exports on both apps. Beta cohort with device-zoo matrix (Samsung/Pixel/Xiaomi background-sync reality testing).

---
---

## 34. Offline, sync, and conflict-resolution strategy

### 34.1 Local-first doctrine
The device DB is the source of truth; cloud is a replication target. Everything works offline (viewing, logging, scoring on existing data); sync is convergence, not gating.

### 34.2 Sync engine design
Per-entity change feeds with logical clocks (device id + lamport counter); E2E encryption (server sees opaque payloads + minimal routing metadata); chunked/resumable transfer for large histories; attachment blobs content-addressed. Selective sync: sensitive-plus classes sync only with their separate consent (§28.2).

### 34.3 Conflict resolution matrix

| Data type | Policy |
|---|---|
| Platform-imported samples | No conflicts possible (deterministic ids; re-sync idempotent) |
| Manual logs edited on two devices | Last-writer-wins per field + conflict copy retained in audit ("edited on two devices" notice if material) |
| Customization profile | LWW per key (layout conflicts are benign) |
| Derived values | Never synced as truth — recomputed locally from synced inputs (guarantees consistency + saves bandwidth) |
| Deletions | Tombstones with grace window; import-batch undo respects sync |

### 34.4 Sync UX
Status surface (S-02) with per-source and cloud-sync freshness; conflict notices rare and human ("kept both versions of your note from Tuesday"); "restore from sync" recovery flow (new device: full-history hydration with progress + immediate-usability ordering — recent data first).

### 34.5 Offline edge specifics
Notifications scheduled locally (anchors fire without network); AI features queue or degrade to templates offline (labeled); exports generate locally always (cloud never required for export — ownership principle made technical).

---
---

## 35. Search, filtering, and query experience

### 35.1 Global search (pull-down anywhere / search tab affordance)
Indexes: metrics (names, synonyms, casual+precise labels, localized), foods (personal + DB via proxy), symptoms/meds/conditions (incl. user customs), settings screens, education/glossary, insights history, notes full-text. Result grouping by type with direct deep-links; recent-searches; typo tolerance; Arabic/English cross-script matching (searching "hrv" in Arabic UI still hits).

### 35.2 Structured filtering grammar
Consistent filter chips across list surfaces: date range · pillar · source · tag · status-overlap · has-data/out-of-band (registry) · severity (symptoms) · meal type (food). Saved filters as named views (power) usable in Timeline, registry, and export scopes — one grammar, three payoffs.

### 35.3 Natural-language query path
Ask-BADAN handles question-shaped queries ("worst sleep weeks this year," "show HRV vs alcohol") → grounded answer + generated chart (Pro) + "open as filter" handoff into the structured system (the NL→structured bridge keeps trust inspectable).

### 35.4 Query performance
Local FTS5 indexes; aggregate tables for range queries; search-as-you-type < 50 ms on-device targets; food-DB remote search debounced with cached personal items instant-first.

---
---

## 36. Observability, analytics, and experimentation

### 36.1 Product analytics event schema (privacy-preserving)
Namespaced events with typed properties; **no health values in analytics** (only feature-usage shapes: e.g., `metric_detail_viewed {metric_family, period, depth_mode}` — family, never value). Core funnels: activation (install → connect → first-insight → D1 return), logging adoption (first food/symptom/med), depth migration (casual→power signals), export usage, AI engagement, notification health (sent→open→disable), module adoption/abandonment (edit-layout analytics: added/removed cards — mirrors learning from Bevel's Edit-Home pattern), digest readership, paywall funnel (view→trial→convert→retain).

### 36.2 Privacy engineering for telemetry
Opt-out prominently (opt-in where regionally required); pseudonymous ids rotated; on-device pre-aggregation where feasible; no third-party ad-tech SDKs ever; public analytics disclosure page listing every event (radical but cheap trust — consistent with brand).

### 36.3 Experimentation
Feature-flag platform with staged rollouts + kill-switches (§9.8); A/B limited to non-truth surfaces (onboarding order, education formats, digest layouts) — **never** experiment on scores, phrasing truthfulness, or safety wording; guardrail metrics (uninstall, notification-disable, support tickets) on every experiment; local-only users excluded from experiments requiring telemetry (they get stable defaults).

### 36.4 Quality observability
Crash/ANR (Sentry-class); sync-health dashboards (delivery latency, failure rates per vendor); dedup-accuracy sampling (opt-in diagnostic reports); score-distribution drift monitors (an algorithm change shifting population score distributions triggers review); AI cost/latency/verifier-rejection dashboards; on-device perf beacons against §32.6 budgets.

### 36.5 Segmentation for product learning
Behavioral segments (passive-glancer, logger, analyst, exporter) computed privacy-safely; per-segment retention curves steer roadmap (e.g., if exporters retain +X%, invest §20 further — instrumentation designed to test this blueprint's own bets).

---
---

## 37. Failure modes, edge cases, and resilience planning

The giant inventory. Format: **Case → Detection → System behavior → User experience.**

### 37.1 Data absence & gaps
1. No wearable at all → source detection → manual-mode product (subjective check-ins + phone steps + logging value) → Today hero variant, never "connect a device to start."
2. Wearable removed for days → staleness monitor → baselines pause (don't decay into nonsense) → "data paused since Tue" chip, resume seamlessly.
3. Single missing night → gap flag → scores marked partial-input → narrative says "no sleep data last night — charging?" not a zero score.
4. Sparse metric (labs with 1 point) → registry type check → point+range display, no trend claims → "one result; trends unlock at 2+."
5. Historical backfill partial (HC 30-day cap) → capability descriptor → archive-import suggestion → provisional-baseline note.

### 37.2 Data conflicts & duplication
6. Phone+watch step double-count → dedup family rule → primary-source election → power: decision visible in lineage.
7. Two sleep sources disagree (ring 7h10m vs watch 6h40m) → session-similarity merge with source ranking → chosen primary + "2 sources, view both" affordance → user can flip priority (remembered).
8. Duplicate workout (Garmin-direct + HK write) → signature match (start/duration/type) → merged with richer-source detail retained.
9. Import overlaps live history → batch idempotency + dedup pass → import report ("14,200 added, 3,890 duplicates skipped") + one-tap batch undo.
10. Manual entry contradicts device (user weight 82 kg, scale 84 kg same morning) → manual-wins policy + both retained → gentle "kept your entry as primary."
11. Same med logged twice in 5 min → adherence-window guard → auto-collapse with undo.

### 37.3 Permissions & platform states
12. Partial HK/HC grants → capability probe per type → modules degrade per denied-state matrix (§16.9) → module-level "enable sleep access" cards, no global nagging.
13. Permission revoked mid-life → read failure classified → data pauses, banner with deep-link to OS settings → history retained, clearly dated.
14. Background delivery unavailable (iOS Low Power, Android OEM kills) → sync-latency monitor → foreground-refresh mode messaging ("opens refresh your data") + OEM playbook link.
15. Health Connect app missing/outdated (older Androids) → availability check → guided install/update flow.
16. OS upgrade changes type behavior → platform canary tests in beta ring → adapter capability re-probe on OS change.

### 37.4 Time & timezone
17. Travel across zones → tz-aware records + travel-status suggestion → sleep attributed by local-night rules; charts annotate the shift; baselines use travel covariate.
18. DST transitions → canonical UTC + local render rules → 23/25-hour days handled in aggregates (test fixtures exist).
19. Manual log with wrong date (backdated typo) → soft validation ("this is 3 weeks ago — keep?") → easy re-date from detail.
20. Device clock skew from a stale wearable sync → future-timestamp guard → quarantine future samples with notice.

### 37.5 Physiological & sensor artifacts
21. HR spike artifact (strap compression) → physiologic-bounds + context filter → flagged, excluded from baselines, visible-but-marked in raw explorer.
22. CGM compression low (sleeping on sensor) → pattern classifier (rapid V-shape at night) → "possible sensor pressure artifact" tag, excluded from variability stats by default (toggleable).
23. Fever period → sick status (user or suggested) → recovery phrasing switches to illness mode; strain targets suspended.
24. Cycle-phase temp/HRV shifts → phase-conditioned baselines (the systemic fix) → no false alarms; phase note in Anatomy.
25. Nap vs main sleep misclassification → duration/time rules + user reclassify affordance → corrections remembered as source-pattern hints.

### 37.6 Integration & sync failures
26. Vendor token expiry → auth-health monitor → "reconnect Garmin" card with one-tap OAuth → no silent staleness (S-60 status).
27. Vendor API outage → webhook gap detection + replay buffer → catch-up on recovery; user sees honest per-source freshness.
28. Broker contract change/shutdown → adapter abstraction + exit plan (§13.3) → migration wizard to direct integrations.
29. Sync loop (bad clock/dupe cascade) → loop detectors (change-volume anomaly) + circuit breaker → sync pauses with support code rather than battery drain.
30. Corrupt local DB → integrity checks on open → auto-restore from local snapshot/cloud sync → worst case: re-hydrate from platform stores + imports (repository resilience story documented for users).

### 37.7 Logging & content chaos
31. Symptom vocabulary drift → fuzzy-match at entry + merge tool (§21.4).
32. Food AI wrong → correction UI + personal alias learning; kcal outlier guard ("this logs 4,800 kcal — confirm?").
33. Barcode not found → instant fallback to description path; user-created item enters personal DB (flagged unverified).
34. Medication name ambiguity (brand vs ingredient) → localized drug list with both; free-form allowed, mapped later.
35. Attachment bloat → size caps + storage meter in settings.

### 37.8 Interpretation & trust hazards
36. False-insight risk (spurious correlation) → §22.7 statistical gates + phrasing rules → weak signals never push-notified.
37. Alert fatigue → §24.8 budget engine + weekly self-audit.
38. Score whiplash after algorithm update → versioned recompute + in-app change note ("Recovery model v3: here's what changed and why") → optional side-by-side old/new for 2 weeks (power).
39. Chart misinterpretation (band read as target) → first-view micro-lesson + persistent (i) → copy tested ("your typical range," never "ideal range").
40. Export misunderstanding ("my HRV column differs from Oura's app") → data-dictionary notes on derivation + method column in export.

### 37.9 Human-situation edge cases
41. Onboarding abandonment mid-permissions → resumable onboarding state → next open continues, not restarts.
42. Long absence (90 days) → welcome-back mode: gentle re-baseline note, digest of the gap ("we kept collecting where permitted"), no guilt.
43. Power-user overload self-report → depth dial down-shift suggestion (only on explicit feedback signal).
44. Casual user hits power surface accidentally → "simpler view" escape hatch on dense screens (returns to summary layer).
45. Bereavement/pregnancy-loss-adjacent sensitivity → cycle module pause options with data choices; no cheery streak messaging in paused states (status-aware phrasing globally).
46. Device handed to someone else (shared phone reading) → optional app lock (FaceID/biometric) + discreet-widgets mode.

---
---

## 38. Growth, retention, and habit formation

### 38.1 Value-moment map (what we amplify)
VM1 first personalized insight (session 1 — backfill-powered); VM2 first "it explained me" moment (score matches feeling, or Anatomy explains mismatch); VM3 first pattern discovery (correlation/experiment result); VM4 first export/report used in real life (doctor visit, coach share); VM5 Year-in-Body. Retention loops are engineered around reaching VM1→VM2 in week 1, VM3 by month 2.

### 38.2 Habit loops (ethical by design)
Morning glance loop (anchor notification → 10-second value → done); evening light loop (wind-down cue, opt-in); weekly reflection loop (digest → one focus); logging loops only for users who chose logging goals (streaks opt-in, freeze-friendly, quiet). Explicitly rejected: variable-reward slot-machine patterns, guilt streaks, FOMO campaigns (§9.10).

### 38.3 Aha-moment engineering
Onboarding sequencing targets the report's calibration complaint: provisional-but-personal beats accurate-but-generic; first-week insight templates favor high-confidence, self-evident wins ("your sleep averages 47 min less on Sundays") to bank trust before subtler claims.

### 38.4 Referral & advocacy
Bevel-parity guest-pass referrals (30-day Pro gifts) minus gimmicks; advocacy artifacts: beautiful share-cards (privacy-safe defaults, watermark-light), public roadmap + feature-request portal (report: Bevel's roadmap loop drives investment feeling), transparent changelogs.

### 38.5 Resurrection & churn interception
Churn-signal model on usage shape (not health data); interception = value reminders (what accumulated), not discounts-first; lapsed-Pro users keep repository + individual interpretations forever (Law 1) — the "safe to leave, easy to return" strategy that differentiates from hardware-subscription hostage models (report: WHOOP resentment).

### 38.6 Community (Phase 3, carefully)
Opt-in circles (friends/small groups) with *effort-based* (not score-based) shared challenges (consistency, logging, movement minutes); no public leaderboards on physiology; moderated, wellness-toned; success metric: retention lift without notification-budget inflation.

---
---

## 39. Monetization and packaging strategy

### 39.1 Model: Free repository + Pro intelligence
- **Free (forever):** all ingestion & devices, all logging, unified timeline, every metric with personal bands + definitions + basic trends, daily narrative (concise), calendar, widgets, full export (CSV/JSON/PDF basics), local-only mode, unlimited history.
- **Pro (subscription):** deep AI (Ask-BADAN deep analysis, chart gen, check-ins, training-plan suggestions), Correlation Lab + Experiments, advanced reports (Composer templates, scheduled exports, personal API), biological-age full model + decomposition, cohort context, multi-device sync priority features (e.g., long-history instant hydration), power notification rules.
- Anchors: ~$59.99/yr | $7.99/mo (undercut Bevel's $99.99/$14.99 meaningfully; regional pricing tiers day one — GCC/MENA priced locally, not USD-translated).
- **Founding lifetime tier** (limited, launch): one-time purchase for early trust cohort (also answers the report's no-subscription-demand signal without starving the P&L).

### 39.2 Packaging rationale
The free tier is *complete-feeling* (the report's acquisition wedge vs WHOOP/Bevel paywalls) and every free surface demonstrates the paid layer honestly (real limited versions, no obfuscated numbers — §9.10). Conversion pressure comes from genuine depth appetite (analyst archetypes), not artificial ceilings. Trials: 14-day full-Pro (longer than Bevel's 7 — depth features need time to prove), no-payment-now framing (Bevel's observed reassurance pattern adopted).

### 39.3 Secondary revenue (later, principled)
B2B API licensing of the ingestion/normalization layer (Terra/Sahha model, report-endorsed) — only ever with per-user consent for any data involvement, and primarily as *technology* licensing; coaching-marketplace referral layer (verified human coaches reading user-shared reports) as a Phase-4 exploration with strict consent plumbing. Never: ads, data sale, sponsored insights.

### 39.4 Support & ops implications
Free tier support via self-serve + community; Pro gets priority channels; refund generosity policy (trust > margin at the edge); store-compliance review cadence for subscription UX (both stores' evolving rules).

---
---

## 40. Team structure and execution model

### 40.1 Phase-1 core team (~12–14)
1 product lead · 1 design lead + 1 product designer (design system + flows) · 1 content/UX-writer-localizer (EN/AR, phrasing templates) · 2 iOS (app + widgets/watch) · 2 Android (app + HC depth) · 2 KMP/core engineers (ontology, scoring, dedup, sync client) · 1 backend · 1 data scientist (baselines/scores/validation) · 1 QA (device zoo + conformance suites) · fractional: compliance counsel, security review, clinical-wellness advisor (wording review board).

### 40.2 Phase-2 additions (~+8)
+1 iOS +1 Android (ambient surfaces, strength builder) · +1 backend (integration hub) · +1 ML engineer (AI gateway, food AI, RAG) · +1 data engineer (import connectors, export engine hardening) · +1 designer (education/reports) · +1 support-ops · +1 growth analyst (privacy-safe).

### 40.3 Working model
Squads own **user promises**, not layers: Repository squad (ingestion/dedup/sources/export), Interpretation squad (scores/baselines/insights/AI), Experience squad (Today/pillars/logging/ambient), Trust squad (privacy/consent/compliance/perf) — each full-stack across core+platforms; design system + core owned as platform teams-within-squads. Definition of Done includes: both platforms, both themes, RTL, both depth policies, denied-state, empty-state, export impact, data-dictionary entry, trust collateral (§7 P12).

### 40.4 Rituals & quality gates
Weekly benchmark review (Bevel/WHOOP/Oura release watch — the report shows Bevel ships seasonally; assume moving target); monthly wording-guardrail audit; dedup-conformance and parity suites blocking CI; quarterly threat-model + privacy review; public changelog discipline.

---
---

## 41. Phased roadmap

### Phase 0 — Foundations (months 0–3)
Ontology registry + canonical schema; HK/HC adapters (read core set); ingestion pipeline + dedup v1 + provenance; SQLite/SQLDelight store; baseline engine v1; design system tokens + chart library spike; local-first shell (Today skeleton with real data); wording-guardrail framework; CI (parity, conformance, snapshots). **Exit:** internal build shows personalized Today from backfilled data on both platforms.

### Phase 1 — The honest daily companion (months 3–8) → public launch
Today + pillar pages (Sleep/Readiness/Strain) + universal metric detail + All-Metrics browser; calendar/Timeline; manual logging core (measurements, symptoms, meds, mood, water, workouts quick-add, food search/barcode); statuses; Health Monitor; daily narrative (templated+LLM) + weekly digest; notifications floor + widgets (core set); Export CSV/JSON + physician-basic PDF; Data Sources + Consent center + privacy dashboard + local-only mode; onboarding + education ramp v1; EN/AR launch; free tier complete + Pro trial scaffolding. **Exit criteria:** D30 retention ≥ target for wearable-connected cohort; VM1 in-session-1 ≥80%; crash-free ≥99.7%.

### Phase 2 — Depth & breadth (months 8–14)
Strength Builder + fitness suite (Cardio Load/Focus/HRR/Strain Performance/muscle radar — the full Bevel fitness floor); nutrition full system (photo/describe AI, recipes, micros, scores with visible rubric); CGM module; cycle engine as covariate + module; Sleep Bank + wind-down planner; broker integration wave (Garmin direct + Oura/Fitbit) + import connectors (Apple ZIP, takeouts, CSV mapper); watch apps + Live Activities/Wear tiles; Ask-BADAN grounded chat + check-ins + memory v1; Report Composer + scheduled exports; Biology pillar v1 (biomarker registry, manual labs, lab timeline). **Exit:** metric-coverage checklist vs §6/§10 floor = 100%.

### Phase 3 — Intelligence & ownership apex (months 14–22)
Correlation Lab + Experiments; Biological Age (explainable) + cohort-optional context; on-device AI tier; personal API + Parquet/SQLite exports; lab PDF import assist; advanced notification rules; community circles v1; additional languages wave; B2B API exploration. 

### Phase 4 — Horizon (22+)
Health-records/FHIR regional strategy; family/caregiver sharing (consent-first); voice summaries/coaching; clinician-share mode evaluation; research mode (§45); marketplace exploration.

Sequencing logic: trust infrastructure precedes intelligence features that depend on it; the Bevel floor completes in Phase 2 while BADAN-only differentiators (export, Android, local-first, meds/symptoms) ship in Phase 1 — differentiation arrives *before* parity, deliberately: launch narrative is "what nobody else does," Phase 2 closes "everything Bevel does."

---
---

## 42. Detailed backlog seed

Epic-level seed with sub-epics (acceptance-criteria style guidance in brackets). IDs stable for traceability.

**E-01 Ontology & registry** — E-01.1 metric registry schema + 350 seeds [every §10 family represented; localized names EN/AR; unit variants render correctly in 6 sample locales] · E-01.2 algorithm-version framework [derived values re-derivable; version visible in UI+export] · E-01.3 registry-driven UI binding [adding a registry metric yields browser row + detail screen with zero UI code].

**E-02 Platform ingestion** — E-02.1 HK read core [all §12.1–12.3 ✅ types; observer-driven deltas <15 min p50] · E-02.2 HC read core [parity; background-read fallback modes] · E-02.3 historical backfill [multi-year HK; progress UI; resumable] · E-02.4 write-back with toggles [self-source filtering proven by fixture] · E-02.5 staged permission bundles [denial matrix behaviors implemented per §16.9].

**E-03 Dedup & provenance** — E-03.1 family strategies + decision journal · E-03.2 conformance fixture suite [≥40 real-world cases; CI-blocking] · E-03.3 source priority + hide UI · E-03.4 lineage sheets.

**E-04 Scoring & baselines** — E-04.1 baseline engine (robust stats, covariate contexts) · E-04.2 sleep score + suite · E-04.3 readiness/recovery + Anatomy data capture · E-04.4 strain + zones · E-04.5 provisional/confidence flags end-to-end [visible in UI, export, narrative].

**E-05 Experience shell** — E-05.1 five-tab shell + policy-aware components · E-05.2 Today + edit-layout + presets · E-05.3 universal metric detail template · E-05.4 calendar + Timeline · E-05.5 All-Metrics browser.

**E-06 Logging core** — E-06.1 log hub + recents · E-06.2 measurements/mood/water · E-06.3 symptoms (dictionary, severity, merge tool) · E-06.4 medications (regimens, adherence, reminders, chart annotations) · E-06.5 workouts quick-add · E-06.6 food search/barcode + portions.

**E-07 Narrative & insights v1** — templates registry, verifier pass, dedup memory, feedback loop, tone settings, AR/EN generation parity.

**E-08 Trust surfaces** — consent center, privacy dashboard, local-only mode, app lock, telemetry opt-out, public analytics disclosure.

**E-09 Export v1** — CSV/JSON engines + manifest/dictionary generator [schema snapshot tests]; physician PDF; export history; delete-with-export flow.

**E-10 Notifications & widgets v1** — decision engine + budgets; anchors; core widget set both platforms; deep-link integrity tests.

**E-11 Fitness depth (P2)** — strength builder (templates/runner/progression), cardio load/focus/HRR/strain performance, muscle radar, fitness layout editing.

**E-12 Nutrition depth (P2)** — photo/describe AI + correction aliases; recipes; micros matrix; quality score + rubric page; net energy; write-back toggles.

**E-13 Glucose module (P2)** — store reads, day strip + overlays, derived trio (fasting/average/variability), meal-response binding (order-independent), artifact classifier.

**E-14 Cycle engine (P2)** — phase model, conditioned baselines, module UI, sensitive-class storage + consent gates, phrasing integration.

**E-15 Integrations wave (P2)** — Garmin direct; broker onboarding; Oura/Fitbit; import connectors (Apple ZIP, takeouts, CSV mapper with unit-guard UI); auth-health monitoring.

**E-16 Ambient (P2)** — watchOS/Wear apps, complications/tiles, Live Activities, StandBy, quick-log interactions.

**E-17 Coach v2 (P2)** — Ask-BADAN grounded chat [numeric-claim verifier ≥99% precision on eval set], check-ins, memory (visible/editable), education library CMS.

**E-18 Reports (P2)** — Composer + templates, digest system, Year-in-Body v1, share-cards.

**E-19 Analytics apex (P3)** — Correlation Lab [min-n gates, correction, phrasing rules], Experiments, cohort-optional layer.

**E-20 Bio Age (P3)** — model + validation memo, free band + Pro decomposition, 18+ gate, explanation surfaces.

**E-21 On-device AI (P3)** — runtime integration both platforms, capability gating, private-mode parity matrix.

**E-22 Ownership apex (P3)** — personal API + tokens/audit; SQLite/Parquet; scheduled exports; local export server.

**E-23 Community v1 (P3)** — circles, effort challenges, moderation tooling, notification-budget integration.

**E-24 Platform hardening (continuous)** — perf budgets CI, OEM background playbook, restore/recovery drills, accessibility audits, RTL audits, schema-migration soak tests.

---
---

## 43. Open-source and third-party build strategy

### 43.1 Build vs buy vs adopt matrix

| Layer | Choice | Candidates (report-sourced + evaluated) | Lock-in risk & mitigation |
|---|---|---|---|
| Health store access | Build thin adapters on official SDKs | HealthKit, Health Connect; reference: HealthKMP/Vitality (KMP wrappers) — *study, don't depend* for core | Low; official APIs |
| Wearable breadth | Buy (broker) then selectively build | Terra (500+ devices, webhooks), Sahha (prebuilt biomarkers/scores) — per report the fastest path; Open Wearables (self-hosted, open-source) as sovereignty alternative | Medium-high: per-user pricing + data-path exposure → adapter abstraction + §13.3 exit plan; Open Wearables fallback keeps leverage |
| Dedup/normalization | **Build** (core moat; report: "months to get right") | — | — |
| Scoring/baselines | **Build** (differentiator; validated vs literature) | ACWR literature grounding | — |
| Local DB | Adopt | SQLite + SQLDelight (KMP), SQLCipher | Low |
| Sync | Build on proven primitives | evaluate PowerSync/ElectricSQL-class vs custom E2E (E2E requirement likely forces custom thin layer) | Medium → keep protocol documented |
| Charts | Build design-system layer over | Swift Charts (iOS) + Vico/custom Compose canvas (Android) — native perf beats bridged libs (report lists options; native chosen with KMP chart-spec models) | Low |
| Food data | Buy multi-provider | Open Food Facts (open base) + commercial verified DB (Nutritionix/FatSecret-class) + regional providers (GCC/MENA) behind one proxy | High per-provider → proxy abstraction + provenance per item |
| Drug/ingredient lists | Adopt regional registries + curated list | openFDA labels, EU/GCC registries (display-only) | Low; display-only avoids clinical-DB licensing initially |
| AI/LLM | Buy gateway-routed, dual-vendor | Claude/GPT-class for language; Gemma/LiteRT + Apple Foundation Models on-device (report Tier 3) ; FAISS/BM25 for RAG | Medium → gateway abstraction, eval-suite portability |
| OCR/lab parsing | Adopt on-device first | Vision framework / ML Kit text recognition + custom mapper | Low |
| Auth | Adopt | Sign in with Apple/Google + passkeys; self-hostable option (report suggests Auth0 — acceptable, but passkey-first keeps it thin) | Medium → standard protocols only |
| Analytics | Adopt privacy-grade | PostHog self-hosted / TelemetryDeck-class | Low |
| Crash/monitoring | Adopt | Sentry | Low |
| FHIR (future) | Adopt | HAPI FHIR server-side; FHIR models lib client-side (report) | Contained to future module |
| Research frameworks (future) | Adopt if research mode | ResearchKit/CareKit/CardinalKit (report) | Contained |

### 43.2 OSS posture (outbound)
BADAN open-sources: export schema + data dictionary, import-connector parsers (community-extensible), the phrasing-linter ruleset (trust artifact), and possibly the HK/HC adapter layer — building credibility with exactly the power-user community the strategy courts, while the moat (dedup corpus, scoring calibration, experience) stays proprietary.

### 43.3 Vendor-risk routine
Quarterly dependency review (pricing, ToS, health signals); every "buy" has a documented exit path tested annually (broker → direct migration drill; LLM vendor swap via gateway evals).

---
---

## 44. Risks, traps, and anti-patterns

### 44.1 What NOT to copy from Bevel (observed)
Paywall-first day-one moments (locked hero numbers, particle-scrambled Bio Age, promo-card rotation on Home, two paywall interstitials in a six-minute session) · zeros-and-skeletons cold start (0g/0g/0g, "No data" walls) · logging-gated basic scores ("log 776 kcal to unlock") · iOS-monoculture · export absence · collapsing tab bar that hides orientation · burying the AI coach behind marketing sheets instead of giving it an address.

### 44.2 Category traps (report-grounded)
- **Calibration-trust trap:** confident numbers before baselines exist → the #1 churn quote. Counter: provisional honesty + backfill (P4).
- **Fragmentation trap:** features as islands (Bevel critique) → connective tissue systems (§8.5) with a standing "fragmentation review" in design crits.
- **Intimidation trap:** clinical walls of data → depth dial + presence-based UI + plain-word chips.
- **Shallowness trap (overcorrection):** cute-but-empty wellness apps → the power floor is contractual (§18).
- **Noise trap:** notification-led engagement → budget engine with public KPI (§24.8).
- **Creepiness trap:** unexplained inferences ("we noticed you're stressed") → every claim shows its evidence; no emotion inference beyond user-logged mood.
- **Brittleness trap:** vendor API churn breaking the daily contract → adapter abstraction, replay buffers, canary rings, status transparency.
- **Female-physiology trap:** male-default baselines → covariate architecture from Phase 2, not a bolt-on.
- **Pseudo-science trap:** biological age / correlations overclaiming → validation memos, confidence intervals, association language, published methodology.
- **Localization-theater trap:** translated labels with English-thinking content → native content authoring for AR, localized examples/foods, RTL-native design reviews.
- **Feature-factory trap:** matching every competitor release reactively → the seven laws arbitrate; benchmark reviews inform, don't dictate.

### 44.3 Execution risks & mitigations
Dedup underestimation (staff it as a product, not a ticket) · KMP toolchain friction (platform-team seniors; escape hatch = duplicated Swift core for isolated modules if needed) · AI cost runaways (token budgets per feature, caching, small-model routing per report's fast/slow food-parse pattern) · store-policy shifts on health data (compliance watch + feature flags) · scope gravity of the blueprint itself (phase gates enforce the roadmap's exit criteria; anything not passing gates slips whole, not half-ships).

---
---

## 45. Future expansions

**Biological age v2** — multi-model (lifestyle-age + blood-age separately, PhenoAge-informed), longitudinal "aging pace," full explainability; framed as wellness metric with published methodology.
**Health-record ingestion** — regional FHIR strategies (US HK Clinical Records first, GCC national-platform integrations as APIs mature), record-to-biomarker extraction with human confirmation, records vault UX; strict consent domain.
**Bloodwork services compatibility** — partner-lab import formats, at-home panel kit integrations, reference-range harmonization across labs.
**Family mode / caregiver sharing** — owner-driven, summary-scoped, revocable, visibly logged (§3.19 design); elder-consent research first.
**Clinician-share mode** — expiring read-only report links with professional formatting; explicitly *sharing*, not a clinical system of record; regulatory review gate.
**Advanced coaching** — periodized training-plan generation with load-aware adjustments; human-coach marketplace with consent-scoped data views.
**Voice** — morning audio briefings (TTS of narrative), voice logging everywhere, empathic-voice coaching exploration (report cites 2× engagement precedent) — privacy-reviewed.
**Multilingual wave 2+** — FR/DE/ES/JA/UR/HI/TR; dialect-aware Arabic content.
**Wearable ecosystem expansion** — emerging classes per §13.1 watchlist; BLE-direct evaluation only if store/vendor paths prove insufficient.
**Open API & ecosystem** — public read API (user-token), webhook subscriptions, community integrations gallery (Obsidian/Notion exporters, Home Assistant), plugin-reviewed model.
**Research mode** — opt-in structured self-experiments with e-consent (ResearchKit-class), data donation to IRB-approved studies with granular consent; reproducible report pipelines (notebook-grade exports with embedded methodology).
**Assistant-led data exploration** — conversational deep-dives that produce saved, reproducible analyses ("show me this every month"); the bridge from chat to durable artifacts.

---
---

## 46. Final synthesis

### 46.1 The blueprint in one view
BADAN wins by refusing the industry's false trade: **either** simple-and-shallow **or** deep-and-hostile. The resolution is architectural, not cosmetic — one canonical, provenance-rich data model (§30); one universal interpretive template (§8.4); one depth dial rendering two altitudes (§17–18); connective-tissue systems preventing fragmentation (§8.5); and trust engineered as infrastructure: explainable scores (§22.5), wording guardrails (§23.9), consent surfaces (§28), export as a flagship (§20), and a blind backend that *cannot* betray the user (§31.1).

### 46.2 Against the benchmark
From Bevel, BADAN takes the validated patterns — the pillar grammar, the metric-detail template, personal bands, rolling-delta tables, statuses, calculation transparency, module visibility, the warm-dark instrument aesthetic — and repays the debt by fixing what Bevel's own users document: Android absence, export absence, paywalled hero moments, cold-start emptiness, cycle-as-module, fragmentation. Parity by Phase 2; differentiation from day one.

### 46.3 The recurring tension, answered one last time
Easy for the casual, deep for the power user, broad in compatibility, serious in architecture, elegant, customizable-without-chaos, export-friendly, privacy-respectful, future-proof — these stop being nine competing adjectives the moment the system honors the seven laws: the repository is sacred; honesty over reassurance; zero-effort utility; one model, two altitudes; provenance always; one body, one app; built for the world. Every future feature decision should be tested against those laws — and when a decision passes all seven, it belongs in BADAN.

**بدنك. بياناتك. قصتك. — Your body. Your data. Your story.**
