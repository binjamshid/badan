# BADAN Hydration and Water Tracking Research

## 1. Executive summary

BADAN should implement hydration as a local-first, user-owned fluid-intake ledger with calm behavior support—not as a medical hydration assessor. The V1 loop should let a user log a familiar container in under two seconds, optionally use an editable personal tracking goal, receive few suppressible reminders, and export exact underlying records. HealthKit provides interoperable dietary-water quantities, while Android Health Connect provides `HydrationRecord` for a drink event with volume.

The feature should support two experiences on one canonical model: **casual mode** for favorites, quiet progress, optional goals and simple history; **power mode** for beverage definitions, rule histories, source reconciliation, fasting profiles, activity context, raw exports, API pathways, and correlations. Do not diagnose dehydration, prescribe fluid amounts, or use urgent notification levels.

## 2. Research methodology and safety boundaries

This design uses platform capability research, public-health guidance, and explicit product hypotheses. Total dietary water includes water from beverages and food; therefore a water-counter target is a personal tracking choice, not a medical requirement. Product hypotheses such as container-first entry and adaptive reminder timing require consented testing.

Safety rules:
- Use wording such as “your tracking goal,” “optional planning suggestion,” and “log a drink if you had one.”
- Never say “you are dehydrated,” “you need this amount,” or “correct this now.”
- Users with clinician-directed fluid guidance or restriction must have a manual-goal path.
- Pregnancy, cycle, fasting, medication, symptoms, exercise, and weather are opt-in contexts only.
- Routine wellness notifications use normal/passive delivery; never Time Sensitive or Critical.

## 3. Hydration product philosophy for BADAN

1. **Record first; infer second.** A drink event is evidence; targets, contexts and insights are separate layers.
2. **Choice before inference.** Manual goal and no-goal are valid defaults. Any contextual rule is explained and user-approved.
3. **Silence is success.** Quiet hours, Sleep/Focus, fasting windows, dismissal cooldowns, pause-today and caps are core requirements.
4. **Provenance is product.** Preserve source app/device, external ID, revision, write-back state and duplicate policy.
5. **Progressive disclosure.** Casual users see simple actions; power users inspect raw data, policies and exports.

## 4. Complete hydration feature catalog

| Feature | Casual-user value | Power-user value | Required data | HealthKit support | Health Connect support | Backend need | Complexity | Priority | BADAN recommendation |
|---|---|---|---|---|---|---|---|---|---|
| One-tap quick add | Essential | Useful | volume/time | dietary water write | HydrationRecord write | No | Low | P0 | Ship |
| Container presets/favorites | High | High | label/volume | Indirect | Indirect | No | Low | P0 | Ship |
| Custom drinks | High | High | type/default volume | volume only | volume only | No | Low | P0 | Ship |
| Edit, undo, backdate/history | High | Essential | ID/revision/time | owned records only | owned records only | No | Medium | P0 | Ship |
| Manual/no-goal and daily goal | High | High | target/range | None | None | No | Low | P0 | Ship |
| Quiet/pause/fixed reminders | High | High | schedules/state | None | None | No | Low | P0 | Ship |
| JSON/CSV export | Medium | Essential | ledger/provenance | N/A | N/A | No | Medium | P1 | Ship |
| Health platform sync | Medium | Essential | external IDs/anchors | dietaryWater | HydrationRecord | No | Medium | P1 | Ship |
| Widgets/Watch/Shortcuts | High | High | cached day/presets | indirect | Android equivalent | No | Medium | P1 | Ship |
| Weekly reports | High | High | day totals/goals | optional read | optional read | No | Medium | P1 | Ship |
| Workout context | Medium | High | workout timing | Read workout | Read exercise | No | Medium | P1 | Opt-in |
| Fasting/Ramadan profile | High where relevant | High | windows/schedule | None | None | No | Medium | P1 | Ship optional |
| Beverage metadata | Medium | High | caffeine/alcohol/electrolytes | no rich mapping | no rich mapping | No | Medium | P2 | Local-first |
| Adaptive reminders | Medium | High | interactions/patterns | None | None | No | High | P2 | Experiment |
| Correlation explorer | Low | High | entries plus journals | optional | optional | No | High | P2 | Deterministic first |
| Smart bottles | Low | High | vendor events | vendor-specific | vendor-specific | Often | High | P3 | Adapter/defer |
| Weather/location | Low | Medium | consented location/weather | N/A | N/A | Optional | High | P3 | Delay |
| Food-water estimates/barcode | Low | Medium | nutrition database | no direct model | no direct model | Optional | High | P3 | Separate module |

