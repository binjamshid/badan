# BADAN Live Exercise Monitor Research

## 1. Executive framing

BADAN’s Live Exercise Monitor should be built as a **trustworthy workout operating system** inside a personal health repository, not as a thin stopwatch with decorative graphs. The product’s role is to help casual users start quickly and finish with meaningful records, while also giving power users access to dense live telemetry, exercise context, sensor provenance, and export-grade history. This aligns directly with BADAN’s master blueprint, which defines workouts as a first-class session family, raw workout records as sacred user-owned assets, and “one data model, two altitudes” as a core law.[cite:6][cite:9]

The research corpus already inside BADAN establishes several non-negotiables that should shape this feature from day one: workout data must preserve provenance; manual strength logging needs its own structured system of record because neither HealthKit nor Health Connect natively captures detailed set/rep/load semantics; cross-source workout deduplication is mandatory because the same run may arrive from Apple Watch, Garmin, or platform stores; and exportability must include session summaries plus child files like strength sets rather than flattening everything into a single lossy record.[cite:6][cite:8][cite:9][cite:10]

Platform reality matters. Apple’s modern workout APIs now support live sessions on Apple Watch and on iPhone/iPad via `HKWorkoutSession` plus `HKLiveWorkoutBuilder`, but iPhone still lacks an onboard heart-rate sensor, so live HR there depends on an external device or mirrored watch workflow.[cite:31] Android’s Health Connect provides a strong interoperability and storage layer for `ExerciseSessionRecord`, laps, segments, routes, and granular records like heart rate, speed, distance, steps cadence, and power, but long-running live capture still depends on app-owned services, permissions, batching, and device-specific reliability tradeoffs.[cite:12][cite:14]

The correct BADAN posture is therefore: **local-first session capture, platform-native recording where possible, structured manual augmentation where platform gaps exist, clear source lineage everywhere, and optional guidance that stays calm, non-diagnostic, and easy to disable**. This document translates that posture into a product, UX, data, and delivery blueprint.

## 2. Product thesis

The product thesis is that a modern health repository should not treat exercise as a summary card imported hours later; it should treat workouts as **live, user-owned events with a beginning, evolving evidence, interruptions, subjective context, and downstream meaning**. BADAN’s monitor becomes the layer where the user experiences movement in real time and where the repository gains its richest continuous behavioral record.[cite:6][cite:9]

The winning design is not “more metrics.” It is **metric honesty + progressive disclosure**. Casual users need one-tap starts like “Walk,” “Run,” or “Strength,” a large readable core metric set, safe pause/end controls, and a clean summary. Power users need live sensor streams, configurable tiles, laps, zone tracking, source details, raw sample awareness, structured intervals, route views, notebook context, and export paths.[cite:6][cite:8][cite:10]

Differentiation comes from combining four things competitors usually split apart: (1) live workout capture, (2) structured strength and custom-workout logging, (3) provenance and confidence visualization, and (4) contextual analysis against sleep, recovery, symptoms, cycle phase, medication, and nutrition without pretending to be a medical monitor. The resulting product is broader than a running app, more honest than a generic wellness timer, and more repository-native than many athlete apps that treat source data as opaque.[cite:6][cite:8][cite:9]

## 3. User archetypes and jobs to be done

BADAN’s existing archetypes already imply distinct workout needs. The casual wellness user needs frictionless starts and simple reassurance-free summaries; the Apple Watch-heavy user expects dependable sensor-led tracking and lock-screen/live-surface continuity; the Android/Health Connect user needs variability-tolerant workflows; the quantified-self user wants raw exports and source detail; the strength trainee wants structured set logging and progression history; and the endurance user wants pace, splits, route, and zone fidelity.[cite:3][cite:5]

A practical JTBD framing:

| Archetype | Core job | Live monitor requirement | Anti-failure priority |
|---|---|---|---|
| Casual walker | “Let me start fast and see only what matters.” | Quick start, elapsed time, distance/pace if available, easy pause/end | Avoid permission confusion and dense metrics |
| Recreational runner | “Help me pace and finish with trustworthy splits.” | Pace, distance, heart rate if available, route, auto-pause option | GPS drift and accidental end protection |
| Endurance athlete | “Show me live effort, intervals, zones, and source quality.” | Configurable metrics, laps, power/cadence where available, zone history | Multi-device duplication and sensor drop handling |
| Strength trainee | “Let me log sets without slowing rest transitions.” | Fast exercise/set flow, timer, RPE/RIR optionality, template support | Logging latency between sets |
| Hybrid athlete | “Unify cardio, strength, and recovery context in one history.” | Mixed modality support, custom activities, structured notes | Cross-modality schema consistency |
| Privacy-maximalist | “Keep my workout data local and exportable.” | Offline-first capture, local notebook, export control, provenance | No unnecessary cloud dependencies |

A key product principle is that the same workout model must support these jobs without forking the core schema. BADAN’s blueprint already codifies this through a single session model with presentation-policy layers and structured child payloads for workouts and strength sets.[cite:8][cite:9]

## 4. Exercise modality taxonomy

BADAN needs an explicit cross-platform modality taxonomy that is richer than platform enums but still mappable to them. The canonical taxonomy should include: walking, outdoor running, treadmill running, trail running, interval running, cycling, indoor cycling, mountain biking, strength training, bodybuilding, powerlifting, functional fitness, HIIT, circuit training, yoga, Pilates, mobility, rowing, swimming, hiking, climbing, combat sports, racquet sports, team sports, skiing/snow sports where relevant, wheelchair/adaptive training where supported, generic workout, and user-created custom activities. Apple and Android both support broad workout/exercise session taxonomies, but custom BADAN taxonomy IDs are still needed to stabilize exports, UI, and vendor reconciliation across platforms.[cite:6][cite:10][cite:12][cite:14]

### Taxonomy matrix

| Activity | Casual start flow | Power setup | Minimum useful live metrics | Advanced metrics | Main data sources | Target devices | Maps/routes | Interval needs | Logging needs | Post-workout focus | Common failure modes | Accessibility | Default chart density |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Walking | One-tap Start Walk | Goal, route, cues, HR source | Time, distance, pace | HR zone, cadence, elevation | Phone GPS, watch, HC/HK | Phone, watch | Optional | Rare | Note/RPE optional | Duration, distance, easy pace trend | GPS drift, phone in pocket lock | Large text pace/time | Low |
| Outdoor running | Quick Start Run | Goal, intervals, zone targets | Time, distance, current pace, HR | Split pace, cadence, power, elevation | Apple Watch, Wear OS, chest strap, HC/HK | Watch + phone | Common | Frequent | Lap markers, note | Splits, route, zones, PRs | GPS drift, HR gaps | High-contrast sunlight mode | Medium |
| Treadmill running | Start Indoor Run | Belt speed assist, manual distance correction | Time, HR, manual/estimated distance | Cadence, pace from speed, intervals | Watch sensors, manual edits | Watch/phone | None | Common | Distance override | Time in zone, pace consistency | Distance mismatch vs treadmill | Big buttons during motion | Low |
| Trail running | Start Trail Run | Elevation-heavy screens, route breadcrumb | Time, distance, elevation | Grade, climb rate, descent, HR, route position | GPS + barometer + watch | Watch/phone | Essential | Sometimes | Water/gear note | Elevation, route, climb effort | Route loss, battery drain | Audio cues limited on technical terrain | Medium |
| Interval running | Start Workout or select template | Work/rest sequence, cue preferences | Interval state, time, pace/HR | Lap metrics, zone adherence, power | Platform live session + templates | Watch/phone | Optional | Essential | Segment adherence | Target adherence, splits | Missed transitions, over-cueing | Haptic-first option | Medium |
| Cycling | Start Ride | Sensor select, route, auto-pause | Time, distance, speed | HR, cadence, power, elevation, grade | Watch, bike sensors, phone GPS | Phone mount + watch | Strong | Sometimes | Lap/manual note | Route, splits, power/zone distribution | Phone battery, GPS noise | Glanceability at speed | Medium |
| Indoor cycling | Start Indoor Ride | Bike sensor pairing, zone goals | Time, HR | Cadence, power, intervals | Watch + BT sensors/manual | Phone/watch | None | Common | RPE optional | Zone distribution, load | Missing bike sensor | Large core tiles | Low |
| Mountain biking | Start MTB | Rugged screen, route, pause policy | Time, distance, speed | Elevation, HR, cadence, power | GPS, watch, bike sensors | Watch/phone | Strong | Sometimes | Incident note optional | Route/elevation, effort | GPS under trees, vibration UI issues | Strong haptics, minimal taps | Medium |
| Strength training | Start Strength | Template, units, rest defaults | Exercise, set, reps/load/rest | RPE/RIR, volume, e1RM, superset state | Manual BADAN SOR, optional watch HR | Phone, watch companion later | None | Rest intervals | Heavy | Volume, progression, notebook | Logging too slow, unit confusion | One-handed steppers | Low live / high post |
| Bodybuilding | Start Strength | Pump-oriented template | Set/reps/load | Muscle-group volume, rest adherence | Manual + optional HR | Phone | None | Rest-centric | High | Volume per muscle, pump note | Too many inputs | Large rest timer | Low |
| Powerlifting | Start Strength | Warmup/work/back-off semantics | Set/reps/load | e1RM, bar progression, rest | Manual | Phone | None | Rest-centric | High | Top set trend, estimated strength | Plate math errors | Big number entry | Low |
| Functional fitness | Start Functional | Circuit template or free mode | Time, interval/rest | HR, rounds, reps, load | Manual + watch | Phone/watch | Rare | High | Round/rep capture | Adherence, volume, mixed modality load | Hard-to-log transitions | Voice/haptic support | Medium |
| HIIT | Quick Start HIIT | Work/rest profile | Timer, interval state | HR zone, reps, cadence | Watch + manual | Watch/phone | None | Essential | Minimal | Interval completion | Cue overload | Haptic-first | Low |
| Circuit training | Start Circuit | Station plan | Timer, station | HR, round count | Manual + watch | Phone/watch | None | Essential | Exercise transitions | Completion and rest | Logging lag | Voice prompts helpful | Low |
| Yoga | Start Yoga | Silence mode, breath cue opt-in | Time | HR optional, session tags | Watch/manual | Phone/watch | None | Rare | Reflection note | Duration, subjective effect | Distracting cues | Calm theme, reduced motion | Very low |
| Pilates | Start Pilates | Session template | Time | HR optional | Watch/manual | Phone/watch | None | Rare | Note optional | Consistency | Metric clutter | Minimal UI | Very low |
| Mobility | Start Mobility | Area template | Time | HR optional | Manual | Phone | None | Rare | Body area note | Consistency, symptom relation | Overkill metrics | Simplified UI | Very low |
| Rowing | Start Row | Indoor/outdoor select | Time, stroke rate if available | HR, pace, power, distance | Wearable + machine/manual | Watch/phone | Outdoor optional | Sometimes | Split note | Pace consistency, intervals | Source mismatch | Clear stroke metrics | Medium |
| Swimming | Start Swim | Pool/open-water choice | Time, laps if supported | Pace, SWOLF if external ecosystem later | Platform native where available | Watch-first | Open water only | Sometimes | Manual note | Laps, distance, route if open water | Water lock/device limits | Large waterproof-safe affordances | Low |
| Hiking | Start Hike | Route, battery saver, elevation screen | Time, distance, elevation | Grade, climb rate, route position | GPS, barometer, watch | Watch/phone | Essential | Rare | Trail/symptom note | Route, elevation, duration | Lost signal, long battery drain | Sunlight readability | Medium |
| Climbing | Start Climb | Indoor/outdoor type | Time | Pitch count/manual segments | Manual + watch HR | Phone/watch | Outdoor route optional | Rare | Attempt logging | Attempts, rest, notes | Poor sensor fit | Large tap targets | Low |
| Combat sports | Start Workout | Round timer | Round/time | HR optional, recovery between rounds | Manual + watch | Phone/watch | None | Essential | Round result note | Round adherence, volume | Gloves usability | Audio/haptic cues | Low |
| Racquet sports | Start Match | Format & side switches | Time | HR, movement, sets score manual | Watch/manual | Watch/phone | Optional | Structured sets | Score notes | Match duration, effort | Manual scoring burden | Big score controls | Low |
| Team sports | Start Game | Position/team optional | Time | HR, distance if available | Watch/phone | Watch/phone | Optional | Periods | Event note | Session load | GPS chaos, stop/start ambiguity | Large period controls | Low |
| Skiing/snow | Start Ski | Cold/battery warning | Time, vertical/elevation, route | Speed, descent count | Watch/phone GPS | Watch/phone | Strong | Rare | Run markers | Vertical, route, duration | Cold battery loss | Glove-friendly controls | Medium |
| Wheelchair/adaptive | Start Adaptive Workout | Select modality | Time, distance if relevant | HR, cadence if supported | Platform-specific support + manual | Phone/watch | Optional | Varies | Custom notes | Duration, effort, accessibility-respecting summaries | Bad modality fit | Inclusive labels, no forced assumptions | Low |
| Generic workout | Start Workout | Rename/tag after | Time | HR optional | Any | Any | None | Optional | Freeform notes | Basic duration and effort | Too vague for analytics | Low cognitive load | Very low |
| Custom activity | Start Custom | Name, icon, metric set, route toggle | Time + chosen primary metric | Any compatible metric | Any available source | Any | Optional | Optional | Template-specific | User-defined dashboard | Schema drift | Custom labels in RTL | User-defined |

