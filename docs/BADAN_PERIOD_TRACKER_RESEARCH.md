# BADAN Period Tracking and Cycle-Anomaly Research

## 1. Executive summary

BADAN should implement menstrual-cycle tracking as a sensitive, local-first wellness system that does three jobs at once: it helps users log and anticipate their own pattern, it detects deviations from their own history without sounding clinical, and it exposes cycle phase as an uncertainty-aware covariate across recovery, sleep, training, mood, hydration, and nutrition.[cite:4][cite:10][cite:12] This directly operationalizes the blueprint requirement that cycle phase be modeled inside every baseline rather than treated as a bolt-on feature, explicitly addressing the documented luteal-phase false-alarm gap BADAN identified in WHOOP-like systems.[cite:6][cite:10][cite:14]

The safest and most useful v1 is not a fertility app in disguise and not a diagnostic engine in disguise.[cite:12][cite:41][cite:43] It should remain a general-wellness repository feature that predicts expected period timing with confidence bands, offers optional fertile-window estimates with prominent uncertainty and non-contraceptive framing, and surfaces anomalies only as pattern deviations relative to the user's own history.[cite:10][cite:12][cite:38]

Platform capability is sufficient to build a serious cross-platform system now.[cite:21][cite:27][cite:10] Health Connect natively supports menstruation period and flow records, basal body temperature, cervical mucus, ovulation tests, intermenstrual bleeding, and sexual activity, while BADAN's own blueprint already specifies cycle events, phase confidence, sensitive-class storage, export gating, and phase-conditioned baselines as part of the architecture.[cite:21][cite:10][cite:12]

The highest product risk is not raw prediction quality alone; it is trust failure from privacy overreach, false precision, or clinical-sounding anomaly wording.[cite:20][cite:25][cite:28] The research record around period-tracking apps shows persistent concern about data sharing, deletion controls, third-party SDK exposure, targeted advertising, and law-enforcement-access risk, especially in the post-Roe environment and in jurisdictions where reproductive data may be especially sensitive.[cite:20][cite:25][cite:28][cite:29]

Accordingly, the recommended BADAN stance is: local-first by default; separate consent for cycle sync and cloud-AI use; no third-party advertising or ad-adjacent SDK access to this data; exportable but default-off in scoped exports; and explicit module hide, retain, and purge controls.[cite:11][cite:12][cite:7] Within the product, cycle phase should influence baselines and interpretation only when confidence is sufficient, and the UI should degrade gracefully to "not enough confidence to use this as context yet" rather than guessing.[cite:10][cite:41]

## 2. Research methodology and safety boundaries

This research synthesizes four evidence layers: BADAN's own blueprint and repository architecture; platform documentation for HealthKit and Health Connect; publicly documented product patterns from WHOOP/HAE and the wider cycle-tracking market; and public research on ovulation prediction uncertainty, cycle variability, and reproductive-data privacy risk.[cite:2][cite:3][cite:10][cite:21][cite:27][cite:35][cite:38][cite:39]

The BADAN-specific baseline came from the master blueprint, execution plan, HAE analysis, and repository schema, which already establish sensitive-plus storage, module-level consent, phase-conditioned baselines, and a cycle-aware user archetype named Mariam as first-class product requirements.[cite:2][cite:6][cite:10][cite:12][cite:18] Those materials also establish the governing product laws that raw logs must remain exportable, confidence must accompany interpretation, and the same underlying model must serve both casual and power users.[cite:4][cite:11]

The health-platform layer relies on Apple's documented reproductive-health category identifiers and Android Health Connect's current cycle-tracking record types and permission model.[cite:21][cite:27] Health Connect documentation is especially explicit that menstruation, basal body temperature, cervical mucus, ovulation tests, intermenstrual bleeding, and sexual activity are supported as separate read/write record families, with background and history access requiring additional permissions.[cite:21]

The research boundary is strict: BADAN should not claim to diagnose menstrual disorders, detect pregnancy, confirm ovulation, assess fertility, provide contraception, or function as a medical device.[cite:12][cite:41][cite:47] Where the system estimates fertile timing or phase, it should describe that as a wellness-oriented estimate based on user-entered and platform-available signals, with uncertainty always shown and with plain language that advises prospective methods or professional care when users need medical-grade answers.[cite:38][cite:41][cite:43]

This document therefore separates product recommendations from clinically validated claims.[cite:12][cite:41] Product recommendations cover logging models, privacy architecture, anomaly UX, and phase-aware baseline design; anything that would imply medical efficacy, validated ovulation detection, or treatment guidance is flagged as out of scope unless BADAN later chooses a regulated product path.[cite:12][cite:29][cite:47]

## 3. Cycle-tracking product philosophy for BADAN

BADAN should treat cycle tracking as a repository-native context system, not as an isolated pink-tab utility.[cite:4][cite:6][cite:10] The blueprint already frames the body as one system and criticizes competitive fragmentation, requiring cycle phase to appear in recovery, sleep, and timeline logic when enabled rather than living in a disconnected pillar.[cite:6][cite:10]

That means the feature's core value is broader than "when is my next period."[cite:6][cite:14] The deeper differentiator is baseline correction: a user whose HRV, resting heart rate, sleep quality, temperature deviation, mood, or appetite predictably shifts by phase should see those shifts contextualized against phase-conditioned norms rather than mislabeled as generic under-recovery, sickness, or failure.[cite:6][cite:10][cite:14][cite:45]

The product philosophy should also stay aligned with Law 3: zero-effort utility, opt-in depth.[cite:4] BADAN should provide useful expectation-setting from just period start/end logging, then allow enrichment through optional flow, symptoms, BBT, ovulation tests, wearable temperature, contraception context, and privately gated sexual-activity logging.[cite:4][cite:10][cite:21]

Law 2 is especially important here: honesty over reassurance, kindness over alarm.[cite:4][cite:12] In practice, that means no confident single-date predictions for users with sparse or highly variable history, no pseudo-diagnostic anomaly banners, no generic fertile-window certainty claims unsupported by the data.[cite:4][cite:41][cite:43]

Law 1 and Law 5 together imply an unusually strong standard for reproductive data.[cite:4][cite:11] Cycle logs, symptoms, and related context must remain exportable raw records with provenance, confidence, source attribution, and explicit inclusion controls, even if paid intelligence layers later add advanced analytics on top.[cite:4][cite:10][cite:11]

## 4. Tracking inputs and logging model

BADAN should support all practical cycle-related inputs but grade them by sensitivity, optionality, and interpretive weight rather than pretending every user wants a fertility-tracking setup.[cite:10][cite:21][cite:27] The core model should distinguish between primary cycle events, supporting physiological signals, lifestyle/context modifiers, and highly sensitive optional logs such as sexual activity.[cite:10][cite:12][cite:21]

### Input catalog and policy

