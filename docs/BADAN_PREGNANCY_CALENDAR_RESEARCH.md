# BADAN Pregnancy Calendar Research

## 1. Executive summary

Pregnancy tracking is the single highest-stakes domain BADAN can build. It combines the most legally sensitive personal data category that currently exists in consumer technology [web:20][web:19] with the highest emotional volatility of any health-tracking surface — anticipation, anxiety, and, for a meaningful share of users, loss. Public-health estimates place miscarriage at roughly 10–20% of known pregnancies and stillbirth at roughly 1 in 175 pregnancies in the US, meaning any pregnancy module *will* serve grieving users regularly, not as an edge case [web:28]. This document is a pre-engineering research and design foundation — not a spec, not code — for a BADAN pregnancy-tracking module that spans trying-to-conceive (TTC) awareness through birth and into a postpartum handoff, built strictly as a personal wellness organizer rather than a clinical or diagnostic tool.

The core design thesis is: BADAN never infers pregnancy, never diagnoses complications, and never lets a subscription or business decision hold pregnancy data hostage. Every mode transition is user-initiated. Every piece of week-by-week content is framed as general public-health education, not personalized medical guidance. Every self-logged pattern that could plausibly warrant medical attention is escalated with "this may be worth mentioning to your provider" language — never a diagnosis, never a triage score, never an urgency grade. This mirrors the two public lessons of the last decade in this category: the 2022 post-*Dobbs* period-tracking privacy crisis showed what happens when reproductive data leaves the device and reaches third parties or law enforcement [web:17][web:18][web:20][web:24], and the well-documented pattern of pregnancy apps failing catastrophically at loss (cheerful notifications continuing after a stated miscarriage, no pause button, forced "start over" flows) shows what happens when emotional design is treated as a backlog item instead of a foundational requirement [web:28].

The recommended architecture builds directly on BADAN's existing period-tracker and general health-log primitives (SymptomLog, WeightLog, MedicationLog, lab-results notebook) rather than creating a parallel data silo, consistent with BADAN's "one data model, two altitudes" law. The module is local-first by default, carries a distinct consent flow separate from BADAN's general permissions bundle, and applies BADAN's export-friction pattern with an extra layer of confirmation given the elevated stakes.

## 2. Research methodology and safety boundaries

This research draws from three categories of public information: (1) platform documentation for HealthKit's category and characteristic types related to reproductive health and pregnancy [web:1][web:10][web:12][web:13], and Health Connect's Cycle Tracking and Body Measurement data type categories [web:16]; (2) investigative and policy journalism on pregnancy/period-app privacy incidents, principally the Flo FTC settlement and the 2022 post-*Dobbs* wave of expert commentary from EFF, Mozilla, and academic security researchers [web:17][web:18][web:19][web:20][web:24][web:26]; and (3) publicly documented product/UX guidance on trauma-aware design for pregnancy loss [web:28].

No clinical guidelines, medical thresholds, or diagnostic criteria are reproduced or asserted anywhere in this document, and none should ever appear in BADAN's shipped content. Anywhere this document references "what week-by-week content typically covers" or "what symptom categories are commonly tracked," it is describing the *structural shape* of publicly known feature categories, not specific copyrighted text, and BADAN's own content must be independently authored or licensed and reviewed by a qualified clinical advisor before shipping. Every recommendation in Sections 4–9 is explicitly marked as either (a) a product-design decision BADAN's team can make directly, or (b) a decision requiring clinical, legal, or executive sign-off before implementation — this distinction is preserved throughout via inline flags and is consolidated in Section 17.

## 3. Pregnancy-tracking product philosophy for BADAN

Four commitments anchor this module, derived from BADAN's seven product laws:

- **The repository is sacred.** Pregnancy logs — dates, symptoms, appointments, loss records — are core repository data. They are never paywalled, never held behind a subscription lapse, and remain fully exportable in perpetuity, including after account downgrade or loss declaration.
- **Honesty over reassurance, kindness over alarm.** This is the module's prime directive. BADAN states facts plainly (a due date is an estimate, a pattern "may be worth mentioning") without either false reassurance ("this is definitely nothing") or manufactured alarm ("this could indicate X condition"). Every escalation nudges toward a human provider, never toward an in-app verdict.
- **One data model, two altitudes.** A casual user sees a calm week-by-week card and a due-date countdown; a power user sees the same underlying `PregnancyRecord`, `GestationalMilestone`, and provenance chain with full confidence intervals, source history, and raw exportable logs. No separate "lite" schema.
- **Provenance or it didn't happen.** Every due date, every gestational-age estimate, and every content recalculation carries a visible source (LMP estimate, conception-date estimate, user-entered provider due date, ultrasound-adjusted date) and a timestamp of when and how it was set or changed.

A fifth, module-specific commitment sits alongside these: **BADAN never infers pregnancy, loss, or fertility intent from behavioral or biometric data alone.** Mode transitions are exclusively user-declared. This is both an accuracy safeguard (algorithmic inference of pregnancy from cycle gaps is unreliable and produces false positives/negatives) and an emotional and legal safeguard, directly informed by the post-*Dobbs* lesson that inferred reproductive status is exactly the kind of signal that becomes dangerous when combined with other data or exposed to third parties [web:20][web:24][web:26].

## 4. Journey stages and mode model

BADAN's pregnancy journey is modeled as a set of explicit, user-declared modes rather than an automatically progressing state machine. Every transition requires an affirmative in-app action; none are inferred from missed periods, symptom patterns, or any other passive signal.