Catalog requirements: quick add, custom amount, reusable containers, one-tap re-log, drink favorites, manual correction, undo, backdating, multi-day editing, weekly history, widgets, Apple Watch, Siri/Shortcuts, HealthKit/Health Connect, workout links, quiet/sleep suppression, fasting profiles, Ramadan template, caffeine/alcohol annotations, sports-drink/electrolyte metadata, raw exports, API presets, trends and source reconciliation.

Do not silently calculate “net hydration” through caffeine/alcohol multipliers or mix food-derived estimates into plain logged-water totals.

## 5. Goal-setting and target model research

| Model | Inputs | Comprehension | Limitations/safety | Default | Wording | Approval | Notifications |
|---|---|---|---|---|---|---|---|
| Manual fixed | user volume | High | personal choice, not prescription | Yes | “Your tracking goal” | set by user | if enabled |
| Simple starter | locale/units | High | not a personal need estimate | Offer | “A starting point you can edit” | explicit | after accept |
| Body-weight optional | body mass | Medium | formulae vary and can be unsuitable | No | “Optional estimate, not medical guidance” | explicit | per-rule |
| Activity-adjusted | opted-in workouts | Medium | does not measure sweat/need | No | “Temporary planning adjustment” | explicit | off initially |
| Climate-adjusted | coarse location/weather | Medium | weather is not physiology | No | “Hot-weather planning prompt” | explicit | off initially |
| Fasting-window | schedule/goal | High | practice/health varies | Offer | “Plan your own non-fasting window” | profile | within window only |
| Pregnancy context | user selection/manual goal | High | individualized care | No | “Use your own or clinician-provided goal” | explicit | no auto increase |
| Day-type schedule | selected days/targets | High | user-authored only | P1 | “Goals for selected day types” | configure | yes |
| No goal | none | High | deliberate mode | Always | “Track without a goal” | choose | no goal prompts |

Store a goal snapshot on every daily summary so past adherence is stable after a later edit. Separate contextual target suggestions from contextual reminders; either requires explicit enablement.

## 6. Logging and interaction model

The Today screen prioritizes a favorite preset with its exact volume. After logging: “Added 500 mL from My Bottle” plus Undo. The custom sheet supports amount, beverage, time, tag and note. The timeline distinguishes manual, imported, smart-bottle and platform entries; edits preserve audit history.

Apple Watch exposes 2–4 presets plus crown-adjustable custom amount and an offline queue. iPhone widgets use an App Group cache. App Intents include `LogHydration`, `GetHydrationProgress`, `PauseHydrationReminders`, and `SetHydrationGoal`; ambiguous voice input needs confirmation. Android maps this to widget, Wear tile and App Actions.

Avoid account-first onboarding, mandatory photo/barcode flow, arbitrary scores, and streak-guilt mechanics. Missing logs do not mean the user did not drink.

## 7. Reminder and notification engine

| Reminder type | Trigger | Default state | User controls | Suppression rules | Privacy sensitivity | Risk of annoyance | Priority |
|---|---|---|---|---|---|---|---|
| Morning-start | selected window/no entry | Off | time/days/tone | sleep, Focus, quiet, fasting | Low | Medium | P1 |
| Fixed schedule | chosen times | Off | times/days/cap | quiet, pause, complete | Low | High | P0 |
| Interval | time since log | Off | interval/window/cap | cooldown plus all above | Low | High | P1 |
| Incomplete-goal | chosen day-end threshold | Off | threshold/time | fasting, quiet, pause | Medium | Medium | P1 |
| Meal-linked | user meals/times | Off | meal/delay | skipped meal/quiet | Medium | Medium | P2 |
| Post-workout | opted-in workout end | Off | delay/types | quiet/recent log | Medium | Low-medium | P1 |
| Medication-adjacent | user-created schedule | Off | event/copy | never dose advice | High | High | P3 |
| Adaptive | opt-in learned pattern | Off | max/week/reason | all plus dismissal stop | High | High | P2 |
| Fasting-window | authorized non-fast period | Off | windows/schedule | never during fast/prayer quiet | High | Medium | P1 |
| Travel timezone | timezone change | only if schedule | wall-clock policy | quiet/sleep/pause | Medium | Low | P1 |