| Input | Required fields | Optional fields | Default visibility | Privacy sensitivity tier | Provenance metadata needed |
|---|---|---|---|---|---|
| Manual period start/end | start date; if ended, end date or ongoing flag | time precision, confidence, note | Visible in cycle module and timeline | Sensitive-plus | source=`manual`, entry timestamp, editor, backdated flag, correction chain |
| Flow log | date/time; flow value | numeric scale mapping, note, clotting/custom tags if user enabled | Visible only in cycle module by default | Sensitive-plus | source, scale schema version, normalized value, original label |
| Symptom log | symptom id or custom label; severity; date/time | duration, location, trigger, note | Reuses symptom views; cycle-scoped overlay optional | Sensitive-plus | source, vocabulary version, user-defined/custom flag, severity scale version |
| Basal body temperature | value; unit; date/time | measurement location, device/manual method, note | Visible in power mode by default | Sensitive-plus | source device/app, unit, measurement method, quality flag |
| Cervical mucus | date/time; appearance/sensation or mapped value | note | Hidden until user opts in | Sensitive-plus | source, schema version, manual-only flag |
| Ovulation test strip | result; date/time | brand, note, image attachment if ever added later | Hidden until user opts in | Sensitive-plus | source, result enum, manual/photo provenance, confidence |
| Contraceptive or reproductive-context log | method type; active interval start | end date, adherence notes, dose/schedule, side-effect note | Visible in cycle settings and timeline cards | Sensitive-plus | source, method taxonomy version, certainty, active/inactive state |
| Sexual activity | date/time | protection used, partner/caregiver visibility, note | Off by default and hidden from casual UI | Sensitive-plus-highest | explicit module consent, source, access log flag, redaction policy |
| Wearable-derived correlates | date/time; signal value or deviation | source metric family, nightly coverage, quality | Shown as context only, not as primary log | Standard health source feeding sensitive inference | source device, coverage, quality flags, algorithm version |
| Retroactive correction | target record id; revised value/date | reason, note | Power-mode edit trail | Sensitive-plus | original value, revised value, editor, revision timestamp |
| Historical import | normalized imported rows | source app/file, mapping confidence, unresolved fields | Import review screen first | Sensitive-plus | import batch id, source app, parser version, row-level status |

Manual period start/end logging is the irreducible input BADAN should optimize first.[cite:10][cite:21] A user should be able to start a period, mark it ongoing, end it later, or backfill an entire historical period in under three interactions for the repeat case, consistent with BADAN's interaction-count philosophy.[cite:4][cite:6]

Flow intensity should be customizable because platform-native scales are limited and users vary in how they think.[cite:21][cite:27] BADAN should store both an original user label and a normalized internal score, supporting simple labels like spotting/light/medium/heavy as the casual default while allowing numeric or custom mappings in power mode.[cite:10][cite:21]

Symptom logging should reuse BADAN's existing symptom architecture where possible rather than creating a cycle-only symptom silo.[cite:18] The recommended pattern is one shared `SymptomLog` family with a cycle-scoping relationship and optional cycle-specific vocabulary packs such as cramps, headache, bloating, acne, breast tenderness, fatigue, sleep disruption, digestive changes, libido change, and custom symptoms.[cite:18][cite:10]

Basal body temperature, cervical mucus, and ovulation test logs should be explicitly opt-in and never required to get value from the module.[cite:4][cite:21][cite:27] They are appropriate for users seeking greater cycle awareness or trying to conceive, but their presence should not nudge casual users toward a fertility-optimization workflow they did not ask for.[cite:4][cite:38]

Medication and contraceptive context should be logged as user context, not interpreted as treatment guidance.[cite:10][cite:12] BADAN can record pill use, IUD presence, patch, ring, injection, implant, emergency contraception, and general hormone-therapy context because these strongly affect cycle interpretation, but the interface must avoid advising on adherence or efficacy beyond neutral record-keeping.[cite:10][cite:12]

Sexual activity logging should exist only as a deeply gated, explicitly enabled capability with stronger access friction than the rest of the module.[cite:21][cite:28][cite:29] Research on period-tracker privacy repeatedly highlights that combining cycle, pregnancy, sexual-activity, and location data dramatically raises safety and legal risk, so BADAN should keep this off by default, excluded from cloud AI by default, and omitted from nearly all casual surfaces.[cite:28][cite:29]

Wearable-derived signals such as wrist/skin temperature deviation, HRV, and resting heart rate are useful as correlates and covariates, not as authoritative cycle events.[cite:10][cite:21][cite:38][cite:47] BADAN should label them as "signals that sometimes move with cycle phase" and never silently convert them into definitive ovulation or fertility claims.[cite:10][cite:38]

Historical import should support CSV/manual pathways because users often have years of prior data locked in other apps.[cite:4][cite:15] The import review flow should preserve raw source labels, display mapping confidence, and require user confirmation before cycle history becomes part of BADAN predictions, especially when imported schemas lack explicit end dates or use ambiguous flow/symptom vocabularies.[cite:4][cite:11]

### Logging-model recommendations

- Use interval records for whole-period spans and instantaneous records for flow, symptoms, BBT, ovulation tests, cervical mucus, and sexual activity.[cite:21][cite:10]
- Permit backdating everywhere and preserve revision history because cycle recall is often retrospective.[cite:10]
- Require provenance on every prediction input: manual, imported, HealthKit, Health Connect, inferred-from-wearable, or derived-from-combination.[cite:4][cite:10][cite:18]
- Distinguish "user asserted" from "system inferred" at the model layer, with user-asserted period dates always taking precedence over inferred ones.[cite:10]
- Support partial-history logging, including "I know my start dates for the last six months but not symptoms or flow."[cite:4][cite:35]

## 5. Prediction and expectation model

BADAN should use a tiered prediction stack that becomes more personalized as history quality improves.[cite:10][cite:35][cite:41] The system should start with conservative calendar estimates, progress to rolling weighted models once enough cycles exist, and optionally refine phase estimates using BBT, ovulation tests, cervical mucus, and wearable correlates when the user has opted into those inputs.[cite:35][cite:38][cite:41]

### Prediction tiers

1. **Cold start: zero history.** BADAN should not predict a next period immediately unless the user enters a last period start date or historical import.[cite:4][cite:41] The day-one state should say that predictions need at least one logged period start to begin expectation-setting, and that confidence improves as more cycles accumulate.[cite:4]
2. **Low history: 1 to 2 completed cycles.** Use simple average cycle length and last known period duration, but render only wide ranges such as "expected in about 5-9 days" or "next period likely late next week," not a single date.[cite:35][cite:41]
3. **Moderate history: 3 to 5 completed cycles.** Use a rolling weighted model that emphasizes recent cycles while retaining older cycles for stability.[cite:35][cite:39][cite:41] BADAN's blueprint already suggests six cycles as the baseline window for cycle-length stats, which is a good default planning horizon.[cite:10]
4. **Mature history: 6 or more completed cycles.** Use variability-aware prediction intervals, phase-conditioned expectations, and context-sensitive confidence reduction when travel, illness, medication changes, or contraception context indicate likely disruption.[cite:10][cite:35][cite:39]
5. **Rich-signal mode.** If the user logs BBT, ovulation tests, cervical mucus, or reliable wearable temperature shifts, use those as supporting evidence to refine phase and fertile-window estimates, while keeping raw uncertainty visible.[cite:21][cite:38][cite:47]