The product implication is that BADAN must not hardwire a runner-first worldview. Activity-specific metric bundles, cue defaults, chart density, and empty-state language should be driven by the modality definition, not by one global layout.

## 5. Competitive and platform benchmark

The benchmark set should be split into two classes: **experience competitors** and **platform capability baselines**. Experience competitors include Apple Workout, Nike Run Club, Strava, Garmin Connect, Polar Flow, WHOOP, Strong, Hevy, Ladder-style guided fitness apps, and general wellness apps with thinner exercise features. BADAN’s internal research already treats WHOOP and adjacent apps as relevant context, but BADAN’s opening is not to mimic a single athlete product; it is to combine repository-grade ownership, structured exercise, and contextual health analysis in one system.[cite:2][cite:10]

The most relevant platform benchmark is Apple’s own workout stack. Apple documents a canonical lifecycle around `HKWorkoutSession`, `HKLiveWorkoutBuilder`, preparation before the start countdown, builder-driven metric updates, and a careful ending sequence of `stopActivity` → `.stopped` → `endCollection` → `finishWorkout` → `end`.[cite:31] Apple also explicitly recommends starting on Apple Watch when possible to access the fullest set of sensors and mirroring to iPhone for companion experiences.[cite:31]

Android’s benchmark is different: Health Connect is not a live coaching framework but an interoperable data layer. It recommends `ExerciseSessionRecord` as the workout anchor, batching writes, stable session IDs, foreground services for location and sensor sampling, `WorkManager` for deferred sync, and explicit route permissions and route-consent handling for third-party reads.[cite:12][cite:14]

The strategic conclusion is that BADAN should benchmark against polished athlete apps for screen craft, but architect against the official platform constraints. Live workout reliability is won in state handling, batching, recovery, and provenance—not just in visual design.

## 6. Product principles and differentiation

BADAN’s live monitor should inherit and operationalize the blueprint laws rather than restating them abstractly. The key principles for this feature are:

1. **Repository-first capture**: every workout is stored as a durable session plus child data, not only as summarized UI state.[cite:9]
2. **One model, two altitudes**: casual and expert workout views are policies over one canonical workout object.[cite:6][cite:9]
3. **Provenance visible by design**: sensor source, derived-vs-recorded distinctions, and confidence caveats appear in context rather than being buried.[cite:6]
4. **Manual strength is first-class**: not a hack around cardio-centric platforms.[cite:6][cite:8]
5. **Local-first operation**: live capture, notes, and critical review must work offline.[cite:7][cite:8]
6. **Optional guidance only**: cues help, never pressure, and can be globally disabled.
7. **Arabic and RTL from the start**: labels, metric order, maps, numerals, and templates must localize structurally, not cosmetically.

Differentiation versus generic workout apps should be explicit:

| Area | BADAN position | Common competitor weakness |
|---|---|---|
| Provenance | Source-level workout and metric lineage | Opaque imported summaries |
| Strength logging | Structured system of record with templates and semantics | Flat notes or weak set tracking |
| Cross-domain context | Recovery/sleep/symptoms/cycle/nutrition correlations | Siloed cardio view |
| Export | Raw-ish session + child files + lineage | PDF/share-card emphasis |
| Casual-to-power | One schema, multiple renderings | Separate “lite” and “pro” logic drift |
| Privacy | Local-first live capture | Cloud-first coaching stacks |

## 7. Workout lifecycle model

BADAN needs a precise state machine because workout UX reliability is primarily a state-management problem. The lifecycle should be standardized across platforms even when underlying APIs differ.

### Canonical states

```text
IDLE
  -> ACTIVITY_PICKER
  -> QUICK_START_READY
  -> PERMISSION_GATE
  -> DEVICE_READINESS
  -> COUNTDOWN_PREPARED
  -> ACTIVE
       -> MANUAL_PAUSED
       -> AUTO_PAUSED
       -> SENSOR_DEGRADED
       -> ROUTE_DEGRADED
       -> LOW_BATTERY_DEGRADED
       -> INTERRUPTION_OVERLAY
       -> INTERVAL_TRANSITION
  -> STOPPING
  -> POST_REVIEW_DRAFT
       -> SAVE
       -> EDIT_BEFORE_SAVE
       -> DISCARD_CONFIRM
  -> PERSISTED_SESSION
  -> DELAYED_SYNC / EXPORT_QUEUE
```

Apple’s official session lifecycle strongly supports a prepared → running → stopped → ended discipline, and Apple explicitly recommends a short countdown after `prepare()` so sensors or external HR devices have time to become available before activity begins.[cite:31] Android’s lifecycle is app-defined, but Health Connect’s guidance similarly emphasizes initializing a stable session ID, writing the session anchor first, then collecting GPS/metrics and updating/finalizing the session later.[cite:12]

### State-by-state requirements

| State | User-visible UI | System behavior | Local persistence | Telemetry | Error recovery | Accessibility | Casual vs power |
|---|---|---|---|---|---|---|---|
| Pre-workout setup | Activity card, quick options | Load templates/goals/default metric bundle | Save last used choices | Start intent, activity chosen | Resettable draft | Screen reader announces chosen activity | Casual hides advanced toggles |
| Goal selection | Time/distance/calories/none/structured session | Validate capability match | Persist selected goal | Goal type event | Fallback to “open workout” | Large targets | Power adds interval plan |
| Device readiness | HR sensor, GPS, battery, permissions check | Probe sources and session prerequisites | Persist readiness snapshot | Sensor readiness stats | Retry or start degraded | Voice summary of missing items | Casual: green/yellow/red; power: detail sheet |
| Permission request | Clear rationale and continue | Trigger platform permission APIs | Mark prompt timestamp | Permission funnels | Allow degraded start where safe | Explain consequences plainly | Power can inspect exact permissions |
| Countdown | 3-second or configurable | Apple: `prepare()`, prewarm; Android: start service and sampling | Persist startIntentTime | Countdown started | Skip if resumed | Strong haptic/audio options | Power may disable countdown |
| Active workout | Live metric screen | Collect, batch, update, save checkpoints | Frequent checkpoints | App state, sample cadence, sensor quality | Recoverable after crash | Large motion-safe layout | Power can swipe metrics |
| Temporary pause | Pause overlay | Stop timers/route writes as policy; mark pause span | Persist pause start | Pause reason | Resume or end | Easy resume/end buttons | Power may annotate pause reason |
| Auto-pause | Passive notification | Heuristic pause based on modality and motion | Persist auto event | Auto-pause accuracy metrics | Resume prompt | Clear distinction from manual pause | Power can disable/tune |
| Sensor disconnect | Small banner, degraded metric tile | Continue session, mark missing source, retry connection | Log source gap | Disconnect events | Reconnect gracefully | Non-alarming language | Power sees gap timeline |
| Route loss/recovery | Map badge / degraded GPS | Keep session alive, stop trust in live pace if severe | Save GPS gap | Accuracy and availability | Backfill if possible | Audible warning optional | Power sees accuracy number |
| Low battery | Non-blocking warning | Suggest saver mode, reduce map refresh | Save battery state | Battery drain metrics | Manual mode shift | Haptic + text | Power can keep full mode |
| Audio/call interruption | Overlay | Pause cues; optionally maintain session | Mark interruption event | Interruption type | Resume after interruption | VoiceOver-friendly | Power can auto-mute cues |
| Workout completion | End confirm sheet | Stop collection/finalize | Draft session saved immediately | End reason | If finalize fails, keep draft recoverable | Clear summary heading | Power gets more edit options |
| Post-review | Summary, notes, RPE, tags | Compute derived metrics and quality notes | Draft-to-final transaction | Save funnel | Can reopen edit | Keyboard/screen reader support | Power gets provenance sheet |
| Delayed sync/export | Non-blocking badge | Queue writes/backfill/exports | Outbox entries | Sync failures | Retry with idempotency | Status readable without color | Power can inspect queue |