Use a persistent `ReminderPolicyEngine` that plans the next 7–14 days of local notifications and recomputes after logs, actions, schedule/goal changes, timezone change, workout completion and fasting updates. Fixed reminders are pre-scheduled. Context-driven updates are best effort and must not promise exact-time execution.

Defaults: no reminders until explicit user opt-in; onboarding may offer one calm daily reminder; initial maximum one notification per day. Actions: Log 250 mL, Open presets, Not now, Pause today. “Not now” starts a 2–4 hour cooldown. Stop after daily cap, completion, pause, configured sleep/quiet/Focus, fasting window, or repeated dismissal. After 3–5 ignored prompts, offer adjustment rather than escalation.

Safe examples: “A quick water check-in, if it suits your day.” “Workout finished. Add a drink if you had one.” “Your evening hydration window is open.” Never: “You need to rehydrate now.”

## 8. Health platform and accessory integration map

| Integration | Value | Feasibility | Privacy cost | Direct vs broker | Priority |
|---|---|---|---|---|---|
| HealthKit dietary water | Apple interoperability | High | Health permission | Direct | P1 |
| Health Connect hydration | Android interoperability | High | Health permission | Direct | P1 |
| Apple Watch/widgets | low-friction logging | High | screen visibility | Direct | P1 |
| Shortcuts/App Intents | automation/voice | High | intent history | Direct | P1 |
| Workout data | activity reports | High | activity history | Direct | P1 |
| Android widget/Wear | parity | Medium-high | low | Direct | P2 |
| Nutrition apps | food/beverage import | Medium | diet data | standards first | P3 |
| Weather/location | optional context | Medium | location/routine | coarse broker | P3 |
| Smart bottles | passive events | vendor-dependent | account/device behavior | adapter/broker | P3 |
| REST export | user analytics | High | endpoint/token | direct outbound | P2 |

Map eligible plain-water entries to `HKQuantityTypeIdentifier.dietaryWater` and Android `HydrationRecord`. Rich beverage fields, contexts, targets and reminder history stay local because neither shared platform offers BADAN’s complete model. Request HealthKit share/read separately. Do not infer read-permission denial from an empty result; show an empty import state and settings help. Only modify BADAN-owned platform records, and prevent loops with external IDs/content fingerprints.

Use a `HydrationSourceAdapter`: Health platform import first, CSV/JSON import second, OAuth vendor connector third, Bluetooth direct integration last.

## 9. Data model and architecture requirements

| Entity | Purpose | Required fields | Relationships | Platform mapping | Export fields | Privacy notes |
|---|---|---|---|---|---|---|
| HydrationEntry | drink event/audit | id, time, volumeMl, fluidType, source, state | beverage/container/source/revisions | HK/HC eligible | IDs, time, volume, source, revision | routine-sensitive |
| BeverageDefinition | reusable semantics | id, name, type, default volume | entries/favorites | volume only | type/attributes | diet-sensitive |
| ContainerPreset | quick UI volume | id, label, volume, icon/order | entries | none | metadata optional | low |
| HydrationGoal | period target | id, range, target, origin | rules/summaries | none | target/version | wellness context |
| HydrationTargetRule | approved planning logic | id, type, inputs, approval, version | goals/context | none | rule/history | may expose weight/activity |
| HydrationContext | opt-in time-bound context | id, type, range, consent | rules/reminders/insights | workout read-only | optional | high for fasting/medication |
| ReminderSchedule | user intent | id, type, window/days/cap | events/context | local only | schedule | routine-sensitive |
| ReminderEvent | delivery/action audit | id, scheduled time/state/action | schedule | none | optional log | engagement sensitive |
| HydrationInsight | observation | id, period, evidence/count/confidence | entries/goals | none | result/evidence | no causal claims |
| HydrationExportRecord | export audit | id, range/schema/hash/destination | records | none | manifest | endpoint/path sensitive |
| HydrationDataSource | provenance/checkpoint | id, type, external IDs/anchor/policy | entries | HK/HC metadata | source | minimize account IDs |
| FluidType | classification | code/display/eligibility | drinks/entries | volume only | code | no health claims |
| ElectrolyteProfile | composition annotation | values/units/source | beverage | none | values/source | no recommendations |
| CaffeineAlcoholAssociation | drink annotations | mg/units/estimate flag | drink/entry | none | attributes | sensitive |