### Cycle-length and next-period prediction

Public research consistently shows that cycle and ovulation timing vary more than popular app UIs often imply.[cite:39][cite:41][cite:43] BADAN should therefore predict a window, not a date, and compute its width from the user's own historical spread rather than from a generic 28-day assumption.[cite:35][cite:39][cite:41]

A robust practical model is a weighted rolling estimate over recent completed cycle lengths, with recency weighting, outlier resistance, and a personal variance band.[cite:35][cite:41] For example, the central estimate can come from the weighted median or robust mean of the last 3 to 6 complete cycles, while the prediction interval is widened when recent spread increases, signal quality falls, or contextual modifiers such as medication change, postpartum status, or long-haul travel are active.[cite:10][cite:35][cite:39]

The UI language should match the confidence level.[cite:4][cite:41] High confidence can support phrasing like "expected in 3-5 days"; medium confidence can say "likely in about a week"; low confidence should say "pattern is variable right now, so the estimate is broad" or "prediction paused until more history returns."[cite:4][cite:10]

### Fertile-window estimation

BADAN may include fertile-window estimation only if it is clearly framed as a wellness estimate, not contraception and not fertility treatment.[cite:12][cite:38][cite:43] Evidence from calendar-method studies shows that cycle length alone yields wide ovulation variability and poor precision when apps try to turn it into a narrow fertile window.[cite:39][cite:43]

That makes a three-level approach appropriate:

- **Calendar-only mode:** show a broad "higher-likelihood fertility window" based on cycle history, with strong uncertainty language and a clear "not for contraception" notice.[cite:35][cite:39][cite:43]
- **Signal-assisted mode:** narrow the estimate only when supporting evidence such as a positive ovulation test, BBT shift, or mucus pattern exists.[cite:21][cite:38][cite:42]
- **Suppressed mode:** hide fertile-window estimates entirely if the user selects postpartum, suppressive contraception, perimenopause tracking, or a "don't show fertility estimates" preference.[cite:10][cite:46]

### Ovulation-day estimation

Calendar methods can support rough expectation-setting, but public evidence shows broad variation in actual ovulation timing even within the same apparent cycle length.[cite:39][cite:43] BADAN should therefore treat calendar-only ovulation estimation as the weakest evidence class, BBT shift and ovulation tests as stronger retrospective or near-prospective evidence, and combined multi-signal corroboration as the strongest available non-clinical approach.[cite:38][cite:42][cite:47]

A positive LH/ovulation test is useful as a near-term signal, while a sustained BBT rise is more useful as retrospective confirmation that a phase shift likely occurred.[cite:21][cite:38][cite:42] Cervical mucus can improve subjective awareness but is user-variable and should mainly serve as supportive context rather than a sole determinant.[cite:21][cite:38]

### Handling irregular and special contexts

Irregular cycles, PCOS-pattern variability, perimenopause transitions, postpartum cycle absence, and hormonal contraception all require the same philosophical move: pause or broaden prediction instead of forcing false precision.[cite:10][cite:41][cite:46] BADAN's blueprint already explicitly calls for "prediction paused" rather than wrong guesses for irregular cases, and that should remain the central rule.[cite:10]

For postpartum, breastfeeding-related amenorrhea, or any prolonged absence of logged cycles, BADAN should stop next-period forecasts after a configurable quiet window and explain that there is not enough recent repeating pattern to estimate timing responsibly.[cite:10][cite:46] For users on suppressive hormonal contraception, BADAN should optionally track bleeding events and symptoms but default phase and fertile-window inference to off unless the user explicitly wants contextual overlays with low-confidence labels.[cite:10]

### Visual and verbal confidence communication

The best communication pattern is a confidence band, not a single pin on a calendar.[cite:4][cite:41] Recommended UI elements are: a shaded expected-period window, a central estimate, a confidence descriptor, a method label such as "based on 5 recent cycles" or "refined with BBT and ovulation logs," and a one-tap "why this estimate?" anatomy sheet.[cite:4][cite:10]

BADAN should avoid wording like "you will ovulate on..." or "your period is due tomorrow" unless the user sees the uncertainty context in the same surface.[cite:4][cite:41][cite:43] Better language is "expected around...," "likely between...," "estimate is broad this month," and "not enough recent pattern for a narrow estimate."[cite:4][cite:10]

## 6. Anomaly detection model

BADAN should define anomalies as deviations from the user's own established pattern, never as diagnoses and never as named-condition speculation.[cite:4][cite:12][cite:10] This is philosophically consistent with BADAN's personal-normal-band approach and practically necessary because public cycle research shows wide natural variability across people and within the same person over time.[cite:10][cite:39][cite:41]

An anomaly engine should activate only after minimum-history thresholds are met.[cite:10][cite:41] Sparse data is a major source of false alarms, so the safest rule is that single-cycle anomaly calls require at least 3 completed cycles of baseline history, while pattern-level anomaly calls require at least 4 to 6 cycles depending on the anomaly class.[cite:10][cite:41]

### Detection logic principles

- Use self-referential baselines: compare current cycle length, period duration, flow pattern, and symptom burden to the user's recent historical distribution.[cite:10][cite:41]
- Prefer robust thresholds over naive means: use medians, interquartile spreads, rolling MAD-like bands, and persistence checks so one unusual month does not redefine baseline too aggressively.[cite:35][cite:41]
- Down-rank anomaly severity when contextual disruptors are active, such as travel, high stress, illness, new medication, contraception change, postpartum mode, or known sparse history.[cite:10][cite:12]
- Escalate only on persistence or magnitude, not on one noisy point.[cite:4][cite:12]

### Anomaly matrix

| Anomaly type | Detection basis | Minimum history required | Default sensitivity | Message template | Escalation rule | Risk if worded poorly |
|---|---|---|---|---|---|---|
| Cycle notably longer/shorter than usual | Current cycle length outside personal recent band by configurable margin | 3 complete cycles; better at 4+ | Medium | "This cycle looks longer/shorter than your recent pattern. Changes like this can happen for many reasons. Keep tracking and consider checking in with a clinician if this becomes a repeated pattern or worries you." | Escalate after 2 consecutive deviations or 3 of last 4 cycles | Can sound like pregnancy, infertility, or disease speculation |
| Period duration longer/shorter than usual | Logged bleed duration outside personal range | 3 complete periods | Medium | "This period lasted longer/shorter than your recent pattern." | Escalate after repeated deviation across 2 cycles | Can sound like abnormal bleeding diagnosis |
| Flow heavier/lighter than usual | Sum or peak flow intensity materially different from personal baseline | 3 periods with flow logs | Low | "Your logged flow this cycle looks heavier/lighter than what you usually record." | Escalate only if repeated and user has flow logging consistency | Can sound alarming or imply hemorrhage or deficiency |
| Missed expected period | No period start by end of predicted confidence band plus user threshold | 3 cycles for forecast; otherwise inactive | Medium | "Your period has not arrived within the expected range based on recent logs." | Escalate after threshold + repeat next cycle or prolonged absence mode | Can imply pregnancy if phrased carelessly |
| Symptom cluster shift | New or much higher symptom burden versus personal cycle-phase history | 4 cycles with symptom logs | Low | "This cycle's symptom pattern looks different from what you usually log." | Escalate after 2 similar cycles | Can sound diagnostic for PMDD, endometriosis, PCOS, etc. |
| Multiple irregular cycles pattern | 2+ consecutive cycles or 3 of last 4 outside baseline | 4 to 6 cycles | Medium | "Recent cycles have been more variable than your usual pattern." | Pattern card persists until stability returns or user dismisses | Can sound like chronic-condition labeling |
| Context-linked change | Deviation temporally aligned with travel, illness, med change, stress, postpartum mode | 3 cycles plus context logs | Low | "This shift happened around a time when you logged travel/illness/stress/medication change." | No escalation unless deviations persist after context clears | Can overstate causality |