| Mode | Entry trigger | Available features | Notification behavior | Exit/transition paths |
|---|---|---|---|---|
| Trying-to-conceive (TTC) | User explicitly opts into TTC mode from period tracker or pregnancy module entry point | Fertile-window awareness (inherited from period tracker), BBT/cervical-mucus/ovulation-test logging, TTC-specific mood check-ins, "confirm pregnancy" and "pause TTC" actions | Gentle, low-frequency fertile-window reminders (opt-in), no countdown pressure language | User declares pregnancy confirmed → Pregnancy-confirmed mode; user pauses/exits → back to general period tracker |
| Pregnancy-confirmed | User explicitly declares pregnancy (never inferred); user chooses due-date source at declaration | Due-date model activates, week-by-week content begins, appointment/symptom/weight logging | Milestone and appointment reminders (opt-in, adjustable frequency) | User declares loss → Loss/miscarriage mode; user reaches late pregnancy → Late-pregnancy mode; user corrects a mistaken entry → back to TTC or general tracking with confirmation |
| Week-by-week gestational tracking | Automatic sub-mode of Pregnancy-confirmed once a due-date source exists | Weekly educational content, milestone checklist, screening/test logging handoff to lab notebook | Weekly content notification (opt-in), appointment reminders | Rolls into Late-pregnancy mode near term; or Loss mode at any point |
| Late-pregnancy | Automatic content shift near term (still within Pregnancy-confirmed mode, not a separate declared mode) or user manually opts in earlier | Kick counter, contraction timer, hospital-bag/birth-plan checklist | Reduced non-essential notifications; users can mute all "how many weeks left" countdown messaging | User logs birth/delivery entry → Postpartum handoff; or Loss mode |
| Birth/delivery logging | Single user-initiated entry ("log birth") | One structured, low-friction event: date, basic outcome fields (live birth, stillbirth if user chooses to record), free-text note | No automated notification tied to this entry | Immediately offers (never forces) transition to Postpartum handoff mode |
| Postpartum handoff | Automatic offer after birth/delivery log, or manual entry any time | Recovery symptom tracking, feeding log (if in scope), mood check-ins, cycle-return awareness reconnecting to period tracker | Postpartum-specific check-in reminders (opt-in), mental-health resource surfacing | User resumes general tracking, or re-enters TTC mode for a subsequent pregnancy |
| Loss/miscarriage handling | User explicitly declares a loss, at any point from TTC through late pregnancy | Immediate content and notification suppression; grief-aware resource surfacing; data preserve/archive/delete choice; gentle re-entry path | All scheduled pregnancy notifications suppressed immediately upon declaration — not within 24 hours, immediately, per documented best practice [web:28] | User may re-enter TTC mode, general tracking, or request module deletion at their own pace, with no "explain yourself" gate |

Design notes carried through every mode: (1) no mode ever displays a "you seem to be pregnant" or "you seem to have stopped tracking your pregnancy" inferential prompt; (2) exiting or pausing any mode is always available within one or two taps, never buried in settings, directly following the trauma-aware design principle that pause controls must be immediately reachable [web:28]; (3) re-entering a mode after a pause or loss never resets historical context or forces the user to "start over," consistent with documented failure patterns in mainstream pregnancy apps [web:28].

## 5. Due-date and gestational-age model

BADAN must model gestational age as an estimate with explicit uncertainty, never as a precise clinical fact, and must always make the active estimation source visible to the user.

**Estimation methods, in priority order (highest priority first):**

1. **Provider-given due date (user-entered).** If a user's own clinician has given a due date, that value always overrides any BADAN-calculated estimate. This is the single highest-priority source because a clinical ultrasound-based estimate is more accurate than app-side math, and because deferring to the provider reinforces BADAN's role as an organizer, not an authority.
2. **Ultrasound-adjusted due date (user-entered).** When a user logs an ultrasound-based adjustment (a common real-world event, since first-trimester ultrasound dating is widely used to refine LMP-based estimates), BADAN treats this as an update to the provider-given source, not a new independent calculation.
3. **Conception-date-based estimation.** If a user knows or estimates a specific conception date (common in TTC-tracked pregnancies using ovulation data from the period tracker), BADAN can calculate an estimated due date from that date using a standard convention, framed explicitly as an estimate.
4. **LMP-based estimation.** The last-menstrual-period-based method is available for users who don't have conception-date data, and should be visibly flagged as the least precise of the four sources given natural cycle-length variation.

**Handling due-date changes:** When a due date changes (e.g., a user updates from LMP-based to ultrasound-adjusted), BADAN must recalculate week-by-week content and milestones without abrupt or jarring shifts — for example, avoiding a scenario where a user "loses" a week of already-viewed content or is shown two conflicting countdowns simultaneously. The UI should show a brief, calm transition message (e.g., "Your due date has been updated based on new information — your calendar has been adjusted") rather than silently recalculating in the background.

**Communicating uncertainty:** For TTC-stage and early-pregnancy estimates, BADAN should present a range rather than a single date wherever the underlying method supports it (e.g., "your estimated due date is around March 12, based on your logged cycle data — this is an estimate, not a diagnosis"), avoiding the false precision that a bare date implies. Every due-date display should carry a persistent, non-intrusive indicator of *which* source is currently active (provider / ultrasound-adjusted / conception-based / LMP-based) and a one-tap way to view or change that source, satisfying BADAN's provenance law at the highest-stakes point in the whole module.

**Flag for clinical review:** The exact multi-week conventions used for conception-date and LMP-based calculations (i.e., which standard weeks-from-event formulas BADAN uses) should be validated against current public-health guidance by a clinical advisor before shipping, and the phrasing of uncertainty ranges should go through the same review.

## 6. Week-by-week content and milestone system