The encrypted local ledger is append-first. Edits preserve original ID, revision, deleted/superseded state and platform reference. Index occurrence time, local day/timezone, source/external ID, content fingerprint, enabled rule/window and planned reminder/state. Daily summary is derived and separates manual, imported and estimated-food totals.

JSON uses versioned schema, ISO-8601 timestamps, timezone, raw entries, summaries, goals, rules, provenance and manifest/redaction policy. CSV is a bundle of tidy files for entries, summaries, goals, rules, sources and optional events, plus JSON manifest/field dictionary. Default export excludes notes, medication names, cycle/pregnancy/fasting contexts, reminder history and location.

## 10. Casual-user experience

Onboarding asks only preferred units, optional editable goal and optional reminder. Request Apple Health/Health Connect only after sync selection. Today has favorites, calm progress and recent logs. No-goal is equal-status. If unused, hydration can be hidden without deletion. Weekly wording is observational: “You logged drinks on 5 of the last 7 days.”

## 11. Power-user experience

Expose unlimited beverages/containers/tags; day-type goals; target-rule approvals; audit history; source reconciliation; import exclusion policy; fasting profiles; workout context; raw tables; JSON/CSV/ZIP; REST destinations; and deterministic correlation explorer. Every context card shows inputs, permissions, reminder impact and delete/disable behavior.

## 12. Insights, reporting, and export design

| Insight | Minimum data | Method | Casual rendering | Power rendering | Safe wording |
|---|---|---|---|---|---|
| Logging consistency | 7 days | days with entry | weekly card | heatmap/source split | “Logging pattern” |
| Time-of-day pattern | 14 entries/7 days | hour buckets | simple note | distribution | “Recorded timing” |
| Goal adherence | goal plus 7 days | total vs snapshot | weekly progress | rule/exclusions | “Selected goal met on…” |
| Workout-adjacent logs | 5 workouts | configurable windows | optional note | raw pairs | “Logged around workouts” |
| Caffeine/alcohol relationship | 14 matched days | co-occurrence | off | scatter/coverage | “Same days, not cause” |
| Symptom relationship | 20 matched days | descriptive association | off | filters/confidence | “Pattern to observe, not cause” |

Use deterministic rules first. Every insight displays evidence count, coverage, sources and exclusions. AI may conservatively summarize deterministic facts but not invent causal explanation or diagnosis.

## 13. Privacy, consent, accessibility, localization, and cultural context

Use purpose-bound consent. Logging, fixed reminders and export work offline/no account. Gate workout, nutrition, medication-adjacent schedules, symptoms, cycle, pregnancy, fasting, weather/location and accessories separately. Encrypt local storage and never profile/advertise from routine data.

Accessibility: VoiceOver/TalkBack labels with amount; Dynamic Type; high contrast; color-independent progress; optional haptics; low-stimulation mode; localized number parsing. Store mL canonically and display mL/L/fl oz/cups. Support RTL and Arabic interfaces.

Implement a generic `FastingProfile` with user-entered windows and total reminder suppression during the fast. Offer an editable Ramadan template with optional calendar/prayer quiet blocks; never infer faith or hard-code authority. Pregnancy/cycle are display/planning contexts only, never target calculators.

## 14. iOS implementation considerations

Modules: `HydrationDomain`, `HydrationStore`, `HealthKitHydrationAdapter`, `HydrationSyncCoordinator`, `HydrationNotifications`, `HydrationWidgets`, `HydrationWatch`, `HydrationIntents`, `HydrationExport`. Persist platform UUIDs for BADAN-owned dietary-water samples; bound/anchor imports; imported external records are read-only.

Use `UNUserNotificationCenter` for fixed plans. Widgets consume App Group cache. watchOS queues offline logs and reconciles idempotently. Context refreshes are best effort; no routine notification is Time Sensitive/Critical.

## 15. Android implementation considerations

Use AndroidX Health Connect `HydrationRecord` for interoperable events while retaining BADAN-specific fields locally. Mirror the domain/store model in Kotlin; use WorkManager for reconciliation/export, notification channels with quiet/cap policies, Glance/AppWidget, Wear OS tile/complication and App Actions. Do not use Android’s greater background flexibility to create intrusive behavior.

## 16. Feature prioritization and phased roadmap

**Phase 0:** approve source of truth, safety copy, target/reminder policy, export redaction; create encrypted ledger, unit conversion, migrations and summaries.