### Recommended v1 anomaly classes

The highest-value v1 anomaly classes are: cycle length deviation, period duration deviation, missed expected period, flow deviation, and repeated irregularity over multiple cycles.[cite:10][cite:41] These are the most understandable to users, the most directly tied to available inputs, and the least likely to require clinically loaded interpretation if phrased carefully.[cite:4][cite:12]

Symptom-cluster anomaly detection should be in v1 only if BADAN already has solid cross-feature symptom infrastructure, because otherwise it risks noisy alerts driven by inconsistent logging density.[cite:18][cite:10] If included, it should default to passive cards in the cycle detail view rather than notifications.[cite:4][cite:12]

### Surfacing and sensitivity model

Anomalies should be configurable at three levels: suppressed, gentle awareness, and detailed awareness.[cite:12] The default should be gentle awareness, meaning passive in-app cards and timeline notes rather than push notifications, with push used only for missed-expected-period or repeated-pattern anomalies if the user opts in.[cite:12]

A good default hierarchy is:

- **One-off mild deviation:** quiet card in cycle module only.[cite:4]
- **Meaningful single-cycle deviation:** card plus optional timeline event.[cite:10]
- **Repeated deviation pattern:** card plus optional notification and correlation prompt ("see what else changed").[cite:10][cite:12]
- **User-suppressed:** anomaly still stored for analytics/history if user allows, but never surfaced.[cite:11][cite:12]

### Wellness-safe language and banned language

BADAN should never say: "abnormal cycle," "possible disorder," "this suggests PCOS," "you may be infertile," "implantation," "pregnancy likely," "failed ovulation," "hormone imbalance detected," or "seek care immediately" unless a regulated medical-review pathway is added later.[cite:12][cite:41][cite:46] The product can say: "different from your recent pattern," "broader than usual," "not enough recent pattern," "this can happen for many reasons," and "consider talking with a healthcare professional if this continues or concerns you."[cite:4][cite:12]

## 7. Cycle phase as a cross-app covariate

This is the core differentiator BADAN should pursue hardest.[cite:6][cite:10] The blueprint explicitly states that cycle phase should live inside every baseline and score, especially to prevent luteal-phase misclassification in recovery contexts, and WHOOP's own public feature language plus community feedback show why that matters: menstrual overlays alone do not solve false alarms if the scoring baseline itself remains phase-naive.[cite:6][cite:10][cite:14][cite:45]

### Phase model

BADAN should model phase as a dated interval estimate with confidence, not as a deterministic label.[cite:10][cite:38] The canonical states are menstrual, follicular, ovulatory window, luteal, and unknown/paused, each with a confidence score and an evidence basis such as calendar-only, calendar-plus-BBT, calendar-plus-ovulation-test, or suppressed-due-to-context.[cite:10][cite:38]

Phase should be recomputed daily and attached to baseline contexts only when confidence exceeds a minimum threshold.[cite:10] If confidence is low, BADAN should either widen the covariate band or fall back to unconditioned baselines rather than applying a misleading phase label.[cite:10][cite:41]

### Baseline-aware recovery and vitals

Recovery, HRV, resting heart rate, sleep temperature deviation, and sleep-related readiness should all support phase-conditioned baselines when the cycle module is enabled and sufficiently confident.[cite:6][cite:10] In practical terms, BADAN should maintain parallel baselines such as `hrv baseline overall`, `hrv baseline follicular`, and `hrv baseline luteal`, then compare the current observation against the appropriate context rather than against a pooled cross-phase average.[cite:10][cite:45]

This is the most direct operational response to the blueprint's named WHOOP failure mode.[cite:6] A luteal-phase drop in HRV or rise in resting heart rate that is normal for that user should reduce false "under-recovered" or "possible illness" interpretations, while still allowing BADAN to detect true deviations when current luteal values are unusual even relative to that user's own typical luteal pattern.[cite:6][cite:10][cite:45]

### Training-load and strain context

BADAN can mention phase as context in training views without turning it into deterministic coaching.[cite:10][cite:14] Appropriate phrasing is: "Recent runs in this phase have felt harder for you," "Recovery scores tend to run lower in your late luteal pattern," or "Hydration and sleep disruption often co-occur for you during this part of the cycle."[cite:10][cite:14]

What BADAN should avoid is prescriptive essentialism like "don't train hard in luteal phase" or "you are weak today because of your cycle."[cite:12][cite:45] Training suggestions should be framed as personal trend observations and optional context, not universal sex-based rules.[cite:12][cite:45]

### Sleep, mood, hydration, and nutrition overlays

Sleep views should be able to overlay phase labels or shaded bands on nightly charts when enabled.[cite:6][cite:10] Mood, hydration, appetite, cravings, GI symptoms, and nutrition adherence can similarly show optional cycle overlays to help users spot personally repeating patterns without asserting causation.[cite:10][cite:14]

A strong BADAN pattern would be an opt-in "Correlation Lab" that asks within-subject questions such as whether late-luteal nights are associated with lower HRV, shorter sleep, higher cravings, lower hydration, or different perceived exertion.[cite:14][cite:36] Because within-subject methodology is generally more appropriate for cycle-linked variation than broad population assumptions, BADAN should emphasize sample size, phase coverage, and uncertainty in any correlation view.[cite:36][cite:14]

### Graceful degradation

The covariate model must degrade gracefully for users who disable the cycle module, use suppressive contraception, are post-menopausal, are postpartum, or simply do not have enough data.[cite:10][cite:12] In those cases BADAN should either omit cycle-aware interpretation entirely or show a neutral state such as "cycle context not active," with baselines reverting to standard unconditioned models.[cite:10]

### Cross-app implementation rules

- No score should rely on cycle phase if phase confidence is below threshold.[cite:10][cite:41]
- Any phase-conditioned interpretation must be explainable in one tap with source inputs and confidence.[cite:4][cite:10]
- Phase context should appear as optional overlay chips or chart layers, not forced narrative in every screen.[cite:4][cite:10]
- Correlation views must present association, sample size, and confidence, not claims of biological causality.[cite:14][cite:36]