The lifecycle contract should be implemented as a platform-neutral state machine with platform adapters, not as view logic spread across screens.

## 8. Live metrics ontology

BADAN requires a metric ontology richer than a dashboard tile list. Each live metric must define type, source hierarchy, update cadence, default-display suitability, platform availability, persistence behavior, caveats, user controls, and export representation. BADAN’s existing ontology already names core workout-derived metrics such as duration, zone minutes, strain, cardio load, strength volume, e1RM, total reps, muscle load, and HR recovery, and requires provenance/confidence metadata on derived values.[cite:6][cite:9]

### Core live metric registry

| Metric | Type | Source hierarchy | Update cadence | Casual safe? | Advanced only? | Platform availability | Persist after workout? | Caveats | User controls | Export format |
|---|---|---|---|---|---|---|---|---|---|---|
| Elapsed time | Duration | Session clock | 1s | Yes | No | Universal | Yes | None | Hide/show | Session field |
| Active time | Duration | Session clock minus pauses | 1s | Yes | No | Universal | Yes | Depends on pause policy | Hide/show | Session field |
| Paused time | Duration | Pause spans | On pause changes | No | Sometimes | Universal | Yes | Auto-pause ambiguity | Hide/show | Session field |
| Distance | Length | Platform generated > GPS-derived > manual | 1–5s live | Yes for run/walk/ride | No | HK/HC broad | Yes | Indoor mismatch, route noise | Unit, hide, correction | Session summary + samples |
| Current pace | Rate | Generated/derived from distance/time or GPS | 1–5s | Yes for running/walking | No | Broad | Derived summary/splits | Noisy at low speed | Smoothing level | Splits/series |
| Split pace | Rate | Derived from lap boundaries | On lap | No | Useful in running power mode | Broad | Yes | Depends on lap quality | Auto/manual laps | Lap child file |
| Average pace | Rate | Derived | 5–15s | Yes | No | Broad | Yes | Pause policy matters | Include pauses toggle | Session summary |
| Current speed | Speed | GPS/system/generated | 1–5s | Yes for cycling | No | Broad | Yes | GPS noise | Smoothing, unit | Series/summary |
| Average speed | Speed | Derived | 5–15s | Yes for cycling | No | Broad | Yes | Pause policy | Unit | Summary |
| Heart rate | Quantity | Apple Watch / chest strap / Wear OS / external > platform store | 1–5s typical | Optional default | No | Apple with sensor, Android if collected/written | Yes | May be unavailable on phone-only; sampling variability | Show/hide, source preference | HR series |
| Heart-rate zones | Categorical + duration | Derived from HR + zone model | 5–15s | Optional | No | Where HR exists | Yes | Zone model choice affects meaning | Zone model select | Zone minutes |
| Heart-rate recovery | Derived delta | Post-stop HR | At post-workout checkpoints | No | Advanced | Depends on HR continuity | Yes | Not always available; non-diagnostic | Enable calculation | Derived value |
| HRV in workout context | Quantity | Limited and usually not meaningful live | Rare | No | Yes | Not reliable as live workout metric | Maybe | Should not be overemphasized | Off by default | Derived note only |
| Cadence | Quantity | Running/cycling cadence source | 1–5s | No | Often advanced | HK/HC partial | Yes | Sensor/source specific | Hide/show | Series/summary |
| Stride metrics | Quantity | Platform/vendor-specific | 1–5s | No | Yes | Partial | Yes | Availability fragmented | Enable advanced running | Series/summary |
| Power | Quantity | Cycling/running power source | 1–5s | No | Yes | Partial on both ecosystems | Yes | External sensor dependence common | Source select | Series/summary |
| Elevation gain/loss | Length | Barometer/GPS/derived | 5–15s | For hiking/trail yes | No | Partial | Yes | GPS-only elevation can be noisy | Unit, hide | Summary + route stats |
| Grade | Percentage | Derived from route/elevation | 5–15s | No | Yes | Partial | Yes | Very noisy at short windows | Smoothing | Series |
| Route position | Geo point | GPS route | 1–5s | No | Map screen | Outdoor only | Yes | Permission and signal dependent | Route recording toggle | GPX/JSON points |
| Lap/split count | Integer | Manual/auto lap engine | On event | No | Useful | Broad | Yes | Auto-lap misfires | Auto-lap settings | Laps file |
| Interval state | Enum | Structured session engine | On state changes | Yes in intervals | No | Universal app logic | Yes | Template quality dependent | Cue settings | Timeline/events |
| Repetition count | Integer | Manual strength / segment data if any | Per set or segment | For strength yes | No | BADAN SOR, HC segments partial | Yes | Wearable auto-rep unreliable | Manual edit | Sets file |
| Set count | Integer | Manual strength | Per set | For strength yes | No | BADAN | Yes | None | Manual edit | Sets file |
| Rest timer | Duration | App timer | 1s | For strength/HIIT yes | No | Universal | Yes as event spans | User behavior may override | Auto-start/skip | Events |
| Load volume | Derived | Sets × reps × load | Per set | No | Advanced-ish | BADAN | Yes | Bodyweight/assistance semantics matter | Unit, formula disclosure | Derived values |
| Estimated energy expenditure | Quantity estimate | Platform generated > BADAN heuristic fallback | 15–60s / summary | Optional | No | Broad | Yes | Always estimate, source mismatch common | Hide if unavailable | Summary |
| Training load | Derived score | BADAN engine using HR/duration/strength channels | Post-workout + maybe live trend | No | Yes | BADAN | Yes | Model assumptions | Disable/simplify wording | Derived values |
| Subjective exertion / RPE | Ordinal | User input | On log | No | Optional | Universal | Yes | Subjective by design | Prompt on/off | Session field/event |
| Pain/discomfort/symptom note | Structured note | User input | On log | No | Optional | Universal | Yes | Sensitive data | Prompt on/off, privacy scope | Event record |
| Environmental context | Structured fields | User-entered, optional weather source later | Sparse | No | Optional | Universal | Yes | Don’t over-automate | Enable/disable | Session metadata |
| Sensor/battery/connectivity status | Status object | App/device system | 5–30s | Minimal badge only | Detail for power users | Universal | Quality audit yes | Can clutter live UI | Surface level | Quality log |
| Provenance/confidence | Metadata object | Per metric derivation/source | On source change | Minimal badge default | Full detail advanced | Universal | Yes | Requires disciplined plumbing | Detail depth | Export metadata |

### Metric design rules

- A metric may only be shown as “live” if BADAN can explain its source class and freshness.
- Estimated values such as calories or heuristic load must be explicitly labeled as estimates when expanded, and never presented as objective truth.
- Casual mode should prioritize at most 2–4 primary metrics per modality screen, while power mode may expose dense grids and alternate pages.
- BADAN should store not only final aggregates but also key event spans, splits, and references to raw sample series so post-workout analysis can stay grounded.[cite:6][cite:9]

## 9. Platform capability analysis: Apple ecosystem

Apple’s current official model is the strongest single-platform foundation for a BADAN live monitor. The canonical building blocks are `HKWorkoutSession`, `HKLiveWorkoutBuilder`, `HKLiveWorkoutDataSource`, HealthKit authorization, optional route capture, Live Activities, Siri intents, and workout recovery APIs.[cite:31][cite:17]

### Apple capability matrix

| Capability | Documented support | Product opportunity | Developer complexity | Reliability limits | Privacy requirements | MVP suitability | Fallback |
|---|---|---|---|---|---|---|---|
| `HKWorkoutSession` lifecycle | Yes, official | Robust stateful live workout engine | Medium | Session-ending sequence must be correct | HealthKit permissions | Yes | Retrospective `HKWorkout` save for manual imports |
| `HKLiveWorkoutBuilder` live metrics | Yes, official | Real-time metric updates without manual anchored-query plumbing | Medium | Metrics depend on available sensors and sample types | HealthKit permissions, lock-state behaviors | Yes | Limited manual timers/derived metrics |
| `prepare()` + countdown | Yes, official best practice | Better first-minute metrics and external sensor warmup | Low | Users may skip or start too early | None beyond session permission | Yes | Immediate start |
| Apple Watch native sensors | Yes | Best HR/live workout fidelity | Medium-high if companion architecture | Watch/phone mirroring complexity | Watch Health permissions | Yes if watch app exists | Phone-only degraded mode |
| iPhone/iPad sessions | Yes since Apple’s expanded API | Broadens market beyond Watch owners | Medium | No onboard HR sensor on phone/iPad | Lock-state prompt and HealthKit permissions | Yes | External HR or no-HR workouts |
| External HR on iPhone | Yes via paired devices | Phone-led workout possible with HR | Medium | Pairing and availability vary | Bluetooth/device pairing + HealthKit | Phase 1.5 | Hide HR metric |
| Workout route collection | Supported via workout ecosystem / route objects | Outdoor route, maps, splits, privacy-aware exports | Medium-high | GPS/battery/signal variability | Location permission + route handling | Yes for outdoor MVP | No-route workout |
| Crash recovery | Yes, official | Trustworthy long workout recovery | Medium-high | Must recreate data source | Session recovery permissions/app lifecycle | Yes | Draft restore with degraded details |
| Live Activities on iPhone lock screen | Yes, recommended | Lock-screen glanceability | Medium | Limited space and privacy | User lock-state data access prompt | Yes | Notification-style status |
| Siri workout intents | Yes | Hands-free start/pause/resume/end | Medium | Intent handling must sync app state | Intent permissions and app integration | Phase 2 | Buttons only |
| Workout zones APIs | Apple now highlights them in newer docs/videos | Richer live and post-workout effort analysis | Medium-high | OS version dependency | HealthKit/workout permissions | Phase 2 | BADAN custom zone model |
| Complications/Smart Stack/Watch widgets | Supported surfaces | Fast resume and glanceability | Medium | Space constraints | Standard widget/privacy rules | Phase 2 | In-app shortcuts |

Key Apple-specific truths:

- Apple explicitly says that if a Watch app exists, the workout should start there for fullest sensor access, then mirror to iPhone.[cite:31]
- iPhone and iPad can run workout sessions for any activity, but may not generate all requested samples themselves—heart rate especially depends on paired wearables.[cite:31]
- When the device is locked, health data is normally restricted, but a workout-specific prompt can permit ongoing workout data access so Live Activities can show crucial metrics on the lock screen.[cite:31]
- Builder APIs are preferred because they keep live metrics and saved workout data synchronized, and Apple recommends them rather than older manual query-heavy patterns for active workouts.[cite:31][cite:17]

### Apple architecture recommendation

For BADAN on Apple, the primary architecture should be:

1. **Watch-first for sensor-rich workouts**.
2. **iPhone as control plane, mirrored display, and review/edit surface**.
3. **Phone-only session path** for walk/run/strength/open workout users who have no watch, with graceful HR degradation.
4. **Shared workout domain model** above Apple-specific adapters.
5. **Structured BADAN child payloads** for strength, notebook annotations, and provenance beyond HealthKit’s native shape.[cite:8][cite:9][cite:31]

## 10. Platform capability analysis: Android ecosystem

Android’s official story is centered on Health Connect as a read/write interoperability store rather than a turnkey live workout runtime. Google’s current official workout guidance covers writing exercise sessions, routes, and granular metrics like heart rate, speed, distance, calories, elevation, steps cadence, and power; reading other apps’ workout data; and managing background execution with foreground services plus batched writes.[cite:12]

### Android capability matrix

| Capability | Documented support | Product opportunity | Developer complexity | Reliability limitations | Privacy requirements | MVP suitability | Fallback |
|---|---|---|---|---|---|---|---|
| `ExerciseSessionRecord` | Yes | Canonical workout anchor | Low-medium | Need stable IDs and careful updates | HC exercise permissions | Yes | BADAN local-only draft then write later |
| Segments and laps | Yes | Intervals, strength-like segments, structured subevents | Medium | App must define semantics | HC session permissions | Yes | BADAN local child events |
| `ExerciseRoute` | Yes | Outdoor mapping and GPX-like fidelity | Medium-high | Separate permission and route consent rules | Route permissions + location | Yes for outdoor MVP | No-route session |
| Heart rate records | Yes | Interoperable live/post HR | Medium | Depends on app-owned collection or other apps’ data | READ/WRITE heart rate permissions | Yes if BADAN captures or imports | Hide HR |
| Speed/distance/calories/elevation/power/cadence | Yes | Rich cardio analytics | Medium | Device/sensor variability | Per-type permissions | Yes selectively | Derived minimal metrics |
| Foreground services for live capture | Recommended | Long-running session continuity | High | OEM battery policies can still interfere | Foreground notification + permissions | Yes | Reduced live reliability with clear messaging |
| `WorkManager` deferred sync | Recommended | Battery-aware sync and backfill | Medium | Not for sub-minute live needs | Normal app permissions | Yes | Immediate local persistence |
| Change logs | Yes | Efficient backend or local sync reconciliation | Medium | Requires careful checkpointing | HC permissions | Phase 2 | Full-range reads |
| Route consent for third-party reads | Yes | Privacy-respecting imports | Medium-high | Cannot silently background-read other apps’ routes | One-time consent flow | Yes for import flows | Import session without route |
| Health Connect availability check | Yes | Better onboarding on fragmented devices | Low | HC may be absent or outdated | None beyond install prompts | Yes | BADAN local-only mode |
| Wear OS integration | Partial and device-dependent | Native wearable capture path | High | Vendor fragmentation | Wear OS + HC + location/sensor permissions | Phase 2 | Phone-led workouts |

Important Android constraints from official docs:

- Health Connect might not be installed, enabled, or up to date; BADAN must check SDK availability and guide users accordingly.[cite:14]
- For background workout capture with screen off, Google recommends foreground services for location and sensor sampling, plus batching and `WorkManager` for deferred writes/sync.[cite:12]
- Apps should write frequently during active tracking, but typically in batched intervals rather than per-sensor-event; Health Connect supports up to 1000 records per write request.[cite:12]
- Third-party route reading is intentionally constrained: background reads of other apps’ routes may return consent-required even with general access, so route import should be initiated from deliberate foreground user interaction.[cite:14]

### Android architecture recommendation

For BADAN on Android:

1. **Separate capture runtime from Health Connect persistence**. BADAN’s live session engine owns timers, GPS sampling, sensor fusion, and UI.
2. **Write a durable local session first**, then batch sync to Health Connect with stable `clientRecordId`s for idempotency.[cite:12]
3. **Treat Health Connect as interoperability backbone**, not sole runtime dependency.
4. **Degrade gracefully when HC unavailable**: local BADAN session capture remains usable, then optional later export/write-back.
5. **Delay ambitious Wear OS live mirroring** until phone-first architecture and sensor quality pipelines are proven.

## 11. Wearable and device integration strategy

BADAN should think in layers of trust and richness, not just by brand. The core question for every device class is: can BADAN record directly, read through the platform store, import via vendor APIs/files, or only reconcile post hoc? BADAN’s blueprint already defines a vendor strategy where platform stores are preferred when they already receive companion writes, direct vendor paths are used where they add meaning or avoid duplicates, and overlapping workouts are reconciled with source-priority rules such as Garmin-direct winning workouts by default.[cite:6][cite:10]

### Integration tiers

| Tier | Examples | Role | Pros | Cons | BADAN approach |
|---|---|---|---|---|---|
| Native primary wearables | Apple Watch, Wear OS device with BADAN companion | Direct live capture | Best live UX, direct control | Highest app complexity | Strategic core |
| Native external sensors | Chest HR straps, bike sensors | Live metric enrichers | Better HR/power/cadence fidelity | Pairing variance | Source plugin layer |
| Platform-store contributors | Devices writing via Apple Health / Health Connect | Post hoc or semi-live through stores | Wide ecosystem reach | Timing and metadata opacity | Strong import + dedup |
| Direct vendor integrations | Garmin, Oura, Fitbit, WHOOP | Rich post-workout sync | Deeper vendor metadata | OAuth and duplication risk | Selected adapters |
| File imports | GPX, FIT, TCX, CSV | Recovery and portability | User-owned and explicit | Parsing complexity | Phase 2+ export/import tools |

### Source priority principles

- **For live display**, prefer the device actively attached to the session runtime, with visible source labels.
- **For saved session identity**, prefer the platform-native session BADAN created itself; otherwise apply overlap rules and a deterministic winner policy.[cite:6][cite:8]
- **For high-fidelity cardio metrics**, prefer direct watch/external-sensor samples over delayed vendor summaries.
- **For strength**, BADAN manual logs remain the primary source of truth even if a wearable records concurrent HR.[cite:6][cite:8]

### Device-status surfaces

Users need a device/sensor chooser and a source detail sheet showing:

- Connected sensors and battery if available.
- Signal/last sample age.
- Whether the metric is device-recorded, platform-generated, vendor-imported, or BADAN-derived.
- Whether the current workout is being recorded on watch, phone, both mirrored, or post hoc only.

This reinforces BADAN’s “provenance or it did not happen” law in a user-understandable form.[cite:6]

## 12. Canonical workout and live-stream data model

BADAN already has the right broad shape: a `Session` envelope with a `WorkoutSessionPayload`, child structures for laps and strength sets, and derived-value tables for post-workout metrics.[cite:9] The live monitor should extend this into an implementation-ready canonical model.

### Core entities

```text
WorkoutSession
- id
- activityTypeId (BADAN canonical)
- platformActivityTypeRef
- startAt, endAt
- timezoneStart, timezoneEnd
- stateHistory[]
- sourceProfile
- deviceContext
- routeRef?
- hrSeriesRef?
- metricSeriesRefs[]
- laps[]
- intervals[]
- strengthBlock?
- subjectiveContext
- qualitySummary
- exportStatus

LiveMetricSample
- sessionId
- metricId
- recordedAt
- value
- unit
- sourceId
- freshnessMs
- confidence
- derivationRef?

WorkoutSource
- sourceId
- sourceClass (device/platform/vendor/manual/derived)
- vendorName
- hardwareModel?
- appBundleOrPackage?
- platformStoreRecordId?
- connectionType?

WorkoutRoutePoint
- sessionId
- at
- lat/lng
- altitude?
- horizAccuracy?
- vertAccuracy?
- bearing?
- speed?
- sourceId

WorkoutInterval
- id
- sessionId
- kind (work/rest/lap/manual segment/transition)
- startAt/endAt
- targetDefinition?
- resultSummary?

StrengthExerciseBlock
- sessionId
- exercises[]
- sets[]
- supersetGroups[]
- notes[]
- volumeDerived[]
```

### Proposed BADAN workout JSON export shape

```json
{
  "session_id": "01J...",
  "activity_type": "running.outdoor",
  "start_at": "2026-07-20T15:00:00Z",
  "end_at": "2026-07-20T15:42:31Z",
  "devices": [{"source_id":"watch_1","class":"device","name":"Apple Watch"}],
  "summary": {
    "elapsed_sec": 2551,
    "active_sec": 2490,
    "distance_m": 7032.4,
    "energy_kcal_est": 481.0,
    "avg_hr_bpm": 153
  },
  "laps": [...],
  "intervals": [...],
  "route_ref": "route_01J...",
  "series_refs": ["hr_01J...", "pace_01J..."],
  "subjective": {"rpe": 7, "note": "Felt heavy first 10 min"},
  "quality": {"hr_completeness": 0.94, "route_quality": "partial"},
  "provenance": {
    "primary_source": "healthkit.live_workout_builder",
    "derived_metrics": [{"metric":"training_load","algorithm_id":"strain.v1"}]
  }
}
```

### Model invariants

- Every session has a stable BADAN ID independent of platform-store IDs.
- Every persisted metric aggregate can reference underlying series or a derivation formula/version where practical.[cite:6][cite:9]
- Strength data is attached structurally, not only as notes.[cite:8][cite:9]
- Merge/suppression lineage is preserved for overlapping sessions.[cite:9]
- Session payload versions are schema-versioned to allow future migration without silently rewriting history.[cite:9]

## 13. Sensor, data quality, and provenance model

BADAN should make source quality legible without drowning the casual user in debugging jargon. Provenance must exist at three levels: **session-level provenance**, **metric-level provenance**, and **derived-value provenance**. The blueprint already requires confidence and provenance metadata across metric families and explicit labeling for heuristic strength/muscular load and e1RM formulas.[cite:6]

### Provenance classes