**Phase 1/V1:** quick add, presets, custom/edit/undo/backdate/history; manual/no-goal/fixed goal; opt-in fixed reminders with quiet/pause/cap; JSON/CSV; platform write-back; widget and basic App Intents.

**Phase 2:** incremental import/reconciliation, watch/wear, workout context, day-type goals, fasting/Ramadan profile, localization/RTL/accessibility hardening.

**Phase 3:** beverage metadata, advanced ZIP/REST export, deterministic insights and opt-in adaptive reminder experiment.

**Phase 4:** nutrition estimate source, smart-bottle vendors, weather and encrypted cloud automation after privacy review.

### Backlog-ready implementation matrix

| ID | Capability | Phase | Owner | Dependencies | Approval needed | Proposed files/modules | Acceptance criteria |
|---|---|---|---|---|---|---|---|
| HYD-001 | Canonical ledger | 0 | Domain | encryption/migrations | source-of-truth | Domain/Store | offline, revision-safe, migratable |
| HYD-002 | Quick add/presets | 1 | Mobile UX | HYD-001 | No | Feature/ContainerStore | <=2 actions, exact amount, Undo |
| HYD-003 | Goals/summaries | 1 | Domain+UX | HYD-001 | wording | GoalEngine/Summary | no-goal, timezone, snapshots |
| HYD-004 | Notifications | 1 | Platform | HYD-003 | caps/defaults | Notifications | caps/suppressions tested |
| HYD-005 | HealthKit write | 1 | iOS | permissions | consent copy | HKAdapter | no write/import loops |
| HYD-006 | Health Connect write | 1 | Android | permissions | consent copy | HCAdapter | round-trip/provenance |
| HYD-007 | Export | 1 | Data | HYD-001 | redaction | Export | stable schema/privacy preview |
| HYD-008 | Widgets/intents | 1 | iOS | App Groups | No | Widgets/Intents | accessible quick log |
| HYD-009 | Import/reconcile | 2 | Data | HYD-005/006 | inclusion policy | SyncCoordinator | idempotent/read-only external |
| HYD-010 | Watch/Wear | 2 | Wearables | HYD-002 | No | Watch/Wear | safe offline merge |
| HYD-011 | Workout context | 2 | Health | workout access | context consent | Context/WorkoutAdapter | opt-in/no medical language |
| HYD-012 | Fasting/Ramadan | 2 | Product/i18n | schedule engine | cultural copy | FastingProfile | silent in fast window |
| HYD-013 | Beverage metadata | 3 | Domain | HYD-001 | sensitive policy | Beverage/Electrolyte | no hidden target effect |
| HYD-014 | Insights | 3 | Data/UX | summaries | safe copy | Insights | N/coverage/no causality |
| HYD-015 | Adaptive experiment | 3 | Product | HYD-004 | privacy experiment | AdaptivePolicy | opt-in/cap/stop rules |
| HYD-016 | Smart-bottle adapter | 4 | Integrations | vendor contracts | vendor review | SourceAdapter | disconnect/delete works |

## 17. Risks, anti-patterns, and features to avoid

- False precision from hidden body-weight, climate or cycle formulae.
- Shame/streak/red-alert/Focus-bypassing notifications.
- Platform write loops and duplicate daily totals.
- Conflation of logged drinks with total dietary water.
- Medical claims from medication, pregnancy, symptoms or cycle data.
- Notifications during an enabled fasting window.
- Default export of notes, routines, contexts, medication references or location.
- Smart-bottle lock-in.
- Opaque AI causal stories.
- Permission-heavy onboarding before first logging.

## 18. Implementation recommendations for BADAN

1. Launch local-first quick logging, containers, manual/no goal, calm reminders and export before smart targeting.
2. Make no-goal/no-reminder valid first-class states.
3. Keep BADAN ledger canonical; reconcile HealthKit/Health Connect as mirrors with provenance.
4. Publish versioned JSON/CSV, field dictionary, stable IDs, revisions, timezone, goal snapshots and redaction manifest immediately.
5. Build generic fasting profiles and editable Ramadan template without identity inference.
6. Centralize target, suppression, timezone, reminder and insight-coverage decisions in one deterministic engine.
7. Ship deterministic insights before AI.
8. Use separate purpose-specific consent for every sensitive context.
9. Deliver accessibility and localization with the core quick-log path.
10. Obtain product/privacy approval for target wording, reminder caps/defaults, export redaction, Ramadan copy and adaptive/vendor integrations.