## 8. Customization and modes

Cycle tracking has unusually diverse user intents, so BADAN should expose explicit modes without forking the underlying model.[cite:4][cite:12] This matches the "one data model, two altitudes" philosophy: casual users need calm, low-friction awareness; power users need schema transparency, raw exports, and custom logging vocabularies on the same data backbone.[cite:4][cite:18]

### Goal and mode configuration

Recommended top-level goals are:

- General awareness.
- Trying to conceive.
- Avoiding pregnancy awareness (explicitly non-contraceptive).
- Symptom-pattern tracking.
- Perimenopause tracking.
- Postpartum tracking.[cite:46][cite:12]

These goals should not create different databases or different truth models.[cite:4][cite:18] They should instead tune visible inputs, wording, default overlays, fertile-window behavior, anomaly sensitivity, and onboarding copy.[cite:4][cite:12]

### Vocabulary and scale customization

Flow scales should support both friendly labels and numeric mappings.[cite:21][cite:27] Symptom vocabularies should offer a curated starter set plus custom symptoms, favorite symptoms, and language-localized synonyms so Arabic-speaking users can pick precise but culturally comfortable terms rather than being forced into imported English euphemisms.[cite:12]

### Notification styles

Notification options should include none, gentle, and detailed.[cite:12] Gentle is the recommended default and should favor calendar-like expectation notices or one bundled "pattern changed" card rather than multiple alerts for flow, symptoms, and timing independently.[cite:12]

### Sharing modes

Partner-sharing or caregiver-sharing should be out of the default scope and added only if BADAN is willing to implement explicit consent, revocation, auditability, and per-field scoping.[cite:11][cite:12] If ever added, the share model should allow users to expose only selected outputs such as next expected period window or symptom summary while keeping detailed sexual or contraception logs private.[cite:11][cite:12]

### Localization and Arabic/RTL considerations

Arabic and RTL support should be treated as a first-class requirement rather than a translation pass because reproductive-health language is culturally sensitive and can quickly become awkward, clinical, or stigmatizing.[cite:4][cite:12] BADAN should support terminology variants, avoid infantilizing euphemisms, ensure calendar layouts mirror properly in RTL, and let users choose between more neutral "cycle" language and more direct "period" language where culturally appropriate.[cite:4]

### Visibility, retention, and deletion controls

The cycle module should have a master visibility switch that hides it from navigation while preserving data unless the user explicitly purges it.[cite:10][cite:12] Because the blueprint already requires delete-vs-retain choice on module disable, BADAN should expose three separate actions: hide, pause predictions, and delete data.[cite:12]

## 9. Privacy and safety architecture

This module deserves BADAN's strictest privacy stance.[cite:7][cite:11][cite:12] BADAN's blueprint already classifies cycle data as sensitive-plus, stores it in a separate encrypted database, excludes it from cloud AI by default, and requires separate sync consent, which should be preserved exactly as the implementation baseline.[cite:11][cite:12]

### Required architectural posture

- Local-first by default for all cycle-family data.[cite:12]
- Separate consent for cycle sync, separate consent for cloud-AI use of cycle data, and separate export inclusion toggles.[cite:11][cite:12]
- No ad-tech, third-party analytics SDKs, or partner-sharing SDKs with access to raw reproductive-health fields.[cite:11][cite:20][cite:28]
- Module disable must offer retain vs purge, with purge actually deleting rows, destroying relevant key material, and invalidating derived values.[cite:12]
- Sensitive export must default off every time, with no sticky "always include cycle data" setting.[cite:12]

These recommendations are strongly supported by public privacy research and investigations into period trackers.[cite:20][cite:25][cite:28][cite:29] Reporting from the BBC, the UK ICO review context, Duke's post-Roe privacy research, and Privacy International's technical investigations all point to recurring user concerns about third-party sharing, difficult deletion, location-linked reproductive inference, misleading consent, and legal/government access risk.[cite:20][cite:25][cite:28][cite:29]

### Consent design

Consent for this module should not be buried inside general HealthKit/Health Connect permission copy.[cite:11][cite:12] BADAN should use a dedicated BADAN-level consent screen that explains, in plain language, what cycle data can be stored locally, what is excluded from cloud AI by default, what sync would mean if turned on, and how users can later hide, export, or delete the module.[cite:11][cite:12]

A good consent stack is:

1. Platform read/write permission explanation.[cite:21][cite:27]
2. BADAN cycle-module explanation and local-first default.[cite:11][cite:12]
3. Optional sync consent for cycle family only.[cite:11][cite:12]
4. Optional cloud-AI consent for cycle family only, off by default.[cite:11][cite:12]
5. Optional sexual-activity sub-consent if that feature is enabled.[cite:21][cite:29]

### Server-side minimization

BADAN should minimize server-side transmission of raw reproductive-health logs as a categorical rule, not just a preference.[cite:11][cite:12][cite:28] If sync is ever enabled, BADAN should consider end-to-end or blind-storage patterns for the sensitive namespace and should keep operational metadata minimal enough that server compromise or compelled access reveals as little as possible.[cite:11][cite:12]

### Export and deletion behavior

Law 1 means cycle data must remain exportable, but sensitive export should require extra intentionality.[cite:4][cite:12] BADAN should use a dedicated confirmation step, redaction preview, and warning that exported files may not be protected once saved or shared outside the app.[cite:11][cite:12]

Deletion behavior must be explicit and verifiable.[cite:11][cite:12] Users should be able to delete a single log, a date range, the entire cycle family, or the entire account, and the app should state whether local-only data, synced replicas, derived values, and backups are also affected.[cite:11][cite:12]

### Regional and legal review flags

BADAN should flag reproductive-data handling for product/legal review in regions with restrictive reproductive-health laws or heightened compelled-disclosure risk, but without making legal promises in the UI.[cite:12][cite:28][cite:29] The blueprint already requires a jurisdictional reproductive threat-model document, which should explicitly cover law-enforcement requests, residency options, cloud-processor exposure, and data minimization for this family.[cite:12]

### Trust messaging

Reassurance should be precise, not absolute.[cite:11][cite:12] BADAN can credibly say "stored on this device by default," "excluded from cloud AI unless you turn that on," and "sensitive data is off in exports unless you choose otherwise," but should avoid broad claims such as "fully private," "unhackable," or "impossible for anyone else to access."[cite:11][cite:12]

## 10. Data model and technical architecture

BADAN already has a two-database architecture with `badan.db` and `badan_sensitive.db`, plus shared provenance and derived-value conventions, which is a strong foundation for the cycle module.[cite:18][cite:11] The cycle feature should reuse these conventions rather than inventing a parallel schema philosophy.[cite:18]

### Recommended entity design

The cycle module should introduce explicit entities for user-asserted cycle events, flow, temperature, ovulation signals, predictions, phase estimates, anomalies, and visibility/consent, while reusing generic symptom infrastructure whenever possible.[cite:10][cite:18]

### Data model matrix