| Class | Meaning | Example |
|---|---|---|
| Device-recorded | Direct from hardware sensor path | Apple Watch HR during live session |
| Platform-generated | OS-generated during workout | iPhone-generated distance/calories in supported session path |
| App-recorded manual | User-entered structured data | Strength set reps/load |
| Vendor-imported | Direct from third-party API/file | Garmin FIT workout import |
| BADAN-derived | Computed from other inputs | Zone minutes, training load, HR recovery |
| User-corrected | Manual correction to recorded data | Treadmill distance adjusted after save |

### Quality dimensions

| Dimension | Meaning | Examples |
|---|---|---|
| Completeness | Did the metric exist through the session? | HR present for 92% of active time |
| Freshness | How old is the live sample? | HR last updated 4s ago |
| Continuity | Were there significant gaps? | Route gap 3m14s |
| Accuracy hint | Does source provide confidence/accuracy fields? | GPS horizontal accuracy |
| Consistency | Do sources conflict materially? | Calories differ by 22% across imports |
| Derivation transparency | Can BADAN explain formula and inputs? | e1RM formula ID stamped |

### User-facing provenance UX

- **Casual mode**: small badges like “Watch HR,” “Phone GPS,” “Estimated calories,” “Route partial.”
- **Power mode**: source sheet with device, sample completeness, gaps, algorithm versions, and conflicting-source journal.
- **Post-workout note**: include short quality notes such as “Heart rate unavailable for first 2 minutes; zone minutes are partial.”

### Conflict handling

BADAN already anticipates overlap rules such as Garmin + Watch logging the same run and explicitly recommends deterministic suppression/merge behavior.[cite:6] For live exercise, the rules should be:

1. During one BADAN-owned live session, one source becomes primary per metric family.
2. Secondary sources may fill gaps but should not silently replace high-confidence primary samples without a merge journal.
3. Post hoc imported duplicate sessions should be merged or suppressed based on type, overlap window, magnitude similarity, and source priority.[cite:6][cite:8][cite:10]

## 14. Live monitor information architecture

The workout monitor should have a dedicated sub-IA rather than behaving as a single screen. The right structure is:

```text
Workout Home
 ├─ Activity Picker
 ├─ Quick Start
 ├─ Goal Picker
 ├─ Device/Sensor Chooser
 ├─ Readiness Check
 └─ Template Builder / Custom Activity Builder

Active Workout
 ├─ Default Screen
 ├─ Compact Screen
 ├─ Advanced Metrics Pages
 ├─ Interval Screen
 ├─ Lap/Splits Screen
 ├─ Route Map Screen
 ├─ Strength Logger
 ├─ Notes / RPE / Symptom Quick Log
 └─ Pause / End Flow

Post-Workout
 ├─ Overview
 ├─ Detailed Analysis
 ├─ Timeline
 ├─ Route Detail
 ├─ Source Detail
 ├─ Edit Screen
 ├─ Notebook / History
 ├─ PR / Load Views
 └─ Export
```

The IA should be anchored around the workout lifecycle, not merely around tabs. Casual users may only touch Workout Home → Active Default → Overview. Power users may traverse many branches without forcing complexity on everyone else.

## 15. Screen-by-screen product blueprint

This section specifies the key screens required by the mandatory brief.

### Workout home

- **Purpose:** immediate start point for all workouts.
- **Target user:** all users.
- **Primary action:** start last-used or recommended activity.
- **Secondary actions:** browse activities, select template, inspect sensors, open history.
- **Data shown:** recent activities, quick-start cards, last sensor availability, saved templates.
- **Advanced affordances:** recent source issues, shortcut editor, preferred metrics.
- **Metric density rules:** none by default beyond quick stats.
- **Interaction behavior:** tap to start, long-press to customize, swipe between quick actions.
- **Accessibility:** large primary buttons, VoiceOver labels, high contrast.
- **Arabic/RTL:** quick cards reverse naturally; numerals localized per settings.
- **Anti-intimidation:** “Start Walk,” “Start Run,” “Start Strength,” “Start Workout” always visible.

### Activity picker

- **Purpose:** browse modality taxonomy.
- **Primary action:** choose activity.
- **Secondary:** favorite, create custom activity, learn required sensors.
- **Data:** modality icon, common metrics, indoor/outdoor variant, route capability.
- **Power affordances:** platform mapping and metric availability preview.
- **Anti-intimidation:** top section shows popular activities first; advanced categories collapsed.

### Quick-start controls

- One-tap actions for the four most common flows.
- Long-press opens goal and sensor sheet.
- Casual mode defaults to last successful sensor/source setup.

### Goal picker

- Goals: open workout, time, distance, calories-estimate, interval template, lap count, strength template.
- If unsupported by modality, options are hidden or clearly disabled.
- Casual mode shows only 3–4 common goal types.

### Device/sensor chooser

- Shows source candidates per metric family.
- Lets user select auto / prefer watch / prefer chest strap / no HR.
- Includes battery and freshness if available.
- Power-only detail: sample rate hints, fallback chain, permission gaps.

### Permissions flow

- Rationale-first, platform-native second.
- Split asks by necessity: workout session, heart rate, location, notifications/audio cues.
- If denied, offer “Start with limited data” where safe.

### Pre-workout readiness check

- Traffic-light readiness: Ready / Limited / Missing Critical.
- Items: session permission, location, HR source, battery, watch link, offline map state.
- Casual sees summary; power can expand into exact missing components.

### Live workout default screen

- Large primary metric, 2–3 secondary metrics, pause/end safely separated.
- Swipe or crown/gesture to alternate pages on wearables.
- Lock-screen/live surface shows only essential metrics.

### Live workout compact screen

- One primary metric + elapsed time for high-motion or sunlight conditions.
- Ideal for cycling, hiking, reduced-distraction mode.

### Live workout advanced metric configuration

- Power-user grid editor for choosing tiles per modality.
- Save presets by activity and device context.

### Interval screen

- Current segment, next segment, time remaining, target range, adherence status.
- Calm wording such as “Below target range” or “Above target pace range.”

### Lap/split screen

- Current lap stats, recent laps table, manual lap button.
- Auto-lap indicators with correction notes if suspicious.

### Route map screen

- Live breadcrumb, current position, distance markers, elevation toggle.
- Privacy-aware post-workout route clipping near home in share/export flows.

### Audio/haptic settings

- Cue modes: none, haptic-only, audio-only, mixed, headphone-preferred.
- Announcement cadence controls and throttle limits.

### Strength workout logger

- Exercise header, last set reference, set entry row, rest timer, next exercise queue.
- Gesture-safe one-handed buttons and fast weight/reps steppers.
- Supports warm-up/working/drop/failure/back-off labeling.

### Exercise library

- Search, filter by muscle/equipment, favorites, recent, custom exercises.
- Mixed-language names supported; Arabic aliases encouraged.

### Set/rep/rest flow

- Fast mark-complete flow: reps, load, optional RPE, save, rest auto-start.
- Superset mode jumps between paired exercises.

### RPE/pain/symptom quick log

- Optional bottom-sheet during or after workout.
- Very short inputs to avoid disrupting movement.

### Pause screen

- Resume, end workout, add note, switch to battery saver.
- Distinguish auto-pause from manual pause.

### End-workout confirmation

- Prevent accidental termination with explicit confirmation or long-press end on motion-heavy activities.

### Post-workout overview

- Headline metrics, source badge, optional note prompts, save/edit actions.

### Detailed post-workout analysis

- Tabs or sections for timeline, splits, zones, route, strength, provenance, notes.

### Workout timeline

- Evented timeline combining pace/HR/intervals/pause notes/strength sets.

### Route detail

- Map, elevation profile, privacy mask, route quality notes.

### Sensor/source detail

- Per metric source list, gaps, accuracy hints, merge journal.

### Workout edit screen

- Safe corrections: title, activity type, notes, treadmill distance, laps, tags, privacy flags.
- Any edits journaled, never silently overwrite provenance.[cite:9]

### Workout notebook/history

- Chronological session log with filters by type, source, quality, tags.

### Personal records screen

- PR detection with caveat engine; disallow false PRs when data incomplete.

### Training-load view

- Acute/chronic trends and distribution, borrowing BADAN’s existing load concepts.[cite:6]

### Workout export flow

- Export summary CSV/JSON, child files, route GPX/GeoJSON where supported, notebook PDF later.

### Template builder

- Build interval runs, strength sessions, circuits, custom sequences.

### Custom activity builder

- Name, icon, modality family, default metrics, route yes/no, note fields, export tag.

### Empty/permission/offline/error states

- Should explain consequence, not just missing access.
- Example: “Route recording is off because location access is disabled. You can still track time and manual notes.”

## 16. Casual-user workout experience

The casual experience should be optimized around four truths: users often start in a hurry, many do not care about metric density, permissions are confusing, and a good simple workout history is already valuable. The casual flow is therefore:

1. Open Workout Home.
2. Tap Start Walk / Run / Strength / Workout.
3. See a short readiness state if something critical is missing.
4. Get a big, legible live screen.
5. End and save with an optional note or RPE.

Defaults for casual mode:

- No custom grid editing exposed upfront.
- Only core metrics shown.
- Guidance off or very light by default.
- Automatic route only for outdoor types when permission exists.
- Strength flow defaults to just exercise + reps/load + rest, with RPE hidden unless previously used.
- Post-workout summary prioritizes one or two key learnings, not deep analytics.

Casual mode is not a separate data model. It is a rendering and interaction policy over the same session object.[cite:6][cite:9]

## 17. Power-user workout experience

Power mode should feel coherent, not merely crowded. It is for users who want to inspect more, configure more, and export more. Features include:

- Configurable metric pages by modality.
- Live source badges and freshness hints.
- Structured interval execution and adherence visualization.
- Manual/auto laps and split analysis.
- Zone models and time-in-zone detail.
- Route map + elevation + privacy clipping controls.
- Strength semantics such as warm-up/working/drop/back-off/failure sets.
- Export bundles and raw-ish references.
- Comparison of workouts and training load context.

Power mode should always preserve a “back to simple” escape hatch. Expert users appreciate control, but not mandatory micromanagement on every session.

## 18. Activity-specific experience design

The product should support activity-specific defaults rather than one universal workout screen. Examples:

- Running emphasizes pace, distance, HR, intervals, splits.
- Cycling emphasizes speed, distance, cadence/power, route, bigger glance targets.
- Strength emphasizes exercise queue, set completion, rest timer, last performance.
- HIIT emphasizes segment timer and calm cues.
- Hiking emphasizes route, elevation, battery-saving options.
- Yoga/mobility emphasize low-distraction timing and subjective notes rather than performance metrics.