**Structural model for week-by-week content.** Rather than reproducing any existing app's specific text, BADAN's content architecture should be built as a generic, versioned content schema: each gestational week maps to a content card with fields for (a) general fetal-development-stage information sourced from public-health-education material and independently authored/licensed, (b) a common-symptoms-this-stage note framed descriptively ("many people report X around this stage"), never predictively or diagnostically, and (c) a mandatory disclaimer block rendered identically on every card. This content must be trimester-aware in tone: first-trimester content should acknowledge uncertainty and the higher likelihood of early loss without being alarmist; second-trimester content can shift toward practical logistics (appointments, screenings); third-trimester content should shift toward late-pregnancy preparation (Section 4's late-pregnancy mode) and explicitly avoid urgency-inducing language.

**Milestone/checklist system.** Appointments, tests, and screenings are modeled as user-loggable calendar-style events, not as a source of medical scheduling advice — BADAN should never tell a user "you should schedule your anatomy scan this week" as though it were a clinical recommendation. Instead, the system offers a generic, editable checklist template ("common milestones people track") that a user populates with their own provider's actual schedule, explicitly framed as an organizer, not an authority on care timing.

**Multiples handling.** If twins/triplets are in scope, the `PregnancyRecord` entity (Section 12) should support a multiples flag and multiplier field, and week-by-week content should branch to multiples-aware variants (e.g., acknowledging that multiples pregnancies commonly progress on a different typical timeline) without asserting specific clinical thresholds unique to multiples care — this branch content requires clinical review before shipping given how much multiples-specific guidance genuinely does differ from singleton pregnancies.

**Due-date-change handling for content:** As described in Section 5, a due-date change must trigger a smooth content recalculation rather than a jarring jump; the milestone checklist should preserve any already-completed items even after the week numbering shifts.

**Mandatory disclaimer requirement:** Every week-by-week content screen, without exception, must display: "This is general educational information, not medical advice or a personalized recommendation. Always follow your provider's guidance for your specific pregnancy." This disclaimer should be persistent and visually integrated (a footer treatment, not a dismissible banner that disappears after first view), directly following the requirement for a "persistent, unobtrusive but clear" disclaimer strategy rather than a one-time popup (Section 8).

## 7. Logging and tracking inputs

| Input | Required fields | Optionality | Default visibility | Safety-copy requirement |
|---|---|---|---|---|
| Weight tracking | Weight value, date, unit | Fully optional | Private, integrated into general weight history with a pregnancy-context tag | None beyond general "not diagnostic" framing |
| Symptom logging (nausea, fatigue, swelling, mood, sleep, custom) | Symptom type, severity/free text, date/time | Fully optional, extensible with user-defined symptoms | Private | Severe or sudden-onset symptom entries should surface the standard provider-contact nudge (Section 8) |
| Appointment logging | Date, provider name/type, notes, next-appointment reminder toggle | Fully optional | Private | Framed explicitly as personal-organizer, not a clinical record or reminder-of-care-standard system |
| Test/screening logging | Test name, date, result summary, link to lab-results notebook entry | Optional, but recommended integration point | Private, cross-linked to lab notebook | Result summaries must never be auto-interpreted by BADAN; link out to lab notebook for full context |
| Medication/supplement logging | Name, dose, frequency, start/end date | Fully optional | Private | Explicit "this is your own record, not prescribing guidance" framing; never suggest dosage or interactions itself |
| Kick counter | Session start/end time, kick count, optional notes | Fully optional, session-based | Private | Must display "contact your provider if movement feels different than usual for you" — a baseline-relative, non-numeric-threshold phrasing (see Section 8) |
| Contraction timer | Start/stop timestamps per contraction, computed duration and interval | Fully optional, session-based | Private | Must be labeled explicitly as a stopwatch utility; must never claim to indicate labor stage or urgency |
| Mood/mental-health check-ins | Mood scale or free text, date | Fully optional | Private | Always paired with a visible, one-tap link to professional mental-health support resources, given the well-established importance of perinatal mental health |
| Hospital-bag/birth-plan checklist | User-editable checklist items | Fully optional | Private | None beyond general organizer framing |
| Belly-photo/memory journal | Photo/media, optional caption, date | Fully optional, private-by-default | Private, never auto-shared | Standard media-privacy framing; no safety-copy needed beyond general privacy assurance |

The kick counter and contraction timer deserve particular care because they are the two inputs most likely to be used in a moment of real anxiety. Both must avoid any numeric "normal/abnormal" threshold language (e.g., never asserting a specific kick count as clinically "normal") and must instead direct users to their own provider's guidance for what counts as a meaningful change for their specific pregnancy, paired with the universal "contact your provider" phrasing defined in Section 8.

## 8. Safety, disclaimers, and escalation language

This is the most consequential section of the entire research document, and every phrase proposed here should be treated as a first draft requiring clinical and legal sign-off before shipping — not as final copy.

**Persistent disclaimer strategy.** Rather than a single onboarding popup (which is reliably ignored and forgotten), BADAN should embed a lightweight, consistent disclaimer treatment into every pregnancy-content surface: a small, permanently visible footer or inline note reading something close to "General information, not medical advice — always follow your provider's guidance." This should appear on week-by-week content, kick-counter and contraction-timer screens, and any symptom-pattern summary view, using consistent visual treatment so it becomes a recognizable, trusted part of the interface rather than a legal afterthought.

**Provider-contact escalation language.** Any time BADAN surfaces a self-logged pattern that could plausibly warrant medical attention — a symptom marked severe, a kick-count session the user personally flags as unusual, a contraction pattern the user is timing with concern — the copy must consistently use the frame "this may be worth mentioning to your provider," never a diagnosis, never a severity score, never a triage classification. BADAN must not attempt to grade urgency (no "this looks mild/moderate/severe" language), because doing so would constitute an unlicensed clinical judgment.

**Draft language templates** (all require legal/clinical review before shipping):

- *Normal educational content:* "Here's some general information about what's commonly discussed around week [N] of pregnancy. This is educational information only, not a personalized recommendation — your provider knows your specific pregnancy best."
- *Gentle awareness nudge (e.g., after several days of a new symptom logged):* "You've logged [symptom] for a few days in a row. Many people experience this at some point in pregnancy, but if it's concerning you, it's worth mentioning at your next appointment or sooner if it feels urgent."
- *Provider-contact suggestion (e.g., user flags reduced movement or unusual bleeding):* "What you've described may be worth contacting your provider about. If you're ever unsure or concerned, your provider or a labor-and-delivery line is always the right place to check — BADAN can't assess this for you."
- *Emergency-adjacent framing (used only as a persistent, always-visible footer near kick-counter/contraction-timer tools, not as a triggered pop-up):* "If you feel something is seriously wrong, please contact your provider or emergency services right away rather than waiting on an app."

**What BADAN must never do**, as hard constraints: never claim to detect or predict a complication; never present a gestational-age-specific number (kick counts, contraction intervals, weight-gain ranges) as if it were a clinically authoritative threshold; never use language that could be read as discouraging a user from seeking care ("this is probably nothing" is prohibited); never insert an in-app flow, chatbot conversation, or additional screen between a user expressing a possible emergency and a direct, immediate real-world contact prompt.

**"When in doubt" pattern.** Any screen displaying a self-logged pattern that the user themselves has flagged as concerning (via a severity marker, a free-text note, or an explicit "this felt different" toggle) must include, without exception, a visible "if you're ever in doubt, contact your provider or emergency services" line — this is a non-negotiable universal pattern rather than a conditional one, because false negatives (failing to show it) are far more dangerous than the minor redundancy of showing it often.

**Content and tone review checklist before shipping** (draft, to be finalized with legal/clinical advisor):
1. Does every content screen carry the persistent disclaimer footer?
2. Does any content assert a specific clinical threshold, statistic, or diagnostic criterion as fact rather than attributing it to general public-health education?
3. Does any escalation copy imply a diagnosis, a severity grade, or an urgency ranking?
4. Does any copy discourage or delay real-world provider contact in any scenario?
5. Has multiples-specific and loss-adjacent content been independently reviewed given their higher clinical-sensitivity profile?
6. Has the due-date/gestational-age uncertainty language been checked against current public-health estimation conventions?
7. Has legal counsel reviewed regional considerations (Section 11) for the target launch markets?

## 9. Emotional design for loss and uncertainty

Loss handling must be a foundational design principle from day one, not a retrofitted settings toggle — this is the single clearest lesson from documented failures in mainstream pregnancy apps, where cheerful due-date countdowns and milestone notifications continued after a stated loss because no one built a path to declare it [web:28].

**Immediate, low-friction loss declaration.** A "log a loss" or equivalent option must be reachable within one or two taps from anywhere in the pregnancy module, never buried in settings and never requiring the user to navigate through active pregnancy content to find it.

**Immediate notification suppression.** The instant a loss is declared, all scheduled countdown notifications, weekly milestone content, and celebratory messaging must stop immediately — not "within 24 hours," immediately — matching the explicit standard documented as best practice in this domain [web:28].

**No forced justification.** The loss-declaration flow should require only the minimum fields needed (approximate date, optional gestational stage if the user wants to record it) and must never require an explanation, a cause, or any additional detail the user doesn't choose to provide. This should extend to the `LossDeclarationRecord` entity design in Section 12: minimal required fields, maximal optionality.

**Grief-appropriate language, not clinical detachment or forced positivity.** Any acknowledgment BADAN shows after a loss declaration should be simple, honest, and warm — no euphemism, no rushed reframing toward "trying again," no forced silver-lining language. A single, sincere acknowledgment plus a calm offer of next steps (resources, data choices) is preferable to an elaborate message.

**Resources, not a redirect.** BADAN should surface both practical next-step information categories (what's commonly discussed physically after a loss, framed as general education, always paired with a provider-contact nudge) and mental-health resources (crisis lines, grief support, professional-help guidance) directly within the acknowledgment flow — not merely a link to a community forum, which documented critiques note is not a substitute for the product itself responding appropriately [web:28].

**User-controlled data disposition.** After a loss, the user must be offered a genuine, unpressured choice to keep, archive, or delete their pregnancy data for that pregnancy — with no default that quietly favors deletion (which could feel like erasure) or quietly favors retention (which could feel intrusive). This choice should be revisitable later, not a one-time forced decision at the moment of loss.

**Re-entry without "starting over."** If a user later returns to TTC mode or a new pregnancy-confirmed mode, their prior history — including the loss — should remain part of their record rather than being wiped or treated as if they were a first-time user, consistent with the principle that a compassionate product "remembers" rather than resets [web:28]. This also applies to users with a history of loss who are newly pregnant or in TTC mode: BADAN should allow (never force) a lighter-touch content pacing option for anxious users, reducing celebratory or milestone-triggered content by default unless the user opts back in.

**Fertility-treatment context.** Users who conceive via fertility treatment may want a different content pacing (e.g., delayed excitement framing given higher early-loss risk in some treatment contexts, or specific milestone tracking tied to treatment cycles rather than LMP). BADAN should offer an optional "conceived via fertility treatment" context flag that adjusts content pacing without requiring the user to disclose treatment details beyond what they choose to log.

## 10. Integration with the rest of BADAN

**Period tracker.** The pregnancy module shares cycle history and fertile-window logic with BADAN's existing period tracker rather than duplicating it — TTC mode is best modeled as an overlay/extension of the period tracker's existing fertile-window estimation, not a separate calculation engine. When pregnancy is confirmed, BADAN should pause (not delete) period-cycle predictions, and postpartum handoff mode should reactivate cycle-return awareness by resuming period-tracker logic once the user is ready.

**Lab-results notebook.** Prenatal screening and test results should be logged as lab entries within BADAN's existing lab-results notebook module, tagged with pregnancy-specific context (gestational week at time of test, associated `PregnancyRecord` ID) rather than existing in a separate results store. This is an explicit handoff point: the pregnancy module's `ScreeningTestReference` entity (Section 12) should link to, not duplicate, the underlying lab-notebook entry.

**Medication logging.** Pregnancy-related medication and supplement entries reuse BADAN's general medication-log entity, adding a pregnancy-context tag rather than a separate schema, consistent with the "one data model, two altitudes" law.

**Weight and nutrition tracking.** Pregnancy weight entries reuse BADAN's general weight-tracking entity with a pregnancy-context tag and gestational-week annotation, allowing casual users to see a calm pregnancy-aware weight chart while power users can inspect the full underlying weight history unfiltered by pregnancy context. Nutrition tracking integration should similarly tag pregnancy-relevant entries without duplicating the underlying nutrition log.

**Mood/symptom logging.** The pregnancy module's mood check-ins and symptom logs are extensions of BADAN's general `SymptomLog` and mood-tracking entities, adding pregnancy-mode context tags — this preserves a single longitudinal mood/symptom history that spans pre-pregnancy, pregnancy, and postpartum periods rather than fragmenting it.

**Export system.** A full pregnancy-journey export (due-date history, week-by-week logs, appointments, symptoms, kick/contraction sessions, loss records if present) should be available at any time, governed by the same extra-confirmation friction pattern BADAN uses for other highly sensitive modules — this satisfies the "repository is sacred" law even for the most emotionally weighted data BADAN holds.

**Notification/quiet-hours system.** Pregnancy-module notifications must respect BADAN's existing quiet-hours and notification-preference system, and additionally support the loss-triggered full-suppression behavior described in Section 9, which should override any standing notification preference immediately upon declaration rather than waiting for the next quiet-hours cycle.

## 11. Privacy and safety architecture

Pregnancy data is arguably BADAN's most sensitive data category, given the documented post-*Dobbs* precedent of reproductive-health data being sought via subpoena, sold by data brokers, or exposed through third-party SDK sharing [web:17][web:18][web:20][web:24][web:26]. The architecture must reflect this directly:

- **Local-first storage priority.** Pregnancy data should default to on-device storage, mirroring the documented privacy-expert recommendation that locally stored health data requires a warrant (a materially higher legal bar) to access, versus cloud-stored data which may be obtainable via subpoena [web:20][web:24].
- **Separate, explicit consent flow.** Enabling the pregnancy module should trigger its own consent screen, distinct from BADAN's general permissions bundle, explaining specifically what pregnancy data is collected, where it is stored, and who (if anyone) can access it — never bundled silently into a general "allow health tracking" toggle.
- **No third-party SDK or analytics exposure.** No analytics, crash-reporting, or advertising-adjacent SDK should receive any signal — even aggregated or pseudonymized — tied to pregnancy-module usage, mode transitions, or content views. This directly addresses the documented Flo/Facebook signal-sharing incident that triggered the FTC settlement [web:19][web:26].
- **Rapid full-module deletion.** Users must be able to delete the entire pregnancy module's data, including all historical records, in a single clear action, separate from general account deletion, with no forced multi-step "are you sure" gauntlet beyond one reasonable confirmation.
- **Elevated export-confirmation friction.** Exporting pregnancy data should require an explicit, separate confirmation step beyond BADAN's standard export flow, given the elevated sensitivity — this is a deliberate extra layer of friction, not an obstruction, aimed at preventing accidental or coerced disclosure.
- **No cross-system inference or exposure without explicit, repeated, revocable consent.** BADAN must never use pregnancy-module data to infer or expose pregnancy status to any other system, integration, calendar sync, or notification channel (including partner-sharing features) without explicit, specific, and revocable consent obtained separately from general sharing permissions.
- **Explicit legal/product review flags.** Given known regional legal sensitivities around pregnancy and reproductive-health data (documented extensively in the post-*Dobbs* US context [web:17][web:18][web:20][web:24][web:26], and relevant to Oman and the broader GCC region's own distinct legal and cultural context around reproductive health data), this module requires a dedicated legal review pass before any regional launch, specifically covering: data-residency requirements, law-enforcement request handling procedures, and appropriate default consent language for the target market.

## 12. Data model and technical architecture

| Entity | Purpose | Key fields | Provenance/confidence fields | Storage tier | Export behavior |
|---|---|---|---|---|---|
| `PregnancyRecord` | Root record for a single pregnancy journey | Mode/stage, start basis, due-date source, due-date value, multiples flag/count, fertility-treatment context flag | Due-date source type, confidence range, source-change history log | Local-first, encrypted at rest | Included in full pregnancy export; extra confirmation required |
| `GestationalMilestone` | Tracks milestone/checklist items tied to gestational week | Milestone name, target week, completion date, user notes | Content-version ID (which content schema version generated this) | Local-first | Included in export |
| `AppointmentLog` | Personal-organizer record of appointments | Date, provider name/type, notes, reminder toggle | Entry timestamp, edit history | Local-first | Included in export |
| `KickCountSession` | Session-based kick-counting tool data | Start/end time, kick count, optional notes | Session ID, device/entry timestamp | Local-first | Included in export |
| `ContractionEvent` | Individual contraction timing entries | Start/stop timestamp, computed duration/interval | Session grouping ID, entry timestamp | Local-first | Included in export |
| `PregnancySymptomLog` | Pregnancy-context extension of general `SymptomLog` | Symptom type, severity, free text, date/time, pregnancy-context tag | Links to base `SymptomLog` entity, gestational week at entry | Local-first | Included in export, same schema as general symptom export plus context tag |
| `PregnancyWeightLog` | Pregnancy-context extension of general weight entity | Weight value, date, unit, gestational-week annotation | Links to base weight entity, pregnancy-context tag | Local-first | Included in export |
| `ScreeningTestReference` | Links pregnancy screening/test events to lab-results notebook | Test name, date, gestational week, link to lab-notebook entry ID | Linked lab-entry provenance (inherits notebook's own provenance chain) | Local-first, cross-references lab-notebook storage tier | Included in export, references linked lab entry |
| `LossDeclarationRecord` | Minimal-field record of a declared loss | Approximate date, optional gestational stage, optional free-text note | Declaration timestamp, linked `PregnancyRecord` ID | Local-first, highest privacy tier | Included in export only with explicit separate confirmation; deletable independently |
| `PostpartumHandoffRecord` | Bridges pregnancy record to postpartum tracking | Birth/delivery date, handoff-accepted timestamp, linked feeding/mood/recovery log references | Linked `PregnancyRecord` ID, mode-transition timestamp | Local-first | Included in export |
| `ModuleVisibilitySetting` | User's visibility/notification preferences for the module | Notification toggles, quiet-hours overrides, content-pacing preference (e.g., reduced-celebration mode) | Setting-change history | Local-first | Included in export for completeness, low sensitivity |
| `SharingConsentRecord` | Records explicit partner/support-person sharing consent | Grantee identifier, scope of shared data, grant/revoke timestamps | Consent-event history, revocation timestamp if applicable | Local-first, highest privacy tier | Included in export; revocation must be immediate and logged |

## 13. Health platform integration map

**HealthKit.** Apple's HealthKit exposes a dedicated `HKCategoryTypeIdentifier.Pregnancy` category type as of recent HealthKit versions, alongside related types including `PregnancyTestResult`, `ProgesteroneTestResult`, `Lactation`, `BleedingDuringPregnancy`, and `BleedingAfterPregnancy` [web:10]. HealthKit's long-standing Reproductive Health category also includes basal body temperature, cervical mucus quality, menstruation, ovulation test results, sexual activity, and spotting [web:1][web:12]. BADAN should plan to read and write the `Pregnancy` category type as a lightweight boolean/interval signal (with explicit user consent) so that other HealthKit-aware apps and Apple's own Health app reflect BADAN's user-declared pregnancy status, while treating this as a one-way convenience sync rather than a primary source of truth — HealthKit values should never be used to *infer* pregnancy status back into BADAN, consistent with the no-passive-inference principle in Section 3.

**Health Connect.** Android's Health Connect organizes relevant data under its "Cycle Tracking" category, which includes `BasalBodyTemperatureRecord`, `CervicalMucusRecord`, `IntermenstrualBleedingRecord`, `MenstruationFlowRecord`/`MenstruationPeriodRecord`, `OvulationTestRecord`, and `SexualActivityRecord` [web:16]. As of current public documentation, Health Connect does not expose a dedicated first-class "pregnancy status" record type comparable to HealthKit's `Pregnancy` category — BADAN's Android integration should therefore focus on writing relevant Cycle Tracking and Body Measurement (weight) records where a clear mapping exists, while treating pregnancy-mode status itself as a BADAN-internal signal not mirrored to Health Connect until/unless Android introduces an equivalent type. This asymmetry between platforms should be clearly documented internally and flagged for periodic review as both platforms evolve.

**Calendar integration.** Appointment entries in `AppointmentLog` should support export to the device's native calendar (iOS Calendar / Android Calendar) as a convenience feature, explicitly framed as a personal-scheduling export rather than a clinical scheduling system — BADAN should never auto-create calendar events without user confirmation of each one.

**Lab-results notebook handoff.** As described in Section 10 and modeled via `ScreeningTestReference`, this is an internal BADAN-to-BADAN integration point rather than an external platform integration, but it should be documented with the same rigor: the pregnancy module writes a reference record, the lab-notebook module owns the underlying result data and its own provenance chain.

**Export formats.** Pregnancy-module exports should support BADAN's standard structured export format (for full data portability, consistent with the "repository is sacred" law) and a human-readable summary format (e.g., a calm PDF or document summarizing the pregnancy journey for a user's own personal records or for sharing with a new provider) — both gated behind the elevated export-confirmation friction described in Section 11.

## 14. Casual-user experience

A casual user's experience should feel like a calm, low-effort companion rather than a data-entry chore. On confirming pregnancy, they see a single clean due-date estimate with a simple source label, a gentle weekly content card, and a small set of one-tap loggers (weight, symptom, mood) that require no configuration. Notifications are opt-in and infrequent by default. The kick counter and contraction timer are presented as simple, obvious tools with minimal setup — tap to start, tap to log, done — with the safety-copy footer always visible but never intrusive. A casual user experiencing a loss should be able to find the "log a loss" option within one or two taps without ever having seen it before, because it should be a persistently discoverable (though unobtrusive) affordance from the very first time pregnancy mode is entered, not something that only becomes visible after searching.

## 15. Power-user experience

A power user should be able to see the full underlying data model: the complete due-date source history with timestamps of every change, raw exportable logs for every kick-counting session and contraction event with computed statistics (average interval, session duration trends), the full provenance chain for every screening test linked to the lab notebook, and granular notification/quiet-hours overrides specific to the pregnancy module. Power users should also be able to inspect and export the raw underlying `SymptomLog`, weight, and medication entries filtered by pregnancy-context tag versus unfiltered, reinforcing that this is the same data model as the rest of BADAN, simply surfaced with more detail and less abstraction.

## 16. Wellness-safe language guide and phrasing library

**Always use:** "general educational information," "this is an estimate," "worth mentioning to your provider," "many people experience," "your provider knows your specific situation best," "if you're ever in doubt, contact your provider or emergency services."

**Never use:** "this means," "this indicates," "you have," "this is normal/abnormal" (as an app-asserted verdict), "don't worry," "this is probably nothing," "seek care immediately" framed as an app-generated triage decision rather than a general safety reminder, "diagnosis," "risk score," any numeric threshold presented as a clinical cutoff.

**Tone calibration by trimester:** First trimester — cautious, acknowledging uncertainty, avoiding premature celebration; second trimester — practical and organizational; third trimester — calm and preparation-focused, deliberately avoiding urgency language even when discussing labor-adjacent tools.

**Tone calibration for loss/anxiety contexts:** Warm, unhurried, non-euphemistic, resource-forward, never rushing toward positivity or resolution.

## 17. Feature prioritization and phased roadmap

**Phase 1 (v1 — foundational, lowest clinical-copy risk):** Mode model with explicit user-declared transitions; due-date model with all four sources and provenance display; basic week-by-week content shell with persistent disclaimer (content itself pending clinical review); weight/symptom/appointment logging via existing BADAN entities; loss-declaration flow with immediate notification suppression; local-first storage and separate consent flow; basic export with elevated friction.

**Phase 2 (v1.1 — expanded logging and integrations):** Kick counter and contraction timer (safety copy fully reviewed before launch); medication/supplement logging; lab-notebook handoff via `ScreeningTestReference`; calendar export for appointments; HealthKit `Pregnancy` category read/write.

**Phase 3 (v1.2 — emotional depth and postpartum):** Mood/mental-health check-ins with resource surfacing; hospital-bag/birth-plan checklist; postpartum handoff mode with feeding/recovery/mood tracking and cycle-return awareness; multiples-aware content branching (pending clinical review).

**Phase 4 (v1.3 — sharing and polish):** Belly-photo/memory journal; `SharingConsentRecord`-based partner sharing (pending legal review of consent model); Health Connect integration as platform support matures; regional legal-review-gated launch expansion.

## 18. Risks, anti-patterns, and features to avoid

- **Passive pregnancy inference from cycle gaps or symptom patterns** — never build this; it is both inaccurate and the exact pattern that creates legal exposure documented in post-*Dobbs* commentary [web:20][web:24][web:26].
- **Numeric clinical thresholds presented as app-native facts** (e.g., a specific kick count or weight-gain range asserted as "normal") — this constitutes unlicensed clinical guidance and must never ship.
- **Celebratory or milestone-triggered content that cannot be proactively disabled after a loss** — documented as one of the most harmful and preventable failures in this product category [web:28].
- **Third-party analytics or ad SDKs receiving any pregnancy-module signal, even pseudonymized** — directly informed by the Flo/Facebook incident [web:19][web:26].
- **Forced "start over" flows after a loss or pause** — erases user history and causes real harm; must never ship.
- **Urgency-graded triage language or anything resembling a diagnostic score** — outside BADAN's scope and legally risky.
- **Bundling pregnancy-module consent into general health-permission consent** — reduces user agency over the most sensitive data category BADAN holds.
- **Cloud-first default storage for this module** — increases legal exposure to subpoena-based access relative to local-first, warrant-gated storage [web:20][web:24].

## 19. Implementation recommendations for BADAN

BADAN should treat this module as a distinct, carefully gated workstream rather than a routine feature addition, given its unique combination of legal sensitivity, emotional stakes, and clinical-adjacency. The recommended sequencing is: (1) finalize the mode model, due-date provenance model, and privacy/consent architecture first, since these are foundational and hard to retrofit; (2) draft all safety-copy and disclaimer language early and route it through legal/clinical review in parallel with engineering rather than after; (3) build loss-handling as a first-class feature alongside — not after — the core pregnancy-confirmed flow, since retrofitting it is exactly the documented failure pattern this research warns against [web:28]; (4) reuse BADAN's existing SymptomLog, weight, and medication entities rather than creating parallel schemas, preserving the "one data model, two altitudes" law; (5) treat every piece of week-by-week or milestone content as requiring independent authorship or licensing plus clinical review — none of it should be adapted from any specific existing app's text; and (6) commit to local-first storage and a distinct consent flow from day one, since this is materially harder to retrofit into a cloud-first architecture later.

## Feature matrix

| Feature | Casual value | Power-user value | Required data | HealthKit support | Health Connect support | Privacy tier | Safety-copy required | Complexity | Priority | BADAN recommendation |
|---|---|---|---|---|---|---|---|---|---|---|
| TTC fertile-window awareness | Simple reminder of fertile window | Full cycle/BBT/ovulation-test data history | Cycle data (from period tracker), optional BBT/ovulation logs | Yes (Reproductive Health category) [web:1][web:12] | Yes (Cycle Tracking category) [web:16] | High | Low (general awareness framing) | Low | P1 | Build on existing period-tracker logic |
| Due-date model with provenance | Single clear due-date display | Full source history and confidence ranges | User-declared pregnancy, due-date source data | No direct equivalent | No direct equivalent | High | Medium (uncertainty framing) | Medium | P1 | Core v1 feature |
| Week-by-week content | Calm weekly card | Full content-version history | Gestational week (derived) | No | No | Medium | High (mandatory disclaimer) | Medium | P1 shell / content pending clinical review |
| Weight logging (pregnancy-tagged) | Simple entry | Full chart with context filter | Weight value, date | Yes (Body Measurements) [web:6] | Yes (Body Measurement category) [web:16] | High | Low | Low | P1 | Reuse general weight entity |
| Symptom logging | Quick tap-to-log | Full symptom history, custom types | Symptom type, severity, date | Partial (HealthKit symptom category types) [web:10] | No direct equivalent | High | Medium (severe-symptom nudge) | Low | P1 | Reuse general SymptomLog |
| Appointment logging | Simple reminder | Full history with notes/export | Date, provider, notes | No | No | High | Low | Low | P1 | Personal organizer only |
| Screening/test logging → lab notebook | Simple link-out | Full linked provenance chain | Test name, date, linked lab entry | No | No | High | Medium (no auto-interpretation) | Medium | P2 | Explicit handoff, no duplication |
| Medication/supplement logging | Simple entry | Full dose/frequency history | Name, dose, dates | Yes (general medication types) | No direct equivalent | High | Medium (not prescribing guidance) | Low | P2 | Reuse general medication log |
| Kick counter | Simple session tool | Session history and stats | Start/end time, count | No | No | High | High (baseline-relative language only) | Low | P2 | Ship only after safety-copy review |
| Contraction timer | Simple stopwatch tool | Interval/duration history | Start/stop timestamps | No | No | High | High (stopwatch framing only) | Low | P2 | Ship only after safety-copy review |
| Mood/mental-health check-ins | Simple mood entry | Full mood history trend | Mood value/text, date | Yes (Mindfulness/State of Mind types) | Yes (Wellness/Mindfulness category) [web:16] | High | High (always paired with resources) | Low | P3 | Always show support resources |
| Hospital-bag/birth-plan checklist | Editable checklist | Full custom checklist history | Checklist items | No | No | Medium | Low | Low | P3 | Personal organizer only |
| Belly-photo/memory journal | Simple private log | Full media history export | Photo/media, date | No | No | High | Low | Medium | P4 | Private-by-default |
| Loss declaration and suppression | One-tap declare, immediate silence | Full record with disposition choice | Approximate date (minimal) | No | No | Highest | Highest (grief-aware language) | Medium | P1 | Foundational, not retrofitted |
| Postpartum handoff | Simple mode offer | Full recovery/feeding/mood tracking | Birth date, linked record | Partial (Lactation category) [web:10] | No direct equivalent | High | Medium | Medium | P3 | Reconnects to period tracker |

## Safety-language matrix

| Scenario | Trigger | Required disclaimer | Provider-contact language | What must never be said | Review sign-off required |
|---|---|---|---|---|---|
| Week-by-week educational content view | User views any weekly content card | "General educational information, not medical advice or a personalized recommendation" | Not applicable (informational only) | Any claim framed as personalized medical guidance | Legal + clinical |
| Symptom logged as severe or unusual | User marks a symptom entry as severe/concerning | Standard disclaimer footer | "This may be worth mentioning to your provider" | Any diagnostic label or severity grade | Clinical |
| Kick-counter session with user-flagged reduced movement | User notes movement felt different than usual | Standard disclaimer footer | "Contact your provider if movement feels different than usual for you" | Any specific numeric "normal" kick-count threshold | Clinical + legal |
| Contraction-timer active use | User is actively timing contractions | "This is a stopwatch tool, not a clinical assessment" | "If you're ever in doubt, contact your provider or emergency services" | Any claim about labor stage or urgency level | Clinical + legal |
| Loss declaration | User declares a loss | Grief-aware acknowledgment, no clinical framing | Gentle offer of practical and emotional resources, provider-contact option | Any euphemism, forced positivity, or clinical detachment | Clinical + legal + product leadership |
| Due-date change/uncertainty display | Due-date source changes or is first set | "This is an estimate, not a diagnosis" | Not applicable | False precision (a bare date with no uncertainty framing) | Clinical |
| Mood check-in indicating distress | User logs a low mood/distress entry | Standard disclaimer footer | Visible, one-tap link to professional mental-health resources | Any attempt to assess or label a mental-health condition | Clinical |

## Data model matrix

| Entity | Purpose | Key fields | Provenance/confidence fields | Storage tier | Export behavior |
|---|---|---|---|---|---|
| PregnancyRecord | Root pregnancy journey record | Mode, due-date source/value, multiples flag | Source-change history, confidence range | Local-first, encrypted | Full export, extra confirmation |
| GestationalMilestone | Milestone/checklist tracking | Milestone name, target week, completion | Content-version ID | Local-first | Included in export |
| AppointmentLog | Appointment organizer entries | Date, provider, notes, reminder | Entry/edit timestamps | Local-first | Included in export |
| KickCountSession | Kick-counting sessions | Start/end time, count, notes | Session ID, timestamp | Local-first | Included in export |
| ContractionEvent | Contraction timing entries | Start/stop, duration/interval | Session grouping ID | Local-first | Included in export |
| PregnancySymptomLog | Pregnancy-tagged symptom entries | Symptom type, severity, date | Links to base SymptomLog, gestational week | Local-first | Included, same schema plus tag |
| PregnancyWeightLog | Pregnancy-tagged weight entries | Weight, date, unit | Links to base weight entity | Local-first | Included in export |
| ScreeningTestReference | Links to lab-results notebook | Test name, date, linked entry ID | Inherits linked entry's provenance | Local-first, cross-referenced | Included, references linked entry |
| LossDeclarationRecord | Minimal loss record | Approximate date, optional stage/note | Declaration timestamp, linked record ID | Local-first, highest tier | Extra-confirmation export, independently deletable |
| PostpartumHandoffRecord | Bridges to postpartum tracking | Birth date, handoff timestamp | Linked record ID, transition timestamp | Local-first | Included in export |
| ModuleVisibilitySetting | Notification/content preferences | Toggles, quiet-hours, pacing preference | Setting-change history | Local-first | Included, low sensitivity |
| SharingConsentRecord | Partner/support-person sharing consent | Grantee ID, scope, grant/revoke timestamps | Consent-event history | Local-first, highest tier | Included, revocation logged immediately |

## Backlog-ready implementation matrix

| ID | Capability | Phase | Owner | Dependencies | Approval needed | Proposed files/modules | Acceptance criteria |
|---|---|---|---|---|---|---|---|
| PREG-01 | Mode model with user-declared transitions | 1 | Mobile + backend | Period-tracker module | Product | `PregnancyModeController`, `PregnancyRecord` schema | No transition occurs without explicit user action; all seven modes implemented |
| PREG-02 | Due-date model with four-source priority | 1 | Backend | PREG-01 | Clinical (formula validation) | `DueDateEstimator`, `PregnancyRecord` extensions | Correct priority ordering enforced; source always visible in UI |
| PREG-03 | Week-by-week content shell + disclaimer | 1 | Mobile + content | PREG-02 | Legal + clinical (content itself) | `WeeklyContentCard`, disclaimer component | Disclaimer renders on 100% of content screens |
| PREG-04 | Loss declaration + immediate suppression | 1 | Mobile + backend | PREG-01 | Clinical + legal + product leadership | `LossDeclarationRecord`, notification-suppression hook | Notifications stop within same session as declaration, zero delay |
| PREG-05 | Local-first storage + separate consent flow | 1 | Backend + security | None | Legal | Consent screen, encrypted local store | No pregnancy data leaves device without explicit separate consent |
| PREG-06 | Weight/symptom/appointment logging reuse | 1 | Mobile + backend | Existing SymptomLog/Weight entities | Product | `PregnancyWeightLog`, `PregnancySymptomLog`, `AppointmentLog` | Entries appear in both pregnancy view and general history |
| PREG-07 | Kick counter + contraction timer | 2 | Mobile | PREG-01, safety-copy review | Clinical + legal | `KickCountSession`, `ContractionEvent` | Safety copy passes checklist in Section 8 before release |
| PREG-08 | Lab-notebook handoff | 2 | Backend | Lab-results notebook module | Product | `ScreeningTestReference` | Test entries link to, never duplicate, lab-notebook data |
| PREG-09 | HealthKit Pregnancy category integration | 2 | Mobile (iOS) | PREG-01 | Product + privacy review | HealthKit read/write adapter | One-way convenience sync only; no inference back into BADAN |
| PREG-10 | Mood check-ins + resource surfacing | 3 | Mobile + content | PREG-01 | Clinical | Mood check-in component, resource directory | Resource link visible on every mood check-in screen |
| PREG-11 | Postpartum handoff mode | 3 | Mobile + backend | PREG-01, period tracker | Product + clinical | `PostpartumHandoffRecord` | Cycle-return awareness reactivates period tracker correctly |
| PREG-12 | Partner/support-person sharing | 4 | Backend + legal | PREG-05 | Legal + product leadership | `SharingConsentRecord` | Consent revocation takes effect immediately, logged |