| Entity | Purpose | Key fields | Provenance/confidence fields | Storage tier | Export behavior |
|---|---|---|---|---|---|
| `CycleRecord` | Canonical period span | id, start_at, end_at, ongoing, note, user_goal_context | source, confidence, backdated_flag, revision_chain, import_batch_id | Local-only by default in sensitive DB; optional sync with separate consent | Included only when cycle export toggle enabled |
| `FlowLog` | Day-level or time-level flow intensity | id, cycle_id, occurred_at, original_label, normalized_intensity, note | source, scale_version, confidence | Sensitive local-first | Included when cycle export enabled |
| `SymptomLog` / cycle-scoped symptom entry | Shared symptom logging with cycle relationship | id, symptom_id, severity, occurred_at, duration, note, cycle_id optional | source, vocabulary_version, scale_version, confidence | Sensitive local-first | Included with symptom export and cycle relations preserved |
| `BasalTemperatureLog` | Manual or imported BBT entries | id, occurred_at, value, unit, method, location | source_device, quality_flags, confidence | Sensitive local-first | Included when cycle export enabled |
| `OvulationSignalLog` | LH test, mucus, other opt-in ovulation-related signals | id, signal_type, occurred_at, value/result, note | source, signal_schema_version, confidence | Sensitive local-first | Included when cycle export enabled |
| `ContraceptiveContextLog` | Reproductive-context intervals | id, method_type, start_at, end_at, adherence_note, category | source, certainty, taxonomy_version | Sensitive local-first | Included when reproductive-context export enabled |
| `CyclePrediction` | Next-period and optional fertile-window forecast | id, generated_at, predicted_next_start_low, center, high, method, status | confidence, algorithm_version, input_manifest_id, suppression_reason | Derived sensitive | Exportable as derived sensitive if user includes derived cycle data |
| `CyclePhaseEstimate` | Date-scoped phase context | id, date_range_start, date_range_end, phase, evidence_basis | confidence, algorithm_version, input_manifest_id | Derived sensitive | Exportable with phase context if enabled |
| `AnomalyEvent` | Non-diagnostic pattern deviation object | id, type, detected_at, basis_window, severity, message_template_id, state | confidence, detection_rule_version, input_manifest_id | Derived sensitive | Exportable with user-facing and machine-readable basis |
| `ModuleVisibilitySetting` | Hide/pause/retain state for cycle module | module_name, visible, predictions_enabled, anomaly_surface_mode | changed_at, actor | Main DB settings or consent DB | Included in settings export |
| `SharingConsentRecord` | Optional scoped sharing grants | id, target, scope_json, granted_at, revoked_at | purpose_text_hash, last_used_at | Main consent store + sensitive linkage | Included in consent export |

### Schema and relationship guidance

`CycleRecord` should be the anchor entity for completed or ongoing periods, with related `FlowLog`s and optionally associated symptom entries through date overlap or explicit linkage.[cite:10][cite:18] Because symptoms already exist in BADAN's sensitive schema, the cleanest route is to extend symptom entries with optional cycle linkage rather than duplicating a full symptom model under a cycle namespace.[cite:18]

Predictions and phase estimates should be stored as append-only derived values or dedicated derived entities with algorithm versioning and input manifests, consistent with BADAN's provenance law.[cite:4][cite:18] That makes it possible to explain exactly which cycles, signals, and context factors influenced a forecast or anomaly event.[cite:4][cite:10][cite:18]

Anomaly events should store both machine-readable detection basis and user-facing rendered message templates so that dismissed, acknowledged, repeated, and suppressed states can be audited cleanly.[cite:12][cite:18] Severity should be a surfacing priority only, not a clinical importance claim.[cite:12]

## 11. Health platform integration map

BADAN should map its internal model to platform-native objects where possible, but it should not let platform schemas dictate the whole user experience.[cite:21][cite:27][cite:10] Health Connect currently offers the clearest modern cross-platform cycle-record map in public documentation, including distinct records for menstruation period, menstruation flow, basal body temperature, cervical mucus, intermenstrual bleeding, ovulation tests, and sexual activity.[cite:21]

HealthKit's reproductive-health families, as reflected in Apple ecosystem documentation and long-standing type identifiers, support menstrual flow, intermenstrual bleeding, ovulation-test results, cervical mucus, basal body temperature, and sexual activity, with menstrual flow historically modeled as a category value rather than a full interval object.[cite:27][cite:22][cite:30] BADAN's blueprint already references these HealthKit categories directly in the cycle raw-input spec.[cite:10]

### Feature matrix

| Feature | Casual value | Power-user value | Required data | HealthKit support | Health Connect support | Privacy tier | Complexity | Priority | BADAN recommendation |
|---|---|---|---|---|---|---|---|---|---|
| Period start/end logging | High | High | Manual dates | Yes via menstrual/reproductive data ecosystem references; internal mapping needed[cite:10][cite:27] | Yes via `MenstruationPeriodRecord`[cite:21] | Sensitive-plus | Medium | P0 | Ship in v1 |
| Flow logging | High | High | Flow value by date/time | Yes via `MenstrualFlow` category values[cite:27][cite:30] | Yes via `MenstruationFlowRecord`[cite:21] | Sensitive-plus | Medium | P0 | Ship in v1 |
| Cycle prediction window | High | High | 1+ prior periods | Platform-agnostic internal model[cite:10] | Platform-agnostic internal model[cite:10] | Sensitive-plus derived | Medium | P0 | Ship in v1 |
| Phase estimate overlay | Medium | High | Periods; optional signals | Inputs supported[cite:10][cite:27] | Inputs supported[cite:21] | Sensitive-plus derived | High | P0 | Ship in v1 with confidence gating |
| Anomaly cards | Medium | High | 3+ cycles or logs | Platform-agnostic internal logic[cite:10] | Platform-agnostic internal logic[cite:10] | Sensitive-plus derived | Medium | P0 | Ship core anomalies in v1 |
| Symptom logging with cycle overlay | High | High | Symptom entries | Internal + possible platform read if available elsewhere[cite:18] | Internal + platform-independent[cite:18] | Sensitive-plus | Medium | P0 | Ship in v1, reuse symptom model |
| BBT logging/import | Medium | High | Temperature values | Yes via basal body temperature[cite:10][cite:27] | Yes via `BasalBodyTemperatureRecord`[cite:21] | Sensitive-plus | Medium | P1 | Ship in v1 if UI remains optional |
| Ovulation test logging | Low | High | Test result + time | Yes via ovulation test result[cite:10][cite:27] | Yes via `OvulationTestRecord`[cite:21] | Sensitive-plus | Medium | P1 | Ship in v1 as opt-in advanced input |
| Cervical mucus logging | Low | High | Appearance/sensation | Yes via cervical mucus quality[cite:10][cite:27] | Yes via `CervicalMucusRecord`[cite:21] | Sensitive-plus | Medium | P2 | Defer to phase 2 unless target audience demands it |
| Sexual activity logging | Low | Medium | Date/time + protection | Yes in HealthKit reproductive health references[cite:22][cite:27] | Yes via `SexualActivityRecord`[cite:21] | Sensitive-plus-highest | High | P2 | Defer; include only with strong privacy gating |
| Contraceptive context | Medium | High | Method interval | Usually manual/internal | Usually manual/internal | Sensitive-plus | Medium | P0 | Ship in v1 internal-only |
| Historical CSV import | Medium | High | File mapping | Internal import layer | Internal import layer | Sensitive-plus | High | P1 | Ship basic import in phase 1.5/2 |
| Wearable temperature/HRV correlation | Medium | High | Standard wearable vitals + cycle data | Yes depending on source availability[cite:10] | Yes depending on source availability[cite:21] | Mixed: standard->sensitive inference | High | P1 | Ship overlay/covariate use before full inference |
| Scoped export with default-off sensitive toggle | Medium | High | Raw + derived records | Internal export | Internal export | Sensitive-plus | Medium | P0 | Mandatory in v1 |