Every modality should have:

- A default metric bundle.
- A compact low-cognitive-load view.
- A list of optional advanced metrics.
- A route policy.
- A cue policy.
- A post-workout summary policy.

## 19. Running and walking experience

Running and walking are likely the highest-volume cardio entry points and should define BADAN’s quality bar. Core live views should include elapsed time, distance, current pace, and HR when available. Running adds laps/splits, auto-lap options, interval handling, cadence, power where available, and route maps.[cite:12][cite:31]

### Key design choices

- Use smoothing for live pace to avoid jitter, but expose the smoothing level in advanced settings.
- If GPS quality degrades materially, show “Pace unstable” rather than pretending precision.
- If HR is absent on phone-only Apple sessions, omit HR tile rather than showing zeros; Apple explicitly notes iPhone lacks an onboard HR sensor.[cite:31]
- For treadmill mode, prioritize manual distance correction after save.

### Post-run analysis

- Headline summary.
- Splits and lap analysis.
- HR zones and recovery if available.
- Route/elevation for outdoor sessions.
- Quality note when route or HR is partial.
- Context links to sleep/recovery/load.

## 20. Cycling experience

Cycling UX must be highly glanceable because attention windows are brief. The default screen should emphasize large speed/distance/time tiles, with cadence/power/HR on secondary pages. Route and elevation matter strongly for outdoor rides. Auto-pause must be conservative because short stops at intersections are common.[cite:12][cite:14]

### Cycling-specific needs

- Screen readability in sunlight.
- Mount-friendly phone experience plus watch fallback.
- Strong battery-saver mode due to long GPS sessions.
- Sensor support for cadence and power where available on both Apple and Android ecosystems, understanding that support is fragmented and often external-device dependent.[cite:10][cite:12]

## 21. Strength-training experience

BADAN’s strength system is strategically important because both HealthKit and Health Connect lack a full native strength-set model. BADAN’s blueprint already defines strength as a system-of-record domain with `exercise_library`, `workout_templates`, `strength_sets`, and a crash-safe `StrengthSessionRunner` that persists after every set write.[cite:6][cite:8]

### Strength design goals

- Fast, low-friction “Start Strength Workout” flow.
- Structured exercise selection and custom exercise creation.
- First-class capture of set type, reps, load, units, rest, and optional RPE/RIR.
- Supersets, circuits, giant sets.
- Time-based and rep-based exercises.
- Bodyweight and assisted movements.
- Progression tracking with e1RM and volume history.[cite:6][cite:8]

### Strength entities

BADAN’s existing entities are a solid foundation:

- `ExerciseDefinition`: localized name, muscle groups, equipment, custom flag, optional MET estimate for custom activity honesty.[cite:8]
- `WorkoutTemplate`: reusable sequence of entries.[cite:8]
- `StrengthSet`: set index, exercise, weight, reps, optional RPE, warm-up flag, superset group.[cite:8]

### Set semantics

| Set type | Meaning | Default fields | Post-workout effect |
|---|---|---|---|
| Warm-up | Preparatory set | reps/load, optional note | Excluded from some PR logic by default |
| Working | Main programmed set | reps/load, optional RPE | Included in volume/progression |
| Drop set | Reduced-load continuation | reps/load, linked to parent | Included, labeled distinctly |
| Failure set | Ended at failure | reps/load, failure flag | High effort note; careful coaching wording |
| Back-off | Lower-load follow-up after top set | reps/load | Included, tracked as progression context |
| Assisted bodyweight | Bodyweight with assistance | reps + assistance load | Needs custom volume semantics |
| Timed set | Time-under-tension or plank-style | duration + optional load | Included in exercise-specific analytics |

### Strength live UX

- Start screen offers: Free Strength, Template, Recent Template, Quick Log.
- During session, primary screen shows current exercise, next set target, last performance, rest timer, and set entry controls.
- A compact “between sets” flow is essential: complete set in one interaction path, rest timer starts automatically, next exercise preview appears.
- Exercise swap mid-session must preserve completed sets under original exercise, as BADAN’s blueprint already expects.[cite:8]

### Progression tracking

- Volume by exercise and muscle group.
- Total reps and sessions.
- e1RM with formula disclosure and versioning.[cite:6]
- Best set, heaviest set, best volume day, consistency streaks.
- Optional subjective fields: form quality, pump, pain/discomfort, “felt easy/hard.”

### Manual vs wearable integration

Wearables can provide concurrent HR and session duration, but BADAN manual logging remains the authoritative set-level record. Any future auto-detected reps should be optional annotations, never silent replacements.

## 22. HIIT, functional fitness, and interval experience

These modalities are transition-heavy and therefore cue-sensitive. The monitor should foreground **interval state**, **time remaining**, **next action**, and **rest state** more than raw distance metrics. For functional fitness and HIIT, rounds and station sequences matter more than beautiful pace charts.

### Design rules

- Current state large, next state visible.
- Haptic-first cueing to reduce headphone dependence.
- Calm messaging: “Work interval ended” / “Rest starts now” / “Target pace slightly high.”
- Manual skip/back buttons for missed transitions.
- Circuits support either timed or rep-complete confirmation.

Post-workout should evaluate adherence to the planned structure, not merely summarize total duration.

## 23. Swimming, rowing, hiking, and outdoor activity experience

These modalities are diverse but share a need for contextual policies.

### Swimming

- Prefer native watch-first capture where possible because water constraints make phone interaction unrealistic.
- Pool/open-water distinction changes route needs and summary structure.
- Avoid overpromising live underwater interaction.

### Rowing

- Indoor vs outdoor branch.
- Stroke rate, pace, distance, HR, and intervals matter where available.
- Machine-derived metrics may need manual or vendor import paths later.

### Hiking

- Route and elevation are central.
- Battery saver and offline behavior matter more than high-frequency charts.
- Symptoms, hydration reminders, and environmental notes may be helpful but must stay optional.

### Outdoor miscellaneous

- Trail, climb, snow, adaptive outdoor modes should inherit route/elevation/battery patterns with modality-specific labels.

## 24. Custom activities and templates

BADAN should support user-created custom activities because platform enums and standardized sports lists never cover all real behaviors. A custom activity builder should allow:

- Name and icon.
- Base family (cardio, strength, interval, mindful movement, outdoor, skill/game).
- Default metric bundle.
- Route on/off.
- Goal types allowed.
- Notes fields.
- Export tag and analytics family.

Templates should exist for:

- Strength workouts.
- Interval run/ride sessions.
- Circuits/HIIT.
- Reusable custom flows like “5 km progression run” or “upper-body hypertrophy.”

Templates should be local-first and versioned so that changes do not rewrite historical workout plans.

## 25. Workout planning and structured sessions

Structured sessions are a major unlock for power users but should not burden casual starts. BADAN should support:

- Time-based intervals.
- Distance-based intervals.
- Pace-target intervals.
- HR-zone-target intervals.
- Cycling power targets where available.
- Strength templates with target sets/reps/rest.
- Circuit station plans.

Planning objects should define target, tolerance, cue policy, and adherence evaluation method. If a target relies on unavailable sensors, BADAN must clearly degrade—for example, an HR-zone session can still run but with “heart rate unavailable; target guidance paused.”

## 26. Live guidance and cueing system

The cueing system must be helpful, optional, and non-coercive. The user should be able to disable all live guidance globally or per activity.

### Guidance types

- Pace target cues.
- HR zone cues.
- Interval transitions.
- Time/distance goal milestones.
- Rest timer cues.
- Hydration prompts only if explicitly enabled.
- Lap announcements.
- Minimal battery or GPS quality warnings.

### Wording rules

Bad wording: “Push harder now.”

Good wording:

- “You are below your target pace range.”
- “Heart rate is above your selected zone.”
- “Rest ends in 10 seconds.”
- “GPS quality is low; pace may be unstable.”

### Notification throttling

- Minimum interval between non-critical cues.
- Suppression during rapid oscillation around thresholds.
- Activity-specific defaults: runners may want 1 km lap cues; yoga users may want none.

### Sensory channels

| Mode | Best for | Notes |
|---|---|---|
| Visual | Treadmill, strength, stationary workouts | Low privacy risk |
| Haptic | Running, cycling, HIIT | Low distraction, language-independent |
| Audio | Outdoor endurance, strength rest timers | Requires throttle and interruption handling |
| Mixed | Power users | Must avoid overload |

## 27. Heart-rate zones, intensity, and training-load design

Heart-rate zones should be user-configurable and model-transparent. BADAN can support simple defaults such as age-based or manually set max/resting HR models, but it should also integrate official platform zone data where available in later phases, especially on Apple’s newer workout-zone stack.[cite:20][cite:31]

### Zone design principles

- Make the zone model visible and editable.
- Distinguish “recorded HR” from “BADAN zone interpretation.”
- Show uncertainty when HR coverage is partial.
- Allow sessions with no HR to continue without pseudo-zones.

### Training load

BADAN’s blueprint already defines strain/load concepts like acute 7-day EWMA, chronic 28-day EWMA, focus distribution, and separate strength muscle-load channels.[cite:6] The live monitor should feed these models by supplying trustworthy session-level inputs while keeping coaching claims modest.

Recommended design:

- **Live:** optionally show simple intensity context such as current zone or “hard / moderate / easy” based on user model.
- **Post-workout:** compute session load, zone minutes, and compare against recent baseline.
- **Never:** prescribe medically appropriate training or imply injury prevention certainty.

## 28. GPS routes, maps, and elevation

Routes matter for running, cycling, hiking, trail sessions, open-water activities, and some walking. They do not belong everywhere. Android officially models routes as `ExerciseRoute` attached to an `ExerciseSessionRecord`, with separate permissions and constrained third-party route reading.[cite:12][cite:14] Apple’s workout ecosystem likewise supports route-oriented workout capture for outdoor modalities, though exact implementation details vary by app structure.[cite:6][cite:31]

### Route policies

- Record only when modality and permissions justify it.
- Filter low-accuracy points before persistence where possible, following Android’s official best-practice guidance.[cite:12]
- Pause route point recording during paused segments.
- Mark route as partial when gaps occur.
- Provide export formats such as GPX and GeoJSON in later phases.
- Support privacy clipping near home for share/export flows.

### Elevation

- Treat GPS-only elevation as lower-confidence than barometer-assisted sources.
- Surface gain/loss prominently for trail, hiking, and climbing-related activities.
- Allow “elevation confidence low” caveats instead of false precision.

## 29. Music, audio, haptics, and ambient feedback

Workout experiences often coexist with music, podcasts, phone calls, and environmental awareness. BADAN should not attempt to become a media app, but it should respect and lightly integrate with these realities.

Requirements:

- Cue volume policy and headphone-aware behavior.
- Haptic substitutions when audio is unavailable.
- Automatic cue muting or ducking during calls/interruption audio.
- Safe minimal interactions during motion.
- No brittle dependence on background audio privileges for core workout capture.

Ambient feedback patterns:

- Subtle progress rings or pulse bars for easy effort visualization.
- Low-motion, glanceable changes rather than flashy transitions.
- Distinct haptic patterns for pause, interval change, and end.

## 30. Apple Watch, Wear OS, widgets, and live surfaces

### Apple Watch

Apple Watch should be BADAN’s primary sensor-led wearable surface. Start-on-watch and mirror-to-phone is the preferred Apple path for rich workouts, as Apple explicitly recommends when a Watch app exists.[cite:31] Key watch surfaces:

- Live workout screen.
- Compact glance screen.
- Interval cues.
- Strength companion in Phase 2.
- Complications / Smart Stack entry points.

### iPhone Live Activities

Apple specifically recommends Live Activities for lock-screen workout visibility on iPhone.[cite:31] BADAN should use them for:

- Elapsed time + primary metric.
- Pause/resume/end status.
- Route-free glanceability.
- No dense telemetry on lock screen.

### Wear OS

Wear OS support should follow phone-first Android stabilization. Target features:

- Start/stop/pause workout.
- Core live metrics.
- Haptics for intervals.
- Simple HR-led workouts.
- Optional mirror/sync with phone session.

### Widgets and shortcuts

- Start last workout quickly.
- Resume paused session.
- Show recent workout summary or readiness-to-workout status.
- Avoid putting sensitive live health details in widgets without strong privacy defaults.

## 31. In-workout privacy, safety, and interruption design

The workout monitor is a wellness product, not a medical or emergency-monitoring system. The UI must embody that boundary.

### Safety-oriented UX rules

- Clear pause and end controls.
- Optional emergency-access affordance only if designed with explicit product/legal review; do not imply medical monitoring.
- Non-diagnostic cue wording.
- No coercive “push through” prompts.
- Make data-source quality visible.
- Allow full disablement of guidance.

### Privacy rules

- Local-first live data capture.
- Minimal cloud exposure during active workout.
- Private notes/symptom logs default to local/private scopes unless explicitly exported.
- Lock-screen/live-surface metrics should remain minimal and configurable.
- Route sharing/export uses privacy clipping and explicit user consent.

### Interruption handling

- Incoming call: preserve session, mute cues, show resume state after interruption.
- Audio interruption: pause announcements, not necessarily the workout.
- App background/lock: maintain session within platform rules; show degraded states honestly.

## 32. Offline operation, battery, and connectivity strategy

Offline operation is mandatory for trust. BADAN’s broader logging doctrine already requires offline support across write paths.[cite:7] The live monitor should therefore support:

- Offline workout start and completion.
- Local route capture and checkpointing.
- Local notes/RPE/strength sets.
- Deferred HealthKit/Health Connect writes where necessary.
- Deferred backend sync and export.

### Battery strategy

- Batch writes rather than persist every sensor event individually, aligning with Android’s official guidance.[cite:12]
- Adaptive refresh rates for maps and advanced metrics.
- Battery saver mode reducing map refresh, background sync attempts, and animation.
- Long-session warnings for hiking/cycling.
- Apple watch-first recommendation when phone-only battery drain would be inferior.[cite:31]

### Connectivity strategy

- Work without network.
- Work through watch/phone disconnect with recovery path.
- Persist session checkpoints frequently enough to survive crashes or process death.
- Use idempotent session IDs/client IDs for later platform-store writes and sync.[cite:12]

## 33. Post-workout analysis and workout notebook

The post-workout notebook is where BADAN turns a captured session into a trustworthy record and reflection surface. It should include:

- Headline summary.
- Timeline of live metrics and key events.
- Splits/laps or set logs.
- HR zones and intensity context.
- Route/elevation if relevant.
- Strength volume and progression context.
- Sensor/source provenance.
- Subjective logs.
- Quality notes.
- Export and comparison options.

### Notebook sections

| Section | Purpose | Casual default | Power detail |
|---|---|---|---|
| Summary | Main result | Yes | Expanded stats |
| Timeline | See workout flow | Optional | Yes |
| Splits/Laps | Performance segmentation | For runners/cyclists only | Full table + charts |
| Strength log | What was lifted | For strength only | Full set-by-set details |
| Zones | Effort distribution | Optional | Full zone model detail |
| Route | Map/elevation | Outdoor only | Full route quality and privacy controls |
| Provenance | Trust layer | Small badge | Full detail sheet |
| Notes/Reflections | Journal value | Prompted lightly | Structured and long-form |
| Comparison | Recent benchmarks | Light | Advanced filters |
| Export | Ownership | Optional | Full bundle options |

The notebook should preserve the idea that a workout is both data and context. BADAN is especially well positioned to ask short, optional reflection prompts such as “How hard did this feel?” or “Any pain/discomfort?” without turning every session into a form-filling exercise.

## 34. Correlation with recovery, sleep, symptoms, cycle, and nutrition

This is one of BADAN’s most important differentiators. The live monitor does not need to solve all correlations in real time, but post-workout and weekly review should connect workouts to broader repository context.

Examples:

- Compare workout intensity/load against recent sleep or recovery baseline.[cite:6]
- Show symptom context the user entered around the session.[cite:7]
- Surface cycle-phase context only if opted in and handled respectfully.[cite:10]
- Link nutrition/hydration logs around the workout window where the user wants that view.[cite:7]
- Include medication context only as user-controlled correlation, never as diagnosis or unsafe interpretation.

Correlation language must stay observational:

- “This run followed two nights of below-usual sleep.”
- “You logged knee discomfort after three of your last five lower-body sessions.”
- “This session occurred during your logged luteal phase.”

Not acceptable:

- “Your medication caused poor performance.”
- “You are overtrained.”
- “This pattern indicates a clinical issue.”

## 35. AI-assisted workout summaries and exploration

AI features should be grounded, citation-friendly, and user-correctable. BADAN’s AI layer can help summarize and organize, but must not hallucinate explanations or prescribe unsafe training changes.

### AI use cases

- Concise post-workout summary.
- Long-form power-user analysis.
- “Explain this chart.”
- Compare two workouts.
- Summarize training week.
- Explain zone distribution.
- Convert raw data + notes into journal-quality narrative.
- Detect incomplete/low-quality recording.
- Suggest tags and organization.

### AI contract rules

- Every claim must ground itself in visible session data, recent repository context, or explicit user notes.
- Outputs must use non-diagnostic language.
- Training suggestions, if any, must stay organizational and observational, not prescriptive.
- Users should be able to request concise vs detailed summaries.
- Feedback loops should let users correct “This was not a race effort” or “This route was partial.”

### On-device vs cloud

- Short summaries and quality checks can be good candidates for on-device or local-first inference where feasible.
- Richer cross-workout narratives may use cloud AI only with explicit privacy controls.
- Sensitive note fields should be excludable from AI contexts.

## 36. Logging, notes, RPE, pain/symptoms, and subjective context

Subjective context is essential because numbers alone rarely explain workout meaning. BADAN already has structured event systems for symptoms and notes plus optional perceived effort in workout payloads.[cite:9]

Recommended workout-context fields:

- RPE after session, optional in-session for intervals or strength blocks.
- Pain/discomfort tags with body region and severity if desired.
- Freeform note.
- Tags like race, easy day, travel, heat, fasting, illness context.
- “How did it feel?” quick chips.

Design rules:

- Subjective logging is optional.
- Use very short prompts by default.
- Sensitive entries stay private by default.
- Notes and symptoms can influence comparisons and quality interpretations but never overwrite raw workout data.

## 37. Exports, integrations, and interoperability

BADAN’s workout exports should reflect its repository philosophy. BADAN’s blueprint already anticipates `sessions.csv`, `workout_sets.csv`, nested JSON, and preserved lineage fields.[cite:6][cite:9]

### Export bundle design

| Export | Contents | Best for |
|---|---|---|
| Session summary CSV | One row per session | Spreadsheet review |
| Child CSV files | laps, intervals, sets, notes links | Detailed analysis |
| JSON | Full structured session object with provenance | Developer and archival use |
| GPX/GeoJSON | Route points where supported | Mapping portability |
| Markdown/PDF notebook | Human-readable report | Sharing and journaling |

### Interoperability targets

- HealthKit write-back and reads where supported and user-approved.[cite:31]
- Health Connect session and metric writes/reads where supported.[cite:12][cite:14]
- Direct vendor imports in broader BADAN integration roadmap.[cite:10]
- Long-term file import/export support for FIT/TCX/GPX/CSV.

Export should indicate pending sync states so users do not export a misleadingly incomplete workout.

## 38. Backend, local storage, sync, and event pipeline architecture

The live monitor should follow BADAN’s broader write-path philosophy: local transaction first, domain event emission, later write-back/sync, and explicit audit trails.[cite:7][cite:9]

### Proposed architecture

```text
UI / Workout Runtime
  -> WorkoutStateMachine
  -> Sensor Adapters (GPS, HR, watch mirror, manual logger)
  -> Local Session Repository
  -> Domain Events
       -> Derived Metric Scheduler
       -> Platform Write-Back Outbox
       -> Sync Outbox
       -> Analytics Events
       -> Export Queue
```

### Storage layers

- **Hot local store:** current session checkpoints, last live metrics, pause state, route buffer.
- **Durable local DB:** canonical sessions, sets, intervals, notes, source logs, outbox.
- **Platform stores:** HealthKit / Health Connect as system-facing interoperability stores.
- **Backend sync:** optional BADAN cloud for backup, AI, multi-device continuity, and analytics—not required for workout execution.

### Sync rules

- Stable session IDs and client IDs for idempotency, matching Android official guidance.[cite:12]
- Suppress-only rather than hard-delete platform-origin sessions where necessary, matching BADAN’s session lineage approach.[cite:9]
- Outbox retries with exponential backoff and user-visible pending states.

## 39. Analytics, experimentation, and quality monitoring

Analytics here should serve reliability and product clarity, not surveillance. Key categories:

- Start funnel: activity chosen, permission drop-offs, readiness failures.
- Live reliability: crash recovery success, sensor disconnect rates, GPS gap frequency, duplicate-session rate.
- Strength efficiency: average seconds to log a set, template reuse, abandoned sessions.
- Guidance efficacy: cue disablement rates, ignored/acted-on prompts.
- Post-workout completion: saved vs discarded, note prompt acceptance.

Quality dashboards should monitor:

- Session finalization failure rate.
- Route completeness and accuracy flags.
- HR completeness by platform/device context.
- Merge/suppression frequency and false-positive complaints.
- Export completeness issues.

Experimentation should focus on UX and reliability, not manipulative behavior.

## 40. Accessibility, Arabic, RTL, and inclusive fitness design

This is not a finishing layer. It must be designed into structure, labels, and layouts from the beginning.

### Accessibility requirements

- Large text support without truncating critical live metrics.
- High contrast and sunlight-readable themes.
- Reduced motion mode.
- VoiceOver/TalkBack-friendly live announcements.
- Haptic alternatives to audio.
- One-handed controls where practical.
- Big controls for gloves, sweat, or movement.

### Arabic/RTL requirements

- Metric tiles and screen flow reverse correctly under RTL.
- Mixed-language exercise names render cleanly.
- Arabic numerals/localized numerals configurable.
- Route directions and map labels should respect platform locale behavior.
- Template names and custom activities support Arabic-first entry.
- Avoid iconography or abbreviations that fail in Arabic context.

### Inclusive fitness design

- Adaptive and wheelchair-related modalities where platform-supported or custom-defined.
- No assumptions that all workouts involve steps, pace, or route.
- Custom activities bridge gaps where platforms do not natively model the user’s movement well.

## 41. Failure modes and edge-case inventory

A large practical inventory is essential because workout trust is fragile.

### Session control failures

- Accidental start.
- Accidental end.
- End pressed during motion.
- Pause confused with stop.
- Workout crosses midnight.
- Timezone change during long workout.
- Daylight-saving shift.

### Runtime failures

- App killed mid-workout.
- Watch disconnect.
- Phone/watch mirroring failure.
- Sensor disconnect/reconnect.
- Low battery on watch or phone.
- Foreground service killed on Android OEM device.[cite:12]
- Apple crash recovery invoked but data source not rebuilt correctly.[cite:31]

### Data failures

- Duplicate workout from BADAN + Garmin/Strava/Oura.
- GPS drift or route spikes.
- No GPS for indoor workout.
- Route partial due to signal loss.
- HR gaps at start or during sweat/contact failure.
- Invalid cadence/power bursts.
- Treadmill distance mismatch.
- Calories disagree across devices.
- False PR because a session was partial.
- Export incomplete because sync/write-back pending.

### Permission and policy failures

- User declines location but starts outdoor run.
- Health permissions revoked mid-session.
- HC unavailable or outdated on Android.[cite:14]
- Route consent required when reading third-party route in background on Android.[cite:14]
- Locked iPhone lacks workout data access because user denied prompt.[cite:31]

### UX/accessibility failures

- Strength logging too slow between sets.
- Screen unreadable in sunlight.
- User needs a minimal screen while moving fast.
- Large text breaks metric layout.
- RTL mixed-language exercise names overflow.
- Arabic numerals confuse fixed-width metric cards.

### Policy responses

Each failure mode should map to:

- Detection logic.
- User-facing copy.
- Recovery step.
- Telemetry event.
- Whether session quality is downgraded.
- Whether exports are annotated.

## 42. MVP, phased roadmap, and dependency map

### MVP

MVP should focus on a narrow but trustworthy core:

- Quick-start walk/run/strength/open workout.
- Apple Watch + iPhone core support; Android phone + Health Connect core support.
- Canonical session model with local persistence.
- Running/walking/cycling basics: time, distance, pace/speed, HR where available, route for outdoor.
- Strength manual logger with templates, rest timer, sets/reps/load, optional RPE.[cite:8]
- Post-workout overview + notebook basics.
- Provenance badges and quality notes.
- Export summary JSON/CSV + sets file.
- Offline operation and crash-safe checkpointing.

### Phase 2

- Interval workouts and structured sessions.
- Route map detail + elevation profile.
- Live Activities / Siri intents / watch complications on Apple.[cite:31]
- Wear OS live companion.
- Advanced source detail and duplicate-merge UI.
- AI concise summaries.
- PR and training-load views.

### Phase 3

- Vendor connectors and deep import reconciliation.
- Explain-this-chart AI and workout comparisons.
- Custom activity builder maturity.
- More adaptive/inclusive modality presets.
- File import/export expansion (GPX/FIT/TCX).
- Advanced zone and power analytics.

### Long-term

- Coach/partner review artifacts.
- Team or family shared templates with privacy boundaries.
- On-device model assistance for workout journaling.
- Rich route replay and heatmaps.

### Dependency highlights

- Canonical session model blocks nearly everything.[cite:9]
- Reliable local write path and checkpointing block live trust.[cite:7]
- Apple watch/phone mirroring depends on watch app investment and HealthKit session architecture.[cite:31]
- Android live excellence depends on service/runtime investment beyond Health Connect’s storage layer.[cite:12]

## 43. Detailed epics and backlog seed

### Epic groups

1. Workout domain model and persistence.
2. Apple workout runtime.
3. Android workout runtime.
4. Route capture and quality engine.
5. Strength session runner and templates.
6. Post-workout notebook.
7. Provenance and quality UI.
8. Guidance and cues.
9. Export/interoperability.
10. Accessibility + Arabic/RTL.
11. Reliability/testing/telemetry.

### Sample backlog seeds

- Define canonical `WorkoutSessionAggregate` and child entities.
- Implement local checkpoint store for active sessions.
- Build quick-start workout home cards.
- Implement Apple `HKWorkoutSession` manager with proper stop/end sequence.[cite:31]
- Implement Android `ExerciseSessionRecord` outbox with stable `clientRecordId`.[cite:12]
- Build route buffer and low-accuracy point filter.[cite:12]
- Build `StrengthSessionRunner` UI with crash resume.[cite:8]
- Add RPE/pain/note sheet.
- Add post-workout quality-note generator.
- Build source detail sheet and provenance badges.
- Add export bundle composer.
- Add RTL metric tile audit and Arabic naming tests.

## 44. Open-source libraries, SDKs, vendors, and build-vs-buy decisions

### Native SDKs to rely on directly

- Apple HealthKit workout stack (`HKWorkoutSession`, `HKLiveWorkoutBuilder`, `HKLiveWorkoutDataSource`).[cite:31][cite:17]
- Android Health Connect client and record APIs.[cite:12][cite:14]
- Standard location/mapping frameworks per platform.

### Likely third-party or open-source candidates

- Mapping/rendering library depending on BADAN’s mobile stack.
- Charting libraries for post-workout analysis.
- Local database abstraction already used in BADAN core.
- FIT/TCX/GPX parsing libraries later.

### Build vs buy principles

| Area | Build | Buy/Use SDK | Rationale |
|---|---|---|---|
| Core workout model | Build | No | Strategic repository asset |
| Strength logger | Build | No | Core differentiation |
| Platform session runtime | Build on official SDKs | No opaque vendor | Trust and deep integration |
| Maps | Likely use platform/vendor SDK | Yes | Commodity rendering |
| Vendor connectors | Mixed | Possibly | Depends on partnership/API cost |
| AI summarization | Build orchestration, maybe use model vendor | Mixed | Need BADAN privacy and grounding layer |

Avoid ceding the core session model or live workout runtime to a black-box SDK that weakens provenance or exportability.

## 45. Risks, anti-patterns, and what not to build

### Major risks

- Treating workout capture like just another imported health card.
- Building a run-first UI that marginalizes strength and hybrid users.
- Overpromising live coaching beyond BADAN’s evidence quality.
- Hiding platform limitations and creating false expectations.
- Letting duplicate sessions and source conflicts rot trust.
- Forcing cloud dependence into live workout execution.

### Anti-patterns

- Showing unavailable metrics as zeros.
- Labeling estimates as facts.
- Flattening strength into notes.
- Treating all calories as interchangeable.
- Auto-merging conflicting workouts without lineage.
- Designing RTL as a late-stage “flip.”
- Overusing notifications and spoken cues.

### What not to build early

- Fully autonomous training coach.
- Medical or emergency detection framing.
- Fancy AI route storytelling before session reliability is solved.
- Massive vendor integration matrix before canonical session quality is proven.
- Auto-rep detection as a core requirement.

## 46. Long-term opportunities

Longer term, BADAN can turn the live monitor into a unique body-of-work archive.

Opportunities include:

- Deep week/month training narratives tied to sleep/recovery context.
- Hybrid-athlete dashboards across cardio and strength.
- Adaptive templates informed by recent history, while staying non-prescriptive.
- Better import/export portability than most fitness apps.
- Arabic-first fitness taxonomy and training journaling uncommon in the market.
- Unified health-and-performance storytelling without hiding the raw record underneath.

## 47. Final recommendations

1. **Build the live monitor as a repository-native session system, not as a timer widget.** BADAN already has the right schema instincts around sessions, child payloads, provenance, and exports; this feature should deepen that foundation, not bypass it.[cite:6][cite:8][cite:9]
2. **Ship a narrow, trustworthy MVP across walk/run/strength/open workout before chasing every sport.** Reliability, checkpointing, and post-workout notebook quality matter more than headline modality count.
3. **On Apple, adopt a watch-first sensor strategy with iPhone mirroring and phone-only graceful degradation.** This matches Apple’s official guidance and hardware realities, especially around heart rate.[cite:31]
4. **On Android, keep BADAN’s own live runtime separate from Health Connect persistence.** Health Connect is the interoperability backbone, not the whole workout engine.[cite:12][cite:14]
5. **Treat strength as a flagship domain.** BADAN’s existing strength system-of-record concepts are a real differentiator and should be productized aggressively.[cite:6][cite:8]
6. **Make provenance visible in everyday UX.** Small source badges, quality notes, and deeper source sheets can convert trust architecture into user value.[cite:6]
7. **Keep all guidance optional, calm, and non-diagnostic.** The right product voice is observant, not commanding.
8. **Design Arabic/RTL and accessibility structurally from the first implementation sprint.** Retrofitting them later will break workout layouts and naming systems.
9. **Invest early in crash recovery, duplicate suppression, and delayed-sync transparency.** Users forgive missing polish before they forgive lost workouts.[cite:8][cite:9][cite:12][cite:31]
10. **Use AI for grounded summarization and organization, not pseudo-expertise.** BADAN should help users understand workouts they actually did, not invent certainty.