### Integration guidance

HealthKit integration should focus first on reading menstrual-flow-related categories and basal body temperature, then writing BADAN-originated manual entries back only if the user explicitly enables bidirectional write behavior.[cite:10][cite:27] Health Connect can support a more structurally direct map because it has both `MenstruationPeriodRecord` and `MenstruationFlowRecord` as first-class types.[cite:21]

Because BADAN's trust posture is local-first, imported platform records should preserve their original source-app provenance rather than being silently rewritten as BADAN-native truth.[cite:4][cite:18] If a user edits an imported period, the system should record that as a BADAN correction layer and, unless write-back is enabled, leave the original platform source untouched.[cite:10][cite:18]

## 12. Casual-user experience

The casual-user experience should answer three questions with almost no effort: Am I currently on my period, when is the next one roughly expected, and is anything noticeably different from my normal pattern this month.[cite:4][cite:10] Casual mode should therefore default to simple logging, broad predictions, phase-aware overlays on key screens, and calm anomaly surfacing without exposing the full technical apparatus.[cite:4][cite:12]

The recommended casual home experience is a small cycle card with current status, next expected window, and one sentence of context such as "recovery is being compared against your usual luteal pattern."[cite:6][cite:10] Logging a period should be one tap from the home card and two to three taps to finish the repeat flow, consistent with BADAN's repeat-case interaction standards.[cite:4][cite:6]

Casual users should not be forced to choose flow scales, symptom taxonomies, or fertility settings before seeing value.[cite:4] The default setup should ask only whether to enable the module, whether to import existing cycle data if available, and whether the user wants general awareness versus more detailed cycle insights.[cite:4][cite:12]

## 13. Power-user experience

Power users should get raw history, source provenance, confidence bands, method labels, phase overlays across charts, export scopes, and correlation tooling on the same underlying data model.[cite:4][cite:18] This is where BADAN can outperform simpler trackers and generalized wearables by showing not just a prediction, but how it was formed and how it changes other baselines.[cite:4][cite:10]

The power cycle detail view should include complete cycle history, per-cycle length and period-duration statistics, phase-estimate bands, symptom and flow overlays, confidence shifts after each new input, and an anatomy panel showing the cycles and signals used in the latest forecast.[cite:10][cite:18] Export should support CSV/JSON/SQLite bundle representations with explicit include/exclude toggles for each sensitive family and derived cycle analytics.[cite:4][cite:11][cite:12]

A power-user "Correlation Lab" is especially well aligned with BADAN's audience because it transforms cycle tracking from a silo into a whole-body personal analytics system.[cite:14][cite:36] The key is to keep it statistically honest: show sample size, within-user comparisons, phase coverage, confidence, and plain-language caveats that correlation is not causation.[cite:14][cite:36]

## 14. Wellness-safe language guide and phrasing library

BADAN's language should be calm, personal, and uncertainty-aware.[cite:4][cite:12] It should describe patterns, ranges, and context; it should not imply diagnosis, pathology, fertility efficacy, or reproductive outcomes that the system cannot validate.[cite:12][cite:41]

### Recommended phrasing patterns

- "Expected around..." instead of "due on...".[cite:4]
- "Different from your recent pattern" instead of "abnormal."[cite:12]
- "Estimate is broad this cycle" instead of "prediction unreliable."[cite:4]
- "This can happen for many reasons" instead of named-condition speculation.[cite:12]
- "Consider talking with a healthcare professional if this continues or concerns you" instead of prescriptive or urgent medical language.[cite:12]
- "Compared with your usual late-luteal pattern" instead of "HRV is low."[cite:6][cite:10]

### What BADAN must avoid saying

- "You are ovulating today."[cite:41][cite:43]
- "This likely means pregnancy."[cite:29]
- "Your cycle is abnormal."[cite:12]
- "You may have PCOS/endometriosis/PMDD."[cite:46][cite:12]
- "Avoid pregnancy by using this window."[cite:43]
- "Your body is underperforming because of your cycle."[cite:12][cite:45]

### Ready-to-use message templates

- **Prediction low confidence:** "Your cycle pattern is variable right now, so this estimate is broad."[cite:10][cite:41]
- **Period expected soon:** "Based on your recent logs, your next period is expected in about 3-5 days."[cite:35][cite:41]
- **Longer-than-usual cycle:** "This cycle looks longer than your recent pattern. Changes like this can happen for many reasons."[cite:12]
- **Repeated irregularity:** "Recent cycles have been more variable than your usual pattern."[cite:12]
- **Phase-aware recovery copy:** "Today's recovery is being compared with your usual pattern for this phase of your cycle."[cite:6][cite:10]

## 15. Feature prioritization and phased roadmap

The best roadmap is to ship the minimum coherent system that already expresses BADAN's differentiator: local-first cycle logging, uncertainty-aware forecasting, calm anomaly detection, and phase-aware baseline correction.[cite:6][cite:10][cite:12] Features that materially raise privacy or clinical-risk complexity, such as sexual activity, partner sharing, and narrow fertile-window claims, should be deferred until the foundation is proven.[cite:12][cite:29]

### Recommended phases

- **Phase 1 / v1 foundation:** manual period logging; flow logging; cycle history; next-period window prediction; core anomaly cards; contraceptive context; phase-aware recovery/HRV/RHR baselines; scoped export; dedicated consent and privacy controls.[cite:10][cite:12]
- **Phase 1.5:** symptom overlays, BBT logging, simple fertile-window estimate with explicit disclaimers, timeline/correlation hooks, import of basic historical CSVs.[cite:18][cite:38]
- **Phase 2:** ovulation test logging, cervical mucus logging, richer correlation lab, more configurable anomaly sensitivity, multilingual copy refinement, deeper write-back support to platform stores.[cite:21][cite:27]
- **Phase 3:** optional sharing models, advanced on-device insights, richer import adapters, and phase-conditioned strain/training analytics beyond baseline correction.[cite:14][cite:12]

## 16. Risks, anti-patterns, and features to avoid

The biggest anti-pattern is pretending precision that the data do not support.[cite:41][cite:43] Narrow ovulation claims from cycle length alone, single-date period promises despite high variability, or definitive phase labels from sparse data will break trust faster than a conservative estimate ever will.[cite:39][cite:41][cite:43]

The second major anti-pattern is privacy exceptionalism in marketing but not in architecture.[cite:20][cite:25][cite:28] BADAN should avoid third-party SDK creep, hidden cloud processing, sticky export toggles for sensitive data, ambiguous deletion semantics, or vague privacy language that says little more than "we care about your data."[cite:11][cite:12][cite:28]

The third anti-pattern is clinically suggestive anomaly UX.[cite:12][cite:46] Users may find pattern-deviation awareness helpful, but labels like "irregular," "disordered," "failed ovulation," or named-condition suggestions would move BADAN toward riskier territory without validated clinical basis.[cite:12][cite:41][cite:46]

The fourth anti-pattern is essentialist performance framing.[cite:45][cite:12] Cycle context can improve interpretation, but BADAN should never imply women are categorically weaker or less capable in certain phases; it should describe personal trends and uncertainty, not deterministic biological scripts.[cite:45][cite:12]

## 17. Implementation recommendations for BADAN

The implementation should begin by treating the cycle module as a sensitive-family extension of BADAN's existing repository model, not as a self-contained feature island.[cite:18][cite:10][cite:12] Concretely, that means new cycle entities in `badan_sensitive.db`, reuse of symptom tables where practical, append-only derived prediction/phase/anomaly records with input manifests, and explicit consent gates for sync, cloud AI, exports, and any highly sensitive sub-features.[cite:11][cite:12][cite:18]

The most important product-architecture decision is to compute phase-conditioned baselines in the core baseline engine rather than sprinkling cycle awareness into downstream copy.[cite:6][cite:10] This is what closes the documented WHOOP/Bevel gap: if recovery, HRV, RHR, sleep, and temperature models are not phase-aware at the baseline layer, then any overlay or narrative added afterward is cosmetic rather than corrective.[cite:6][cite:10][cite:45]

The most important UX decision is to present uncertainty clearly and kindly everywhere: next-period windows not single dates, phase confidence not hidden certainty, anomalies as personal deviations not diagnoses, and frictionless hide/retain/delete controls that reflect the sensitivity of the category.[cite:4][cite:12][cite:41] The most important trust decision is to make reproductive data meaningfully harder to expose than ordinary wellness data through local-first defaults, separate consents, default-off exports, and strict exclusion from cloud AI unless explicitly enabled.[cite:11][cite:12][cite:28]

### Backlog-ready implementation matrix

| ID | Capability | Phase | Owner | Dependencies | Approval needed | Proposed files/modules | Acceptance criteria |
|---|---|---|---|---|---|---|---|
| CYCLE-01 | Sensitive cycle schema and repositories | P1 | Core data/platform | Existing dual-DB architecture | No | `core-db` sensitive schema, repository interfaces, migrations | Cycle entities stored only in sensitive DB; architecture test blocks main DB placement[cite:12][cite:18] |
| CYCLE-02 | Dedicated cycle consent flow | P1 | Product + mobile platform | Consent service | Founder/legal review on copy | Consent center, onboarding screens, purpose copy | Separate sync/cloud-AI/export consents for cycle data function and are revocable[cite:11][cite:12] |
| CYCLE-03 | Manual period + flow logging UX | P1 | iOS/Android feature teams | CYCLE-01 | No | Cycle module UI, quick-log components | Repeat period log can be completed in <=3 interactions; backdating supported[cite:4][cite:10] |
| CYCLE-04 | Cycle history and next-period window forecast | P1 | Data science + feature teams | CYCLE-01, CYCLE-03 | No | Prediction engine, calendar views, anatomy sheet | Forecast shows range, confidence, method label; no single-date only states[cite:35][cite:41] |
| CYCLE-05 | Core anomaly engine | P1 | Data science | CYCLE-04 | Product review on copy | Detection rules, anomaly entity, message templates | Detects top 5 v1 anomaly classes with minimum-history gating and calm phrasing[cite:12] |
| CYCLE-06 | Phase-conditioned baseline support | P1 | Core scoring/baseline | CYCLE-04 | No | `core-baseline`, `core-scoring`, metric registry | Luteal-phase fixture no longer trips generic illness/poor recovery false alarms[cite:6][cite:10] |
| CYCLE-07 | Contraceptive/reproductive context logging | P1 | Feature teams | CYCLE-01 | No | Context forms, timeline integration | Predictions pause or broaden appropriately when suppressive context active[cite:10] |
| CYCLE-08 | Scoped sensitive export and purge controls | P1 | Core export + settings | CYCLE-01, consent service | Founder/legal review on wording | Export scope UI, module disable flow | Cycle export default-off every time; purge deletes rows and invalidates derived values[cite:12] |
| CYCLE-09 | Symptom overlay and correlation hooks | P1.5 | Symptom + analytics teams | Existing symptom model, CYCLE-03 | No | Symptom queries, overlays, correlation lab prereqs | Cycle-symptom overlays visible; associations remain non-causal and opt-in[cite:18][cite:36] |
| CYCLE-10 | BBT logging and signal-assisted phase refinement | P1.5 | Data science + feature teams | CYCLE-04 | No | Temp log UI, inference engine extensions | BBT inputs refine confidence when present; absent inputs never block core use[cite:21][cite:38] |
| CYCLE-11 | Historical CSV import | P2 | Import/export team | Import pipeline | No | Import parsers, mapping review UI | User can review and confirm imported periods before affecting predictions[cite:4][cite:15] |
| CYCLE-12 | Advanced fertility-awareness inputs | P2 | Feature teams | CYCLE-10 | Product/legal review on disclaimers | Ovulation and mucus UIs | Inputs fully opt-in; non-contraceptive disclaimers visible wherever fertile estimates shown[cite:21][cite:43] |
| CYCLE-13 | Sexual activity logging with elevated gating | P3 | Feature + privacy | CYCLE-02 | Founder/legal required | Separate secure views, granular permissions | Feature off by default, separately consented, and excluded from broad surfaces[cite:21][cite:29] |
| CYCLE-14 | Optional sharing model | P3 | Product + backend + privacy | CYCLE-02 | Founder/legal required | Sharing consent records, revocation flows | Per-field sharing, auditability, and one-tap revoke all work as designed[cite:11][cite:12] |

### V1 recommendation set

The recommended v1 capability set is:

1. Manual period start/end logging.[cite:10]
2. Flow logging with customizable scale mapping.[cite:21][cite:27]
3. Cycle history and prediction windows with confidence bands.[cite:35][cite:41]
4. Core anomaly cards based on personal baselines.[cite:12]
5. Phase-conditioned recovery, HRV, RHR, sleep, and temperature baselines.[cite:6][cite:10]
6. Symptom logging overlay using existing symptom infrastructure.[cite:18]
7. Contraceptive/reproductive-context logging that can pause or broaden predictions.[cite:10]
8. Separate cycle-data consent, sync, and cloud-AI gates.[cite:11][cite:12]
9. Scoped export with default-off sensitive inclusion.[cite:12]
10. Module hide, pause, retain, and purge controls.[cite:12]
