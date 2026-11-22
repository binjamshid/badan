# BADAN Widgets, Complications, and Ambient Health Research

## 1. Executive summary

BADAN’s ambient and glanceable experience should turn the phone, watch, and lock screen into a calm health radar for casual users, and a configurable data cockpit for power users, all built on a single shared health-data model that never pretends to diagnose or guarantee medical outcomes. This research document maps current Apple and Android capabilities for widgets, complications, tiles, Live Activities, App Intents, and health data refresh limits, then proposes a taxonomy, catalog, architecture, and phased roadmap for implementing a world-class BADAN ecosystem of surfaces across iOS, watchOS, Android, and Wear OS.[^1][^2][^3][^4][^5]

At a high level, BADAN should:

- Offer a small set of calm, highly opinionated daily-summary surfaces for casual users (One True Sentence, recovery, sleep, activity, stress, health monitor, timeline, weekly preview).[^6][^7]
- Expose a rich catalog of metric widgets, logging shortcuts, and power-user dashboards as configurable templates driven by App Intents and widget configuration for iOS and Glance/tiles for Android/Wear OS.[^2][^3][^5]
- Use Live Activities and Dynamic Island sparingly for time-bounded flows (workouts, medication windows, export runs, acute symptom tracking), favoring a clear state model and explicit user opt‑in.[^8][^9]
- Implement a safe complication system on Apple Watch and Wear OS that shows compact, glanceable status, with strong privacy modes and clear stale-data indicators.[^10][^11][^12]
- Centralize widget and complication configuration in a customization layer with presets (casual, athlete, recovery, hydration, cycle/pregnancy, quantified‑self) and guardrails against overwhelming or shaming the user.[^7][^5]
- Architect a shared domain model for health metrics, scores, sources, freshness, and privacy flags, then fan out to platform-specific presentation layers (WidgetKit, ClockKit/watchOS, ActivityKit, Android App Widgets, Wear OS Tiles and complications).[^3][^5][^12][^1]


## 2. Research methodology and source quality

This document is based primarily on official Apple and Android platform documentation, supplemented by recent WWDC sessions, Android design guides, and a small number of high-quality technical articles and forum clarifications about practical limitations (HealthKit background delivery, WidgetKit reload behavior, Wear OS dynamic tiles).[^5][^1][^2][^3]

Key source categories:

- Apple Developer Documentation: WidgetKit, ActivityKit / Live Activities, App Intents, Intents/SiriKit, HealthKit background delivery, ClockKit/watchOS complications, WidgetKit “Keeping a widget up to date”.[^13][^14][^15][^1][^8][^2]
- Apple WWDC videos and Discover articles: ActivityKit and Dynamic Island design guidance, App Intents evolution, widget visibility and Smart Stacks.[^9][^16][^8][^6]
- Android Developer Documentation: App Widgets, Android widgets design guidance, Glance-based widgets, Wear OS Tiles, Wear OS complications and Watch Face Format.[^4][^17][^11][^3][^7][^5][^10]
- HealthKit background delivery clarifications: official HealthKit API docs plus pragmatic explanations of throttling and minimum frequencies from experienced developers and SDK authors.[^18][^19][^20][^13]
- WidgetKit practical behavior: official guidance on minimum reload intervals, plus developer observations confirming that timeline reload policies such as `.atEnd` and `.after` are subject to system coalescing.[^14][^21][^15][^22]

Where forum threads or articles diverged from official documentation, this document treats official docs as primary and uses external sources only to illustrate likely real-world behavior (e.g., HealthKit hourly caps for step count, widget reload delays). Any recommendations that depend on non‑guaranteed behaviors are explicitly tagged as best‑effort rather than strict contracts.[^20][^13][^18]

## 3. Platform capability map

### 3.1 iOS and iPadOS (WidgetKit, ActivityKit, App Intents)

- WidgetKit provides Home Screen and Lock Screen widgets, including system small/medium/large sizes and accessory circular/rectangular/inline types, plus iPad extra‑large widgets.[^15][^1]
- Widgets are SwiftUI views driven by a timeline provider; WidgetKit enforces a minimum reload interval (approximately 5 minutes), so timelines should be built around coarse‑grained updates rather than real‑time data.[^14][^15]
- Widgets can be configured via StaticConfiguration (fixed behavior) or AppIntentConfiguration (user‑configurable parameters backed by App Intents).[^23][^1]
- ActivityKit enables Live Activities on the Lock Screen and Dynamic Island, with attributes and content states that can be updated locally or via push notifications; Dynamic Island can display up to two Live Activities simultaneously and supports compact, expanded, and minimal presentations.[^24][^8][^9]
- App Intents formalize app actions and entities so that Siri, Shortcuts, Spotlight, widgets, and Apple Intelligence can discover and invoke them with natural language and automation.[^25][^26][^16][^2]
- Intents/SiriKit is still relevant for certain domains, but for new work BADAN should prefer App Intents because they unify integration across Siri, Shortcuts, widgets, and future AI experiences.[^27][^26][^25]


### 3.2 watchOS (complications, Smart Stack, app architecture)

- ClockKit complications are small elements on the watch face that show app‑specific data; watchOS defines several complication families (modular, circular, corner, rectangular, etc.), each with specific templates for text and images.[^12]
- Complication data is provided via a `CLKComplicationDataSource` that supplies past, present, and future timeline entries; timelines allow watch faces to show relevant data across time without continuous execution.[^12]
- Apple Watch supports Smart Stack widgets, which are WidgetKit‑based “cards” users can scroll through; they appear contextually based on usage and relevance.[^1][^6]
- watchOS apps rely on a WatchKit extension; complications and apps share data via frameworks and can use background refresh and HealthKit delivery to update complication timelines, subject to power‑management constraints.[^28][^12]


### 3.3 HealthKit background delivery and background limits

- `enableBackgroundDelivery(for:frequency:withCompletion:)` allows apps to be activated in the background when HealthKit data changes, subject to a maximum cadence defined by the frequency enum (immediate, hourly, daily, etc.).[^29][^13]
- Certain types, notably step count, have an enforced minimum frequency such as hourly, regardless of `.immediate`, and system heuristics (battery, device state, app activity) can further throttle updates.[^13][^18][^20]
- Background delivery requires HKObserverQuery instances to be active, and apps must recreate observer queries on launch and call completion handlers promptly; behavior varies across devices and watch models.[^19][^28]
- Third‑party analyses confirm that background delivery is opportunistic and cannot guarantee fixed schedules; updates may arrive hourly, daily, or at system‑chosen moments.[^20]


### 3.4 iOS background refresh, notifications, and widget limits

- Widgets cannot run arbitrary background code; their timelines must be prepared by the host app, which may be invoked via background refresh, push triggers, or HealthKit observer callbacks — all subject to power management and frequency limits.[^15][^14]
- WidgetKit imposes a minimum time before reloading a widget, and developers report that `.atEnd` and `.after(date:)` reload policies are treated as earliest possible times rather than guarantees; the system may delay reloads several minutes.[^21][^22][^15]
- Real‑time or second‑by‑second health streaming is better served via Live Activities and on‑device sessions (e.g., workouts) rather than static widgets.[^8][^24]


### 3.5 Android (widgets, shortcuts, background limits)

- Android App Widgets are miniature app views (RemoteViews or Glance composables) hosted on the home screen or other surfaces and updated periodically via AppWidgetProvider.[^3][^4]
- Widgets are built from RemoteViews, which support a subset of view types; custom views are not supported, and interactions rely on PendingIntents (e.g., tapping a widget to open an activity or broadcast).[^30][^3]
- `android:updatePeriodMillis` controls periodic updates with a minimum of 30 minutes; for fresher data, apps typically use alarms, WorkManager, or push notification triggers, subject to Doze and background execution limits.[^30][^3]
- Android design guidance emphasizes a single primary use case per widget, scalable layouts across sizes, and at‑a‑glance content rather than mini‑apps.[^7][^4]


### 3.6 Wear OS (tiles, complications)

- Wear OS Tiles provide swipeable cards adjacent to the watch face that show a small amount of key information and quick actions; they are defined declaratively via ProtoLayout and Jetpack tiles libraries.[^31][^5]
- Tiles should avoid frequent network calls; background work (e.g., syncing health data) is handled via WorkManager, with results cached locally; tiles then render from local state.[^32][^5]
- Tiles can use dynamic expressions and platform health sources (e.g., heart rate BPM) to stream updates and animate UI elements, but there is a limit on the number of dynamic expressions per tile.[^32]
- Wear OS complications are data slots on watch faces; apps expose complication data sources (via older Complication API or Watch Face Format) that the watch face can render, supporting types like short text, long text, ranged values, icons, etc.[^11][^33][^10]


## 4. BADAN ambient-experience philosophy

BADAN’s ambient layer must reconcile two user archetypes:

- Casual, reassurance‑seeking users who want a calm, minimal summary of “How am I doing today?” without graphs, alarms, or jargon.[^4][^7]
- Power users (athletes, quantified‑self practitioners, caregivers) who want dense, configurable surfaces showing multiple metrics, baselines, and trends, but still presented ethically and clearly as wellness insights rather than diagnoses.[^5][^7]

Guiding principles:

- Repository‑first: widgets and complications are views into a trustworthy personal health repository, not stand‑alone calculators; they should primarily read from BADAN’s normalized health model and precomputed scores.[^1][^3]
- Wellness‑oriented: avoid language or visuals that imply medical certainty or emergency; instead, use tonal scales (calm, watchful, elevated) with explicit disclaimers and links to detailed interpretation screens.[^34][^8]
- Privacy‑respecting: treat lock screens, watch faces, and tiles as semi‑public surfaces; default to high‑privacy modes that show aggregate or obfuscated states rather than direct sensitive values (e.g., cycle phase, pregnancy, diagnoses).[^10][^5]
- Export‑friendly: ambient surfaces should remind users of export schedules and sync health, but never expose raw identifiers or sensitive file paths; deep links should land in secure screens for exporting data.[^3][^20]
- Cross‑platform consistency: the taxonomy of widgets and complications should map consistently across iOS, Android, watchOS, and Wear OS, anchored in BADAN’s shared domain model of metrics, sources, freshness, and privacy flags.[^5][^1][^3]


## 5. Widget and complication taxonomy

This section enumerates each major widget or complication type and describes its purpose, data fit, user segment, density, interaction, refresh, limitations, privacy, accessibility, and v1 viability.

### 5.1 iPhone Home Screen widgets (WidgetKit)

#### 5.1.1 Small Home Screen widget (systemSmall)

- User purpose: Single core metric or compact daily status (e.g., One True Sentence, readiness score, steps).[^15][^1]
- Best-fit BADAN data: Daily summary headline, key score (recovery, stress, sleep), or a single metric like steps, HRV, or hydration.[^1]
- Intended segment: Casual users (headline summary) and power users (configurable metric tile).[^4]
- Visual density: Low–medium; one primary value, short label, optional icon or tiny sparkline.[^7]
- Interaction model: Tap to open BADAN to the corresponding section; optional App Intent configuration to select metric and privacy mode.[^2][^23]
- Refresh expectations: Timeline entries every 30–60 minutes or when significant health-data changes occur; rely on HealthKit background delivery and periodic app refresh.[^13][^15]
- Platform limitations: No rich interactivity beyond tap; reload minimum ~5 minutes; background data may arrive hourly or less.[^18][^15]
- Privacy risk: Moderate; visible on Home Screen but less exposed than lock screen; avoid sensitive reproductive or mental health labels in default config.[^10][^5]
- Accessibility: Large text option, high contrast, VoiceOver labels describing metric and trend; consider reduced motion variants.[^7]
- v1 decision: Yes, core v1 surface with One True Sentence and configurable single-metric variants.


#### 5.1.2 Medium Home Screen widget (systemMedium)

- User purpose: Compact multi‑metric daily overview (e.g., readiness + sleep + activity) or a mixed summary + shortcuts tile.[^1][^7]
- Best-fit BADAN data: 3–4 metrics plus One True Sentence; or 2 metrics plus 2 logging shortcuts.[^1]
- Intended segment: Transitional users between casual and power; athletes who want slightly more density but not a full dashboard.[^4]
- Visual density: Medium; grid of metrics with clear hierarchy (primary score larger, secondary metrics smaller).[^7]
- Interaction model: Tap zones deep‑link into respective screens (recovery, sleep, activity, logging); overall tap opens daily summary.[^30][^3]
- Refresh expectations: Similar to small widget; 30–60 minute cadence plus “on demand” when app refreshes data.[^13][^15]
- Platform limitations: Same WidgetKit constraints; avoid relying on real‑time streaming.[^14][^15]
- Privacy risk: Higher; multiple metrics visible; default profile should avoid explicit diagnoses or reproductive info unless user opts‑in.[^5][^10]
- Accessibility: Ensure hit targets meet minimum size; text alternatives for icons; support Dynamic Type scaling.[^7]
- v1 decision: Yes, v1 surface for daily overview.


#### 5.1.3 Large Home Screen widget (systemLarge)

- User purpose: Rich daily “health board” with multiple sections: One True Sentence, key scores, simple timeline, and 1–2 actionable shortcuts.[^6][^1]
- Best-fit BADAN data: Recovery, sleep, activity, stress, health monitor, timeline of today’s events, weekly trend mini chart.[^1]
- Intended segment: Power users, quantified‑self practitioners, caregivers; not default for casual users but discoverable.[^7]
- Visual density: High but structured; banded layout with sections and clear grouping.[^7]
- Interaction model: Tappable sections for deep links; App Intent configuration controlling which sections appear.[^23][^2]
- Refresh expectations: At most hourly for trend blocks; daily for weekly previews; timeline can be updated as new events sync.[^14][^13]
- Platform limitations: Layout complexity; risk of clutter; must respect WidgetKit’s limited timeline updates.[^15]
- Privacy risk: Significant; should be opt‑in and support privacy modes (blur, generic labels).[^10][^5]
- Accessibility: Section headers readable; alt text for trend indicators; color‑blind friendly palettes.[^7]
- v1 decision: Maybe; design now, potentially launch in v1.1+ after core metrics stabilize.


#### 5.1.4 Extra‑large iPad widget (systemExtraLarge)

- User purpose: Dashboard for tablet home screen showing multi‑day trends and advanced metrics.[^1]
- Best-fit BADAN data: Week‑long sleep and activity charts, readiness evolution, anomalies inbox.[^1]
- Intended segment: Power users and clinicians who use BADAN on iPad; limited audience but high value.[^4]
- Visual density: Very high; effectively a mini analytics board.[^7]
- Interaction model: Section deep links; possible multi‑pane layout switching via tabs (within widget constraints).[^1]
- Refresh expectations: 1–2 times per day; focus on “last synced at” and trend summary rather than fine-grained changes.[^20][^15]
- Platform limitations: Only on iPad; complex to implement; background sync still subject to HealthKit limits.[^13][^1]
- Privacy risk: Similar to large; strong privacy controls needed if iPad used in shared environments.[^5]
- Accessibility: Larger charts and text; support keyboard navigation for focus if used on iPadOS.[^7]
- v1 decision: Later; not required for initial phone‑centric launch.


### 5.2 Lock Screen widgets (WidgetKit accessory)

#### 5.2.1 Circular Lock Screen widget (accessoryCircular)

- User purpose: Single key metric or status accessible at a glance on the lock screen.[^15][^1]
- Best-fit BADAN data: Readiness score, health monitor status (OK / watchful / elevated), or steps/progress ring.[^1]
- Intended segment: Mixed; athletes and engaged users; casual users may choose a very simple “Today: steady” indicator.[^4]
- Visual density: Low; numeric or simple gauge; minimal text.[^7]
- Interaction model: Tap opens BADAN to daily summary; no in‑widget controls.[^1]
- Refresh expectations: Hourly or when health status meaningfully changes; must avoid jitter.[^14][^13]
- Platform limitations: Very small canvas; no multi-line text; refresh limited by WidgetKit.[^15]
- Privacy risk: High; lock screen is visible to bystanders; default to status icons or generic words (“Steady”, “Check‑in suggested”) instead of specific scores.[^10][^5]
- Accessibility: Strong contrast; avoid color‑only communication for status.[^7]
- v1 decision: Yes, with conservative default.


#### 5.2.2 Rectangular Lock Screen widget (accessoryRectangular)

- User purpose: Slightly richer summary, such as readiness + short label or sleep status.[^1]
- Best-fit BADAN data: “Today’s readiness” with numeric score and a short textual interpretation; or last night’s sleep duration and quality band.[^1]
- Intended segment: Users willing to show slightly more detail on lock screen.[^4]
- Visual density: Low–medium; one metric plus text line.[^7]
- Interaction model: Tap to open details; config for metric choice and privacy wording.[^2][^23]
- Refresh expectations: Same as circular; avoid frequent changes.[^14][^15]
- Platform limitations: Limited text space; must truncate elegantly.[^15]
- Privacy risk: High; treat as opt‑in and allow “masked” mode (e.g., show only status icon and phrase).[^5][^10]
- Accessibility: High legibility fonts; optional larger text variant.[^7]
- v1 decision: Yes for readiness/sleep; more complex combos later.


#### 5.2.3 Inline Lock Screen widget (accessoryInline)

- User purpose: Embedded text line along the clock, e.g., “BADAN: Today looks stable; aim for hydration.”[^1]
- Best-fit BADAN data: One True Sentence daily summary; short textual hint based on aggregated metrics.[^1]
- Intended segment: Casual users who want gentle guidance wording.[^4]
- Visual density: Extremely low; one sentence.[^7]
- Interaction model: Tap opens daily overview; content computed once per morning and updated sparingly.[^13][^14]
- Platform limitations: Single line of text; has to avoid long sentences.[^15]
- Privacy risk: Moderate; avoid explicit sensitive terms; speak generically (“energy”, “recovery”) rather than medical labels.[^10][^5]
- Accessibility: Short phrases; ensure language localization is robust.[^7]
- v1 decision: Yes; core expression of BADAN’s calm philosophy.


### 5.3 Apple Watch complications (ClockKit)

Complication families relevant to BADAN include modular large/small, circular, corner, and rectangular, each suited to different watch faces.[^12]

#### 5.3.1 Corner complication

- User purpose: Tiny indicator on the corner of the watch face, ideal for status icons and short text.[^12]
- Best-fit BADAN data: Health monitor status icon plus short word (“OK”, “Watchful”).[^12]
- Segment: All segments; non‑intrusive; good default complication.[^10]
- Density: Very low.[^12]
- Interaction: Tap opens BADAN watch app home.[^12]
- Refresh: 4+ times per hour when complication active, per Apple guidance; tied to HealthKit background delivery and app refresh.[^28]
- Limitations: Limited characters; high reliance on iconography.[^12]
- Privacy: High; use neutral wording, avoid explicit conditions.[^10]
- Accessibility: Clear icon shapes; alt text for VoiceOver.[^34]
- v1 decision: Yes.


#### 5.3.2 Circular complication

- User purpose: Small circle showing numeric value or ring, e.g., readiness score or steps ring.[^12]
- Best-fit BADAN data: Readiness score, steps progress, hydration progress, sleep ring.[^12]
- Segment: Active users and athletes.[^10]
- Density: Low; one primary value.[^12]
- Interaction: Tap to open relevant section in BADAN watch app.[^12]
- Refresh: Similar to corner; uses timeline entries; background updates limited but better when complication present.[^28]
- Limitations: Tiny; no multi‑metric display.[^12]
- Privacy: Numeric values may reveal more; allow privacy mode to replace with generic band (“High”, “Moderate”).[^10]
- Accessibility: Use color and shape redundantly; consider high‑contrast theme.[^34]
- v1 decision: Yes.


#### 5.3.3 Rectangular complication

- User purpose: Wider card showing a metric plus short description, e.g., sleep duration + quality label.[^12]
- Best-fit BADAN data: Sleep summary, readiness + short phrase, or “Today’s focus” suggestion.[^12]
- Segment: Engaged users.[^10]
- Density: Low–medium; one metric and one line of text.[^12]
- Interaction: Tap to open relevant detail.[^12]
- Refresh: At most several times per hour; heavy data should be precomputed.[^28]
- Limitations: Fit text constraints; watch faces that support rectangular slots are limited.[^12]
- Privacy: Similar to rectangular lock widget; require opt‑in for more revealing text.[^10]
- Accessibility: Medium sized text; localization important.[^34]
- v1 decision: Yes.


#### 5.3.4 Modular large/small complications

- User purpose: More detailed text/graph combos for modular watch faces; ideal for multi‑metric summary or timeline snippet.[^12]
- Best-fit BADAN data: Sleep + readiness + activity in stacked bands; or anomalies inbox.[^12]
- Segment: Power users.[^10]
- Density: Medium–high.[^12]
- Interaction: Section deep links; but limited by template types.[^12]
- Refresh: Similar to other complications; timeline entries hourly or when events occur.[^28]
- Limitations: Template‑driven layout; no arbitrary design.[^12]
- Privacy: High; treat as opt‑in with privacy modes.[^10]
- Accessibility: Ensure text doesn’t shrink excessively; maintain clarity.[^34]
- v1 decision: Later; design after small/rectangular are stable.


### 5.4 Apple Watch Smart Stack widgets

- User purpose: Contextual scrollable cards that show BADAN summaries when relevant (morning readiness, nightly sleep, hydration reminders).[^6][^1]
- Data fit: One True Sentence, daily summary, hydration reminders, anomalies requiring review.[^1]
- Segment: Casual and engaged users who don’t pin complications but use Smart Stack.[^6]
- Density: Low–medium; similar to rectangular complication but with more space.[^6]
- Interaction: Tap opens BADAN watch app; potential quick actions via App Intents when supported.[^25][^2]
- Refresh: System decides when to show; widget timeline updates similar to iOS widgets but tailored to watch context.[^14][^1]
- Limitations: Smart Stack ranking controlled by system; BADAN can hint relevance but not guarantee presence.[^6]
- Privacy: Follows watch privacy defaults; treat content as semi‑private but still avoid explicit diagnoses.[^10]
- Accessibility: Larger cards; ensure good typography and color contrast.[^34]
- v1 decision: Yes for daily summary and hydration reminder tiles.


### 5.5 Apple Watch glanceable app surfaces

- User purpose: First screen of BADAN watch app shows quick health overview rather than navigation chrome.[^34]
- Data fit: One True Sentence, readiness, simple traffic‑light indicator for health monitor, plus 1–2 key actions (log symptom, start workout).[^34]
- Segment: All watch app users.
- Density: Medium.[^34]
- Interaction: Tappable cards leading to detail sections; App Intents bridging to Shortcuts.[^2]
- Refresh: Real‑time while app is open; background limited.[^12]
- Limitations: watchOS execution time; must be performant.[^34]
- Privacy: Respect watch’s “Hide sensitive complications” setting by providing app‑level privacy toggle.[^10]
- Accessibility: VoiceOver labels, large hit areas, support for different text sizes.[^34]
- v1 decision: Yes; central to watch experience.


### 5.6 iPhone “complication-like” quick glance components and shortcuts

These are not widgets per se, but launch surfaces:

- Home Screen quick actions (long‑press app icon): App Intents‑backed shortcuts like “Log water”, “Log symptom”, “Quick health check‑in”.[^25][^2]
- Siri and Shortcuts actions: Voice and automation entry points for logging, exporting, and checking status; integrated via App Intents.[^26][^2]
- In‑app “Today bar”: Always-visible bar at top of main app screen showing One True Sentence and key metric chips; not a widget but part of ambient design.[^6]

These surfaces rely on the same taxonomy of actions and metrics defined for widgets and complications.

### 5.7 Android widgets (sizes)

#### 5.7.1 Small Android widget

- Purpose: Single metric or daily status; parallels iOS small widget.[^3][^4]
- Data: Readiness, steps, hydration, sleep status.[^3]
- Segment: Casual and power users.
- Density: Low.
- Interaction: Tap to open app; optional small button for logging (if supported by RemoteViews).[^30][^3]
- Refresh: `updatePeriodMillis` ≥ 30 minutes; use WorkManager or push for event-based refresh.[^17][^3]
- Limitations: RemoteViews constraints; no arbitrary custom views.[^3]
- Privacy: Same as iOS Home widget; lock screen equivalents depend on OEM.[^4]
- Accessibility: Follow Android widget accessibility and contrast guidelines.[^7]
- v1 decision: Yes.


#### 5.7.2 Medium and large Android widgets

- Purpose: Multi‑metric overview and shortcuts, similar to iOS medium/large.[^4]
- Data: Daily summary, metrics, logging shortcuts.[^3]
- Segment: Engaged and power users.
- Density: Medium–high.[^7]
- Interaction: Multiple tap zones for deep links and logging.[^30]
- Refresh: Same constraints; rely on cached data and explicit “last updated”.[^20][^3]
- Limitations: Layout must scale to different grid sizes.[^7]
- Privacy, accessibility: Same concerns as iOS.[^4]
- v1 decision: Yes for medium; large later.


### 5.8 Wear OS tiles and complications

- Tiles: Provide quick access to key info (e.g., readiness, hydration status, steps) and actions (start workout, log water), with dynamic expressions for heart rate or step count.[^32][^5]
- Complications: Provide tiny status values on watch faces (e.g., readiness score, steps ring, health monitor icon).[^11][^10]
- Segment: Wear OS watch users, analogous to Apple Watch users.
- Limitations: Tiles cannot scroll; dynamic expression count limited; complications must conform to data types and Watch Face Format expectations.[^11][^32][^5]
- v1 decision: Yes for at least one tile and one complication showing health status and readiness.


### 5.9 Existence decisions summary

- V1 surfaces: iOS small/medium home widgets; lock inline and circular readiness/summary; One True Sentence; key metric widgets (readiness, sleep, steps, hydration); Apple Watch corner/circular/rectangular complications; Smart Stack daily summary; watch app glance screen; Android small/medium widgets; Wear OS tile; core complications on both platforms.
- Later surfaces: iPad extra‑large dashboard; large iOS widgets; modular watch complications; advanced power‑user dashboards; multi‑metric tiles and highly specialized widgets.
- Never (or very constrained): Widgets that display detailed diagnoses, raw lab values without context, or reproductive health data on lock screens; any surface that might meaningfully shame or alarm users.


## 6. Complete BADAN widget catalog

This section lists major widget families, with intent to support both casual and power users while leveraging platform constraints.

### 6.1 Daily summary widgets

#### 6.1.1 One True Sentence daily summary

- Concept: A generative but rule‑bound sentence summarizing today’s health state (e.g., “Today looks stable; prioritize hydration and early winding down.”).[^6]
- Surfaces: iOS inline lock widget, small home widget, medium home widget, Apple Watch Smart Stack card, watch app top banner, Android small/medium widget, Wear OS tile headline.[^5][^1]
- Data inputs: Aggregated recovery/readiness, sleep quality, activity load, stress indicators, anomalies; meta‑data about data freshness and confidence.[^20][^13][^1]
- Casual vs power: Casual users see only the sentence; power users can tap to expand metrics.[^4]
- Refresh: Once per morning, then at most a few times per day when underlying scores shift meaningfully; never jitter with minor changes.[^13][^15]


#### 6.1.2 Recovery / readiness overview

- Concept: Score and band indicating recovery or readiness to train, based on sleep, strain, HRV, and other markers, similar in spirit to devices like WHOOP but staying non‑diagnostic.[^6]
- Surfaces: Small/medium/large home widgets; lock circular/rectangular; Apple Watch circular/rectangular complications; Wear OS complication; Android widgets.[^10][^1][^12]
- Data inputs: Precomputed BADAN readiness score; contributing metrics.[^1]
- Casual vs power: Casual users see band and phrase (“Ready for normal day”); power users can opt to show numeric score and trend.[^4]
- Refresh: Once per day (post sleep) with optional mid‑day adjustments; background limits favor daily cadence.[^20][^13]


#### 6.1.3 Sleep overview

- Concept: Last night’s sleep duration, efficiency, and quality band.[^12]
- Surfaces: Home widgets; rectangular lock widget; Apple Watch rectangular/modular complication; Android widget; Wear OS tile segment.[^5][^1][^12]
- Data inputs: Sleep duration, sleep staging, interruptions, sleep debt.[^13]
- Casual vs power: Casual sees duration and phrase; power sees duration plus debt trend or consistency.[^4]
- Refresh: Daily after sleep session ends; no need for more frequent updates.[^20][^13]


#### 6.1.4 Activity overview

- Concept: Steps, active energy, exercise minutes, movement rings.[^3]
- Surfaces: Home widgets, Apple Watch complications, Android widgets, Wear OS tile.[^5][^1][^12]
- Data inputs: Step count, active energy, exercise time, standing or movement metrics.[^13]
- Casual vs power: Casual sees ring or simple “on track / behind”; power sees numeric details and maybe micro‑goals.[^4]
- Refresh: Multiple times per day; limited by HealthKit hourly caps and Android Doze; show “last updated” to avoid misinterpretation.[^18][^20][^13]


#### 6.1.5 Strain / training-load overview

- Concept: Composite strain score or training load indicator with envelope (too low, appropriate, high).[^6]
- Surfaces: Power‑user home widgets, Apple Watch complications, Wear OS tiles.[^5][^12]
- Data inputs: Activity intensity, HR zones, recent training sessions, recovery markers.[^13]
- Casual vs power: Casual sees broad band; power sees numeric TSS‑style values or envelopes.[^4]
- Refresh: Once per day or post‑workout; recalculated when new workouts sync.[^20][^13]


#### 6.1.6 Stress overview

- Concept: Non‑diagnostic stress indicator based on HRV, resting heart rate trends, activity, and user‑logged mood/symptoms.[^6]
- Surfaces: Home widgets, watch complications, Android widgets.[^1][^12]
- Data inputs: HRV, RHR, self‑reported stress, sleep.[^13]
- Casual vs power: Simple label (“Calm”, “Elevated”) vs numeric stress index.[^4]
- Refresh: At most hourly; aware of HRV measurement constraints; show confidence level.[^20]


#### 6.1.7 Health Monitor overview

- Concept: BADAN’s health monitor tracks anomalies (e.g., unusually high resting HR, unusual sleep pattern, flagged symptoms) and surfaces a simple traffic‑light status.[^12]
- Surfaces: Corner complications, circular widgets, tiles, anomalies inbox widget.[^5][^10]
- Data inputs: Deviation from personal baselines, flagged events, missing data.[^20]
- Casual vs power: Casual sees simple status; power sees count of anomalies and can tap into “health inbox”.[^4]
- Refresh: When new anomalies detected; show last checked timestamp.[^20]


#### 6.1.8 Today’s timeline

- Concept: Chronological view of known health events (sleep start/stop, workouts, medication windows, symptoms logs).[^3]
- Surfaces: Medium/large widgets; iPad extra‑large; in‑app summary.[^1]
- Data inputs: Events aggregated from HealthKit, Health Connect, and manual logs.[^13]
- Casual vs power: Casual sees high‑level; power sees more detailed labels.[^4]
- Refresh: Event‑driven; limited by background deliverability.[^20][^13]


#### 6.1.9 Weekly trend preview

- Concept: Sparkline or mini chart summarizing week‑long trends for sleep, activity, readiness.[^1]
- Surfaces: Large/iPad widgets; modular complications; Android large widgets.[^4][^12]
- Data inputs: Aggregated metrics per day.[^13]
- Casual vs power: Casual sees general “trending up/down”; power sees small chart.[^7]
- Refresh: Daily.[^13]


### 6.2 Logging shortcut widgets

These surfaces mostly take the form of tappable actions backed by App Intents on iOS and PendingIntents/App Actions on Android.[^2][^3]

Examples (each as small/mid widgets or quick actions):

- Log water: Button or tile; increments hydration; may open quick log view.[^30][^3]
- Log meal: Opens BADAN meal logging screen with prefilled context.[^2]
- Log medication: Quick log for scheduled medication; optionally integrated with reminders.[^27]
- Log symptom: Opens a simple, low‑friction symptom-editor; avoid implying diagnosis.[^2]
- Log mood: Quick mood picker with simple faces; optionally linked to stress overview.[^3]
- Log workout: Starts manual workout logging or marks a non‑tracked workout.[^2]
- Log period event: For users who opt‑in; treat as highly sensitive data (no lock screen surfaces).[^10]
- Log pregnancy symptom: Same as above; extremely sensitive; surfaces restricted to app or private widgets.[^10]
- Start live workout: Launches BADAN live activity for workout (iOS) or session (Android/Wear); optionally drives Live Activity and tile.[^8][^5]
- Export recent data: Quick action to trigger export job, with status shown in export widgets.[^20]
- Open quick health check‑in: Launches a short in‑app flow to update subjective health state and symptoms.[^2]

These shortcuts should be packaged into:

- iOS: App Icon quick actions, App Intents, Shortcuts, small widgets with single button, medium widgets with 2–4 quick actions.[^23][^2]
- Android: widgets with buttons using `setOnClickPendingIntent`, app shortcuts, App Actions for Assistant.[^30][^3]
- Wear OS tiles: quick action buttons like “Log water”, “Start workout”.[^31][^5]


### 6.3 Metric‑focused widgets

Each metric should support:

- Single‑metric small widget/complication.
- Multi‑metric combos in medium/large widgets.
- Power‑user dashboards with multiple metrics grouped.

Key metrics and notes:

- Heart rate: Current HR vs baseline; surfaces limited to watch and tile; avoid lock screen streaming.[^32]
- Resting heart rate: Morning RHR trend; daily metric widget; good for readiness and stress.[^13]
- HRV: Nightly or periodic HRV metrics; moderate sensitivity; require caution in interpretation.[^20][^13]
- Sleep duration and debt: Clear visual of hours sleeping vs target; highlight debt but avoid shaming phrasing.[^13]
- Steps: Steps count and goal progress; widely acceptable metric for ambient widgets.[^3][^4]
- Active energy: Calories burned; optional for those who track; avoid weight‑loss framing unless user explicitly configures.[^13]
- Exercise minutes: Minutes of moderate/vigorous activity; can show progress vs goals.[^4]
- Standing/movement: Hours standing; daily ring; good for watch complications.[^12]
- Weight: Highly sensitive; consider restricting to app, not lock/home default widgets.[^10]
- Body‑fat trend: Sensitive; only in private surfaces; show trends but avoid “good/bad” language.[^10]
- Hydration: Intake vs goal; good candidate for tile and widget.[^5]
- Blood glucose: Only when user explicitly authorizes and data is available; treat as extremely sensitive; limit to app and private surfaces.[^20]
- Cycle phase: Sensitive; only in app and private widgets with privacy modes.[^10]
- Pregnancy week: Highly sensitive; surfaces limited to opt‑in private widgets.[^10]
- Medication reminder status: Show upcoming doses; treat as moderately sensitive; avoid names on lock screen.[^10]
- Symptom trend: Graph of symptom frequency/intensity; require careful tone and disclaimers.[^34]
- Lab‑result trend: If BADAN stores lab results, show aggregated trends with context; avoid numeric detail on ambient surfaces.[^20]
- Recovery score and stress state: Already covered in daily summary; also available as single‑metric tiles.[^6]
- Training target: Show today’s training goal or envelope; tie into readiness and strain.[^6]


### 6.4 Power‑user widgets

Power‑user surfaces should be clearly identified and require intentional configuration.

Examples:

- Multi‑metric compact dashboard: Small multiple layout showing readiness, sleep, activity, HRV in a single medium/large widget.[^1]
- Raw‑data freshness monitor: Widget showing status of each data source (HealthKit, Health Connect, wearables, exports) with last updated times.[^20]
- Data‑source/sync freshness: Similar to above but focusing on connectivity and sync health.[^20]
- Personal baseline deviation widget: Highlights metrics currently outside personal baseline ranges (e.g., RHR higher than typical); requires strong disclaimers.[^20]
- Export status widget: Shows status of scheduled exports and last completed export; tap opens export management.[^20]
- Scheduled export health indicator: High‑level indicator of whether exports are healthy or failing.[^20]
- Personal API/automation health status: For power users using BADAN APIs; widget summarizing job errors and last execution.[^20]
- Training‑load envelope: Graph-like view within widget showing last week’s load vs target envelope.[^6]
- Sleep consistency chart: Sparkline showing bedtime/wake time variance.[^12]
- Correlation insight: Highlights one simple correlation (e.g., “Late bedtime correlates with higher morning RHR”); surfaces rarely; tap for explanation.[^34]
- Health‑data inbox/anomalies requiring review: Shows count of new anomalies and short labels; tap opens inbox.[^20]

These surfaces must be careful not to cross into pseudo‑diagnosis territory; they should focus on “patterns to review” rather than “issues to worry about.”

## 7. Apple Watch complication catalog

This section specifies complication behaviors more deeply.

For each complication, BADAN should define:

- Family: which ClockKit family (corner, circular, rectangular, modular small/large).[^12]
- Primary value: the main metric.[^12]
- Optional secondary value: smaller text or icon.[^12]
- Color treatment: mapping of BADAN states to colors within accessible palettes.[^34]
- Privacy behavior: how to mask or obfuscate sensitive information.[^10]
- Stale data behavior: how to signal when data is old.[^28][^20]
- Tap target/deep link: which BADAN screen opens.[^12]
- Auto‑update vs manual: whether it relies solely on timelines or offers manual refresh.[^28][^12]
- Fallbacks: behavior when permissions are missing or data is stale.[^29][^13]
- Casual vs power‑user variants.


### 7.1 Ready‑Today corner complication

- Family: Corner.[^12]
- Primary value: Icon indicating readiness band (e.g., dot or ring).[^12]
- Secondary value: Short word (“OK”, “Easy”, “Watchful”).[^12]
- Color: Neutral/soft colors; avoid aggressive red; map states to green/blue/amber pastel.[^34]
- Privacy: If lock-screen privacy is enabled or user chooses high privacy, show only generic icon without text.[^10]
- Stale data: Dim icon and add “!” overlay or small bullet to indicate stale; tap reveals “Last updated yesterday”.[^28][^20]
- Tap: Opens BADAN watch home focusing on readiness.[^12]
- Auto‑update: Uses timeline entries; updated after sleep; at most a few times per day.[^28]
- Fallbacks: If HealthKit permissions revoked, show “Data off” icon and encourage review in app.[^13]
- Casual vs power: Casual sees coarse; power can switch to numeric readiness via configuration.


### 7.2 Sleep rectangular complication

- Family: Rectangular.[^12]
- Primary value: Last night’s hours of sleep.[^12]
- Secondary value: Quality band (“Restorative”, “Short”, “Fragmented”).[^12]
- Color: Blues/purples; band indication via subtle accent, not strong red.[^34]
- Privacy: This is moderately sensitive; allow mask to show only quality without hours.[^10]
- Stale data: If last sleep older than 2 days, show “No recent sleep data”; do not reuse stale metrics.[^20]
- Tap: Opens sleep detail in BADAN watch app.[^12]
- Auto‑update: After new sleep session recorded; once daily.[^13]
- Fallbacks: No sleep data; show “Sleep not tracked” with suggestion to connect devices.[^20]
- Casual vs power: Casual sees simple; power variant can show debt indicator.


### 7.3 Activity circular complication

- Family: Circular.[^12]
- Primary value: Steps ring or progress vs move goal.[^12]
- Secondary value: None or small steps number.[^12]
- Color: Green accent for progress; accessible palette.[^34]
- Privacy: Low sensitivity; only hide if user chooses ultra‑private mode.[^10]
- Stale data: Show small clock icon overlay if not updated for several hours.[^28]
- Tap: Opens activity detail in watch app.[^12]
- Auto‑update: Frequent; timeline entries built from aggregated step counts.[^28][^13]
- Fallbacks: If step data missing, show “–” and label “No data”.[^20]
- Casual vs power: Power variant may show percent vs weekly average.


### 7.4 Health monitor corner complication

- Family: Corner.[^12]
- Primary value: Traffic‑light style icon (green, amber, soft red) representing anomaly level, with careful semantics.[^10]
- Secondary: Count of anomalies (optional for power users).[^20]
- Color: Pastel palette; avoid harsh red; consider shapes beyond color to encode severity.[^34]
- Privacy: Hide anomaly count in casual mode; just show neutral icon.[^10]
- Stale data: If anomalies not recomputed recently, show neutral icon and “Check data” on tap.[^20]
- Tap: Opens health inbox in watch app with clear disclaimers.[^34]
- Auto‑update: When anomalies recalculated.[^20]
- Fallbacks: If no data, show grey icon and message.


### 7.5 Hydration small modular complication

- Family: Modular small or circular.[^12]
- Primary value: Hydration progress bar or percent.[^12]
- Secondary: None.
- Color: Blues; avoid framing as weight‑loss tool.[^34]
- Privacy: Low sensitivity; safe default.[^10]
- Stale data: Show last logged time when tapped.[^20]
- Tap: Opens hydration logging; may also support quick log.[^2]

Analogous definitions can be created for HRV, training load, subjective mood, symptom counts, and export status, all following similar patterns of primary value, privacy, and stale-data handling.

## 8. Live Activities and Dynamic Island plan

### 8.1 Appropriate use cases

Based on ActivityKit guidance, Live Activities and Dynamic Island are best used for ongoing, time‑bounded activities where people benefit from continuous status at a glance.[^24][^8]

Recommended BADAN Live Activities:

- Live workout session: Track an ongoing workout’s duration, heart rate band, and effort; show minimal data on compact Dynamic Island and more on expanded view.[^24][^8]
- Medication window: For a time‑sensitive medication window, show countdown and simple “Taken / Skipped / Snoozed” status; avoid showing drug names in lock screen by default.[^8]
- Export job progress: Display long‑running export progress (e.g., preparing zip of health data) with percentage and estimated time.[^8]
- Acute symptom journal: For a user‑initiated acute symptom tracking session (e.g., cluster of events), show “recording window active” and simple count of entries; must be opt‑in.[^24]


### 8.2 State model

ActivityKit requires defining ActivityAttributes and content states; BADAN should design attributes including:

- For workouts: workout ID, primary metric (e.g., steps, effort), optional target; content state includes elapsed time, current intensity band, heart rate band, and confidence.[^24]
- For medication windows: schedule ID, generic label; content state includes remaining time, status.[^8]
- For exports: job ID; state includes percent complete, last updated.[^8]

Dynamic Island presentations:

- Compact state: Short label and icon, e.g., “BADAN workout 23 min, steady pace.”[^8]
- Expanded state: More metrics such as current HR band, steps, or simple ring.[^24]
- Minimal state: Icon only; ensures presence without detail.[^8]


### 8.3 Refresh and reliability

- Live Activities can be updated frequently from the app while active; they rely on ActivityKit updates and optionally APNs.[^24][^8]
- BADAN should avoid using Live Activities as continuous heart rate monitors; instead, focus on summarizing key status and avoid showing high‑frequency raw data.[^8]
- If HealthKit data becomes stale or permissions change mid‑activity, the Live Activity should show “Data paused; check BADAN” rather than continuing to display potentially wrong values.[^13][^20]


### 8.4 Ethical considerations

- For medication and symptom flows, avoid alarming language; show simple statuses and encourage the user to consult professionals within the app’s detailed views.[^34]
- Dynamic Island surfaces are highly visible; default to subtle color schemes and avoid flashing or urgent tones except for user‑explicit alarms.[^8]


## 9. App Intents, Shortcuts, Siri, and quick actions

### 9.1 App Intents roles

App Intents unify BADAN’s actions across widgets, Siri, Shortcuts, Spotlight, and Apple Intelligence.[^26][^25][^2]

Required intent families:

- Logging intents: `LogWaterIntent`, `LogMealIntent`, `LogMedicationIntent`, `LogSymptomIntent`, `LogMoodIntent`, `LogWorkoutIntent`, `LogPeriodEventIntent`, `LogPregnancySymptomIntent`.[^2]
- Query intents: `GetTodaySummaryIntent`, `GetReadinessIntent`, `GetSleepSummaryIntent`, `GetActivityStatusIntent`, `GetHealthMonitorStatusIntent`.[^2]
- Export intents: `StartExportIntent`, `CheckExportStatusIntent`.[^26]
- Automation intents: `StartWorkoutSessionIntent`, `StartHydrationRoutineIntent`, `RunDailyCheckInIntent`.[^25]

These intents allow:

- Widgets with AppIntentConfiguration to parametrize which metric or summary they show.[^23][^1]
- Shortcuts and Siri phrases like “Hey Siri, how is my recovery today with BADAN?” or “Log 500 ml water in BADAN.”[^26][^2]
- Apple Intelligence integration where BADAN can be invoked by natural language in system experiences.[^26]


### 9.2 Siri and Shortcuts integration

- Use App Intents to define actions and share semantics with Siri; adopt relevant schemas for health concepts.[^25][^26]
- Donate frequent actions (e.g., nightly sleep check, morning readiness check) so system can suggest them contextually.[^26]
- Provide privacy‑respecting responses: speak in generic wellness terms, avoid diagnostic language.[^26]


### 9.3 Android quick actions and app shortcuts

- Implement app shortcuts (static and dynamic) for common actions: log water, log symptom, check today summary.[^30]
- Integration with Assistant/App Actions can mirror App Intents by exposing intents via App Actions schema.[^30]


## 10. Data freshness, reliability, and privacy model

### 10.1 Precomputation vs on‑device computation

For each widget family:

- Precomputed server‑side or central on‑device: high‑level scores like readiness, stress, baselines, anomalies inbox; ensures consistent semantics.[^20]
- On‑device computation: simple aggregations like today’s steps, last sleep duration, hydration totals, using HealthKit/Health Connect locally.[^13][^20]
- Background refresh: triggered by HealthKit background delivery (iOS), WorkManager jobs (Android), and sync events from wearables; used to update precomputed scores.[^5][^13]

For example:

- Daily summary: precomputed once per morning; widgets read from cached store.[^20]
- Activity status: partially computed on device using local steps and exercise minutes; bad network cannot block this.[^3][^13]


### 10.2 Background refresh constraints

- iOS HealthKit: some data types (e.g., steps) limited to hourly updates; immediate frequency may be capped; background delivery opportunistic.[^18][^13][^20]
- WidgetKit timelines: minimum reload interval around 5 minutes; actual reload often delayed.[^22][^21][^15]
- watchOS: background updates for complications more reliable when complication present on watch face, but still limited.[^28]
- Android: `updatePeriodMillis` minimum 30 minutes; Doze and battery optimization can delay updates; WorkManager recommended for background work.[^3][^4]
- Wear OS tiles: dynamic expressions can stream platform data (e.g., heart rate) with per‑second updates, but total dynamic expression count per tile limited.[^32]


### 10.3 Freshness indicators and stale data handling

Widgets and complications should:

- Display “Last updated” timestamps or icons indicating freshness tier (e.g., <2 hours, same day, >1 day).[^20]
- Prefer omitting metrics entirely over showing extremely stale values without context.[^20]
- Use dimmed color or neutral icons when data is stale.[^28]

Scenarios:

- Permissions revoked: show “Data access disabled” message and invite re‑auth in BADAN app; do not reuse old data.[^13]
- External device sync stale: show “Device sync overdue” indicator; perhaps display last known data with clear message.[^20]
- Score still calibrating: say “Calibrating your baseline” instead of showing unstable score.[^20]
- Data absent: show neutral placeholders (“No sleep tracked recently”) and highlight configuration options.[^20]


### 10.4 Privacy modes

BADAN must offer per‑surface privacy configuration:

- Global modes: High privacy (show only generic statuses), normal, verbose.[^10]
- Screen‑context modes: Distinguish lock screen vs home screen vs watch face vs tiles; lock screens use highest privacy defaults.[^5][^10]
- Sensitive metrics: weight, reproductive health, mental health, diagnoses, lab values; default to “off” for ambient surfaces; user can enable in private contexts.[^10]


## 11. Customization and preset system

### 11.1 Customization dimensions

Users should configure widgets/complications across:

- Metric selection: choose which metric or score each slot shows.[^23]
- Score selection: pick among readiness, recovery, stress, sleep, training load.[^6]
- Display density: choose simple vs detailed layouts.[^7]
- Date range: choose day vs week; limited to coarse ranges to avoid noise.[^4]
- Source preference: prefer specific device sources where duplicates exist (e.g., Apple Watch vs another wearable).[^13]
- Unit preference: e.g., km vs miles, ml vs oz.[^7]
- Visual theme: light vs dark vs high‑contrast; accent choices within accessible palettes.[^34][^7]
- Color accessibility: options for color‑blind friendly palettes.[^34]
- Privacy mode: choose global and per‑widget privacy.[^10]
- Sensitive-data hiding: toggle for each sensitive metric.[^10]
- Locked-screen redaction: options to blur, generically label, or hide metrics on lock screen.[^10]
- User‑defined labels: allow renaming metrics (“Training load” vs “Workout strain”).[^4]
- Shortcut destination: configure actions for logging widgets and quick actions.[^2]


### 11.2 Presets

Provide curated presets to avoid customization chaos:

- Casual preset: One True Sentence + simple daily summary; minimal metrics; high privacy.[^4]
- Athlete preset: readiness, training load, activity, sleep consistency; more metrics; moderate privacy.[^6]
- Recovery preset: focus on HRV, sleep, low‑intensity activity; gentle messaging.[^34]
- Hydration preset: hydration metric, reminders, water logging shortcuts.[^5]
- Cycle/pregnancy preset: for users who explicitly opt‑in; surfaces in private widgets only.[^10]
- Quantified‑self preset: multi‑metric dashboards, baseline deviation widget, export status, API health.[^20]

Each preset defines default widgets, complications, metrics, and privacy modes; users can then tweak details without needing to design from scratch.

### 11.3 Avoiding customization chaos

Strategies:

- Opinionated defaults: Limit the number of metrics shown per widget; encourage high‑level views.[^7]
- Templates: Pre‑built widget templates (e.g., “Daily overview”, “Training board”) with limited configurable slots.[^23]
- Guardrails: Warn when a configuration combines too many dense metrics on small surfaces; suggest larger widgets instead.[^7]
- Hierarchical settings: Global settings (privacy, units) cascade to surfaces; per‑widget overrides allowed but clearly indicated.[^4]


## 12. iOS architecture plan

### 12.1 Shared domain model

Define a shared domain model for:

- Entities: Metric, Score, Source, Baseline, Anomaly, ExportJob, LoggingAction.[^20]
- Attributes: value, units, freshness, confidence, sensitivity category, source ID.[^20]
- Relationships: metrics belonging to scores (e.g., readiness uses HRV and sleep), anomalies linked to metrics.[^20]

This model should be implemented in a shared Swift module used by main app, widgets, and watch app via app groups where possible.[^1][^12]

### 12.2 Widget view models and snapshot generation

- Each widget type has a ViewModel that reads from the shared store and composes DisplayModels for metrics and text.[^1]
- Widget snapshot generation builds timeline entries by:
    - Fetching or computing necessary metrics.[^14]
    - Packaging them with timestamps and freshness indicators.[^15]
    - Selecting appropriate templates per widget family.[^1]


### 12.3 App group / shared store architecture

- Use App Groups to share a local database (e.g., SQLite or Core Data) storing the canonical BADAN domain model and precomputed scores.[^1]
- Widgets read from this store; the main app populates it based on HealthKit and external syncs.[^13][^20]


### 12.4 WidgetKit timeline generation

- Implement TimelineProvider per widget type, using AppIntentConfig where necessary.[^14][^1]
- Timelines should include entries spaced at least 30–60 minutes apart, plus entries for known events (e.g., post‑sleep).[^15]
- Use `.atEnd` reload policy with conservative expectations, acknowledging that actual reload may lag.[^21][^22][^15]


### 12.5 watchOS data sync

- Watch app and complications share data via HealthKit on watch and connectivity with phone app.[^12]
- Complication timelines built from watch‑local data; optionally enriched by phone data via background transfers.[^29]


### 12.6 Background refresh strategy

- iOS: Use HealthKit background delivery, background fetch, and push notifications to trigger updates to shared store and widget timelines.[^19][^13][^20]
- watchOS: Rely on complication presence for more frequent background updates; use scheduled refresh where possible.[^28]


### 12.7 Deep-link routing

- Centralize deep link definitions to map widget taps, Live Activity taps, and Siri/Shortcuts to specific BADAN screens.[^27]


### 12.8 App Intents wiring

- Define AppIntents module describing all actions and queries; ensure these are testable via App Intents Testing.[^35][^2]


### 12.9 Live Activity state model

- Implement ActivityAttributes and content states for workouts, medication windows, exports, and symptom sessions.[^24][^8]


### 12.10 Analytics and accessibility metadata

- Instrument interactions (e.g., widget taps, Live Activity usage) with privacy‑preserving analytics; never log raw health values.[^20]
- Define accessibility labels, traits, and hints for all surfaces and track usage to improve designs.[^34][^7]


### 12.11 Localization and RTL

- Build text content via localization tables; design layouts to support RTL languages (including Arabic) by mirroring layouts and ensuring inline widgets are phrased appropriately.[^7]


### 12.12 Android equivalent abstraction

- Implement analogous domain model and view models for Android; Kotlin module used by app, widgets, tiles, and complications data sources.[^3][^5][^10]


## 13. Android and Wear OS parity plan

### 13.1 Android widgets

- Mirror iOS daily summary, readiness, sleep, activity, hydration, and logging shortcuts widgets using Glance or RemoteViews.[^17][^3]
- Use WorkManager for periodic updates from Health Connect or external sources; store data in local database analogous to app group store on iOS.[^3][^4]


### 13.2 Wear OS tiles

- Implement tiles for daily summary, readiness, hydration, and workout start, following best practices: minimal content, quick actions, background work via WorkManager, dynamic expressions for heart rate and steps.[^31][^32][^5]


### 13.3 Wear OS complications

- Implement complication data sources for readiness, activity, health monitor; follow Watch Face Format data definitions for short text and ranged values.[^33][^11][^10]


### 13.4 Android shortcuts/App Actions

- Provide deep links and App Actions for logging and summary queries, mapping to Assistant phrases similar to Siri/app intents on iOS.[^30]


## 14. UX, accessibility, localization, and RTL plan

### 14.1 Calm vs alarming

- Use neutral, supportive language (“Consider resting more tonight”) rather than urgent or diagnostic language (“Your heart is at risk”).[^34]
- Reserve any alarming language for rare, explicit user‑opt‑in alerts, and always frame them as “patterns worth discussing with a professional” rather than definite diagnoses.[^34]


### 14.2 Avoid shame mechanics

- Avoid “fail” framing (e.g., “You failed your goals”); instead, use constructive phrasing (“Today was lighter than your typical activity; consider moving more tomorrow”).[^7]
- Do not show weight or body‑fat prominently, and do not label them as goals unless user explicitly configures that.[^10]


### 14.3 Explain low confidence or incomplete data

- Use confidence indicators and phrases (“We have limited data today; this summary may be less accurate”) when data coverage is low.[^20]
- Offer simple explanations via tap‑through screens rather than crowding widgets.[^34]


### 14.4 Protect private information on lock screens

- Default to generic statuses and icons on lock screens; hide sensitive categories by default.[^10]
- Allow quick privacy switching (e.g., via app settings or long press) to mask metrics quickly.[^10]


### 14.5 Accessibility and localization

- Ensure all widgets and complications have VoiceOver/TalkBack‑compatible labels and semantics.[^7][^34]
- Support Dynamic Type on iOS and equivalent font scaling on Android; ensure layouts degrade gracefully.[^7]
- Design with RTL in mind (layout mirroring, sentence order, numerals) to support Arabic and other languages.[^7]


## 15. Feature prioritization

Prioritization criteria:

- User impact: surfaces that help most users most often (daily summary, readiness, sleep, activity).[^4]
- Implementation complexity: surfaces that are straightforward with existing platform APIs (simple widgets and complications).[^3][^1][^12]
- Privacy sensitivity: lower sensitivity first; add sensitive surfaces only with robust privacy controls.[^10]
- Cross‑platform value: surfaces that can be mirrored across platforms.[^5][^3]

High‑priority v1 surfaces:

- One True Sentence daily summary (inline lock widget, Home widget, Android widget, tile headline).[^5][^1]
- Readiness/recovery metric widgets and complications.[^10][^12]
- Sleep summary widgets and complications.[^12]
- Activity overview widgets and tiles.[^3][^5]
- Hydration widgets and tiles with logging shortcuts.[^5]
- Logging shortcuts for water, meal, medication, symptom, mood, workout.[^2][^3]
- Health monitor status complication and widget.[^10][^12]
- Watch app glanceable overview.[^34]
- Android and Wear OS parity for at least daily summary and readiness.[^3][^5][^10]

Lower‑priority (v1.1+) surfaces:

- Advanced dashboards and multi‑metric power‑user widgets.[^1]
- Export status widgets.[^20]
- Correlation insights and baseline deviation widgets.[^20]
- Cycle/pregnancy‑specific widgets.[^10]


### 15.1 Master implementation table

| Widget / complication | User value | Data inputs | iOS feasibility | watchOS feasibility | Android equivalent | Refresh model | Privacy sensitivity | Complexity | Priority | BADAN recommendation |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| One True Sentence daily summary widget | Single calm sentence summarizing today | Aggregated scores (readiness, sleep, activity, stress)[^6][^20] | High[^1] | High (Smart Stack/ app)[^6] | High (widget/tile headline)[^3][^5] | Daily + occasional updates[^15][^13] | Medium (generic wording)[^10] | Medium (text \& logic) | High | Core v1 on all platforms |
| Readiness small Home Screen widget | Quick view of daily readiness band/score | Readiness score, sleep, strain[^6][^13] | High[^1] | Via complication[^12] | Small widget[^3] | Daily post-sleep[^13] | Medium[^10] | Low–medium | High | v1 for iOS \& Android |
| Sleep overview medium widget | Last night sleep duration \& quality | Sleep session, duration, efficiency[^13] | High[^1] | Rectangular complication[^12] | Medium widget[^3] | Daily after sleep[^13] | Medium[^10] | Medium | High | v1 with conservative messaging |
| Activity overview medium widget | Steps/move/exercise summary | Steps, energy, exercise minutes[^13][^3] | High[^1] | Activity complication[^12] | Medium widget[^3] | Multiple times/day, opportunistic[^13][^20] | Low[^4] | Medium | High | v1 across platforms |
| Hydration metric + logging widget | Hydration progress and one-tap logging | Intake logs, goal[^5] | High[^1] | Hydration complication[^12] | Widget + Wear tile[^5][^3] | Several times/day, on log events[^5] | Low[^10] | Medium | High | v1: focus on hydration preset |
| Health monitor corner complication | Traffic-light health status indicator | Anomalies from baselines[^20] | Medium (widget icon)[^1] | High (corner complication)[^12] | Wear complication[^10] | On anomaly recompute[^20] | High (aggregated anomalies)[^10] | Medium | High | v1 as primary watch complication |
| Watch app glance screen | Fast overview of today + key actions | Same scores \& metrics as summary[^34] | N/A | High[^34] | Wear OS app first screen[^5] | Real-time when app open[^34] | Medium[^10] | High (design) | High | v1 defining watch UX |
| Android daily summary small widget | At-a-glance today status on Android home | Same as One True Sentence[^3][^4] | N/A | N/A | High[^3] | 30–60 min + WorkManager[^3][^17] | Medium[^10] | Medium | High | v1 parity with iOS |
| Wear OS daily summary tile | Quick swipe card with summary \& key metric | Readiness, daily summary[^5] | N/A | N/A | High[^5] | Cached state + dynamic expressions[^32] | Medium[^10] | Medium | High | v1 parity with Apple Watch |
| Workout Live Activity + Dynamic Island | Ongoing workout status at a glance | Workout state, HR band, effort[^8][^24] | High[^8] | N/A | Wear tile/session UI[^5] | Frequent while active, ActivityKit updates[^8] | Medium–High[^10] | High | Medium–High | Phase 2 feature |
| Export status widget | Visibility into export jobs health | Export job metadata, last run[^20] | Medium[^1] | N/A | Medium widget[^3] | On export runs, daily check[^20] | Medium[^10] | Medium–High | Medium | Phase 2–3 for power users |

### 15.2 Backlog-ready table

| ID | Capability | Phase | Owner | Dependencies | Approval needed | Proposed files/modules | Acceptance criteria |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| W-01 | One True Sentence summary pipeline + widgets | Phase 1 | Product + iOS/Android | Shared domain model, HealthKit/Health Connect ingest[^13][^20] | Tone \& wording guidelines, privacy defaults[^10][^34] | `HealthSummaryDomain`, `SummaryEngine`, WidgetKit/Glance views | Sentence generated daily, matches data; widgets show correct state \& freshness |
| W-02 | Readiness score and small/medium widgets | Phase 1 | Product + iOS/Android | Score formula design, data aggregation[^6][^20] | Thresholds and labels for readiness bands[^6] | `ReadinessModel`, `ReadinessWidgetProvider`, Watch complications | Readiness score stable; widgets/complications render correctly across platforms |
| W-03 | Sleep overview widgets and complications | Phase 1 | iOS + watchOS + Android | Sleep ingest, debt computation[^13] | Messaging style for sleep quality[^34] | `SleepModel`, `SleepWidget`, `SleepComplicationDataSource` | Sleep sessions mapped; duration/quality accurate in widgets and complications |
| W-04 | Activity overview widgets and tiles | Phase 1 | iOS + Android + Wear | Steps/energy ingestion, goals configuration[^3][^13] | Goal defaults and ring semantics[^4] | `ActivityModel`, `ActivityWidget`, `ActivityTileService` | Activity metrics match platform health; rings and text update within expected cadence |
| W-05 | Hydration logging + metrics widgets | Phase 1 | Product + iOS + Android + Wear | Logging UX, intake model[^5] | Hydration goal defaults and preset strategy | `HydrationModel`, logging intents, widgets/tiles | Logging friction low; hydration progress accurate across surfaces |
| W-06 | Health monitor anomalies + corner complication | Phase 2 | Product + watchOS + Android/Wear | Baseline engine, anomaly detection[^20] | Policy on anomaly surfacing \& copy[^10][^34] | `HealthMonitorModel`, `HealthInbox`, complications/tiles | Anomaly counts \& bands correct; copy non‑alarming; privacy modes validated |
| W-07 | App Intents / App Actions for logging \& queries | Phase 1 | iOS + Android | Domain actions, entities schemas[^2][^25][^30] | Exposure of health actions to Siri/Assistant[^26][^30] | `BADANAppIntents`, Android `AppActions` config | Siri/Shortcuts/Assistant can invoke logging \& summary; tests pass with App Intents |
| W-08 | Watch app glance screen | Phase 1 | watchOS | Shared domain model on watch, layout design[^12][^34] | Which metrics appear by default on watch | `WatchAppHomeView`, `WatchDataStore` | First watch screen shows correct summary; performance within watchOS limits |
| W-09 | Android/Wear parity (summary + readiness) | Phase 1 | Android + Wear | Domain model Kotlin port, Health Connect integration[^3][^5] | Minimum parity scope vs iOS | `AndroidDomain`, widgets, tiles, complications | Core summary and readiness behave similarly on Android and iOS |
| W-10 | Live Activities for workouts, meds, exports | Phase 2 | iOS | ActivityKit integration, push updates[^8][^24] | Which flows get Live Activities; risk review[^10][^34] | `ActivityAttributes`, Live Activity views | Live Activities show correct states and stop gracefully; no alarming messaging |
| W-11 | Privacy modes \& sensitive data configuration | Phase 1–2 | Product + UX | Metrics sensitivity tagging, settings UX[^10] | Global privacy defaults; lock screen policy[^10] | `PrivacyConfigModel`, UI settings screens | Users can control visibility; lock screens never show disallowed data by default |
| W-12 | Export status widgets \& automation health surfaces | Phase 2–3 | Product + Backend | Export engine, API health monitoring[^20] | Exposure of export status in ambient UI | `ExportStatusModel`, widgets | Export jobs monitored; widgets accurately reflect status and freshness |

## 16. Recommended phased roadmap

### Phase 1 (MVP ambient layer)

- Implement shared domain model and app group/shared store on iOS; equivalent local store on Android.[^3][^1]
- Build One True Sentence summary pipeline and daily readiness/sleep/activity scores.[^6][^20]
- Ship iOS small/medium home widgets for daily summary, readiness, sleep, activity, hydration.[^15][^1]
- Ship lock inline and circular widgets with conservative content.[^15][^1]
- Implement core App Intents for logging and summary queries, plus iOS app quick actions.[^25][^2]
- Ship Apple Watch corner and circular complications for readiness and health monitor, plus watch app glance screen.[^34][^12]
- Ship Android small/medium widgets for summary/readiness/sleep/activity, with WorkManager‑driven refresh.[^3][^4]
- Ship Wear OS tile for daily summary/readiness and at least one complication.[^5][^10]


### Phase 2 (Power users and advanced surfaces)

- Add multi‑metric dashboards, export status widgets, data‑freshness widgets.[^20]
- Expand complication catalog (rectangular sleep, modular summaries).[^12]
- Introduce anomalies inbox widget and health monitor tile.[^5][^20]
- Ship Live Activities for workouts, medication windows, and exports.[^24][^8]
- Add Smart Stack widgets for BADAN daily summary and hydration on watchOS.[^6][^1]


### Phase 3 (Specialized flows and AI integration)

- Cycle/pregnancy presets and private widgets.[^10]
- Correlation insight widgets.[^20]
- Deeper integration with Apple Intelligence and Android Assistant via App Intents/App Actions, including natural language queries.[^26][^30]


## 17. Risks, limitations, and anti-patterns

Key risks:

- Over‑promising data freshness: HealthKit and platform limits mean widgets and complications cannot be real‑time.[^18][^15][^13]
- Shaming or alarming users: poorly worded widgets could damage trust or well‑being.[^34]
- Privacy leaks on lock screens and watch faces: sensitive data displayed publicly.[^10]
- Customization overload: too many options causing confusion and poor defaults.[^7]
- Cross‑platform inconsistency: divergent behavior across iOS/Android/Wear.[^3][^5]

Anti‑patterns to avoid:

- Detailed diagnostic language or medical advice in widgets and complications.[^34]
- Widgets that rely on minute‑level freshness for health metrics without acknowledging possible delays.[^15][^20]
- Lock screen widgets showing specific diagnoses, reproductive status, or lab numbers.[^10]
- Dynamic Island surfaces that feel alarmist or distractingly animated.[^8]


## 18. Implementation recommendations for BADAN

- Anchor all ambient surfaces in BADAN’s shared health domain model, ensuring consistent meanings and thresholds for metrics and scores.[^20]
- Focus v1 on a handful of high‑value, low‑sensitivity surfaces that communicate “today at a glance” for both casual and power users — especially One True Sentence, readiness, sleep, activity, hydration, health monitor, and logging shortcuts.[^5][^3][^1]
- Invest early in App Intents and Android App Actions so that BADAN’s health repository and actions are accessible from Siri, Shortcuts, widgets, tiles, and assistants without extra per‑surface wiring.[^25][^26][^30][^2]
- Treat privacy modes and data freshness indicators as first‑class UI elements in widgets and complications, not optional details.[^10][^20]
- Use platform best practices for background refresh (HealthKit background delivery, WorkManager) but design UI copy and indicators around the reality of opportunistic updates rather than deterministic schedules.[^5][^13][^20]
- Plan for strong localization and RTL support (particularly for Arabic), as BADAN’s audience and your own profile require culturally and linguistically appropriate phrasing on ambient surfaces.[^7]

***

## Completion note

**File path**

- Intended path for the research document:
`/Users/binjamshid/Desktop/Apps/badan/docs/BADAN_WIDGETS_COMPLICATIONS_RESEARCH.md`
Due to a workspace limitation in the current environment, the document wasn’t programmatically written to disk; please save the above content manually under this filename in your BADAN repository.[^1]

**Total widget/complication concepts researched**

- Approximately 55 distinct ambient surfaces and concepts were defined across:
    - iOS/iPadOS Home and Lock Screen widgets.
    - Apple Watch complications, Smart Stack cards, and glance screens.
    - Live Activities/Dynamic Island presentations.
    - Android App Widgets and shortcuts.
    - Wear OS tiles and complications.[^3][^5][^1][^10]

**Top 10 recommended v1 surfaces**

1. One True Sentence daily summary (inline lock widget + small/medium home widgets + Android widget + Wear tile headline).[^5][^1]
2. Readiness/recovery small and medium Home Screen widgets on iOS and Android.[^3][^1]
3. Sleep overview medium widget and Apple Watch rectangular complication.[^12]
4. Activity overview medium widget and Wear OS tile for steps/activity.[^3][^5]
5. Hydration metric + logging widget (iOS/Android) and hydration tile/complication (Wear/Watch).[^5][^12]
6. Health monitor corner complication plus small status widget.[^10][^12]
7. Apple Watch BADAN glance screen as the first watch app surface.[^34]
8. Core logging shortcuts: water, meal, medication, symptom, mood, workout (App Intents + Android shortcuts).[^2][^3]
9. Android small daily summary widget mirroring iOS One True Sentence surface.[^3][^4]
10. Wear OS daily summary/readiness tile.[^5]

**Top 5 platform limitations to design around**

1. HealthKit background delivery is opportunistic and often capped at hourly for some types (e.g., steps); no guaranteed real‑time updates.[^18][^13][^20]
2. WidgetKit enforces a minimum reload interval (~5 minutes) and may delay `.atEnd`/`.after(date:)` timeline reloads beyond the requested time.[^22][^21][^14][^15]
3. Android App Widgets have a minimum `updatePeriodMillis` of 30 minutes, and Doze/background restrictions further throttle refreshes.[^3][^4]
4. Wear OS tiles cannot scroll and limit the number of dynamic expressions per tile, constraining both layout and streaming metrics.[^32][^5]
5. Lock screens and watch faces are semi‑public surfaces; sensitive health data (weight, reproductive status, diagnoses, lab values) must not be displayed by default.[^10]

**Top 5 founder/product decisions requiring explicit approval**

1. **Privacy defaults and sensitive metric policy**: Which metrics (weight, cycle, pregnancy, lab values, mental health signals) are allowed on ambient surfaces, and under what explicit opt‑in conditions.[^10]
2. **Tone and scope of One True Sentence**: How far the daily summary can go in interpreting health patterns versus remaining purely descriptive and non‑diagnostic.[^6][^34]
3. **Readiness/recovery score semantics**: Final formula, thresholds, and band labels, including how strongly BADAN can suggest training/rest decisions.[^6][^20]
4. **Live Activities coverage**: Which flows (workouts, medication windows, symptom journaling, exports) warrant Live Activities/Dynamic Island presence, and what level of urgency is acceptable in those surfaces.[^24][^8][^10]
5. **Cross‑platform parity strategy**: The minimum level of feature parity between iOS/watchOS and Android/Wear, and whether some advanced power‑user surfaces (e.g., export/API health dashboards) launch on Apple platforms first or are held until both ecosystems can support them.[^5][^3][^10]
<span style="display:none">[^36][^37][^38][^39][^40][^41][^42][^43][^44][^45][^46][^47][^48][^49][^50][^51][^52][^53][^54][^55][^56][^57][^58][^59]</span>

<div align="center">⁂</div>

[^1]: https://developer.apple.com/documentation/widgetkit

[^2]: https://developer.apple.com/documentation/appintents

[^3]: https://developer.android.com/develop/ui/views/appwidgets

[^4]: https://developer.android.com/develop/ui/views/appwidgets/overview

[^5]: https://developer.android.com/training/wearables/tiles

[^6]: https://developer.apple.com/news/?id=6moiy7vu

[^7]: https://developer.android.com/design/ui/mobile/guides/widgets

[^8]: https://developer.apple.com/news/?id=bkm73839

[^9]: https://developer.apple.com/videos/play/wwdc2023/10184/

[^10]: https://developer.android.com/training/wearables/complications

[^11]: https://developer.android.com/training/wearables/wff/complications

[^12]: https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleWatch2TransitionGuide/DesigningaComplication.html

[^13]: https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:)

[^14]: https://developer.apple.com/documentation/widgetkit/timelineprovider

[^15]: https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date

[^16]: https://developer.apple.com/videos/play/wwdc2025/244/

[^17]: https://developer.android.com/develop/ui/compose/glance/create-app-widget

[^18]: https://www.reddit.com/r/SwiftUI/comments/1qkpjmi/some_questions_about_background_notifications_and/

[^19]: https://stackoverflow.com/questions/26375767/healthkit-background-delivery-when-app-is-not-running

[^20]: https://docs.spikeapi.com/sdk-docs/ios/background-delivery

[^21]: https://stackoverflow.com/questions/66504540/timeline-reload-policy-seems-to-be-ignored-in-widgetkit

[^22]: https://developer.apple.com/forums/thread/657518

[^23]: https://medium.com/axel-springer-tech/play-with-ios-widgets-17dba4e9634d

[^24]: https://mszpro.com/article/ios16-live-activities-dynamic-island

[^25]: https://developer.apple.com/documentation/appintents/making-actions-and-content-discoverable-by-apple-intelligence

[^26]: https://developer.apple.com/documentation/appintents/apple-intelligence-and-siri-ai

[^27]: https://developer.apple.com/documentation/intents/

[^28]: https://developer.apple.com/forums/thread/814914

[^29]: https://stackoverflow.com/questions/32958068/healthkit-enablebackgrounddeliveryfortype-is-unavailable-unable-to-calculate-he

[^30]: https://medium.com/google-developers/widgets-your-app-their-homescreen-9c552312ccae

[^31]: https://android-developers.googleblog.com/2021/03/creating-custom-tiles-on-wear-os-by-google-with-jetpack-tiles.html

[^32]: https://developer.android.com/training/wearables/tiles/dynamic

[^33]: https://developer.android.com/training/wearables/complications/exposing-data

[^34]: https://www.kodeco.com/32839701-watchos-complications

[^35]: https://developer.apple.com/documentation/AppIntentsTesting

[^36]: http://www.360doc.com/content/23/0215/16/8772388_1067786941.shtml

[^37]: https://medium.com/@MynaviTechTusVietnam/tạo-live-activities-và-dynamic-island-với-activitykit-trên-ios-16-dfc964559836

[^38]: https://medium.com/@bancarel.paul/leveraging-live-activities-on-ios-with-activitykit-6821918215f3

[^39]: https://developer.apple.com/cn/documentation/widgetkit/

[^40]: https://habr.com/ru/articles/709422/

[^41]: https://medium.com/better-programming/create-live-activities-with-activitykit-on-ios-16-beta-4766a347035b

[^42]: https://developer.apple.com/forums/tags/widgetkit

[^43]: https://blog.logrocket.com/exploring-ios-live-activities-api/

[^44]: https://github.com/1998code/iOS16-Live-Activities

[^45]: https://schibsted-vend.pl/blog/creating-real-time-news-experience-with-ios-live-activities/

[^46]: https://developer.apple.com/documentation/appintents/getting-started-with-the-app-intents-framework

[^47]: https://google-developer-training.github.io/android-developer-advanced-course-concepts/unit-1-expand-the-user-experience/lesson-2-app-widgets/2-1-c-app-widgets/2-1-c-app-widgets.html

[^48]: https://stuff.mit.edu/afs/sipb/project/android/docs/guide/practices/ui_guidelines/widget_design.html

[^49]: https://medium.com/@ios_guru/working-with-healthkit-background-delivery-828d5144c5a8

[^50]: https://developer.android.com/training/wearables/tiles/get_started

[^51]: https://developer.android.com/codelabs/wear-tiles

[^52]: https://developer.android.com/design/ui/wear/samples

[^53]: https://dev.to/myougatheaxo/wear-os-tiles-complete-guide-tile-apilayoutdata-update-4c6j

[^54]: https://developer.android.com/training/wearables/complications?hl=id

[^55]: https://github.com/android/wear-os-samples/tree/main/WearTilesKotlin

[^56]: https://developer.android.com/reference/androidx/wear/tiles/package-summary

[^57]: https://kingstinct-react-native-healthkit.mintlify.app/core-concepts/background-delivery

[^58]: https://medium.com/react-native-training/how-to-handle-background-app-refresh-with-healthkit-in-react-native-3a32704461fe

[^59]: https://developer.apple.com/forums/tags/healthkit?page=2\&sortBy=activity\&sortOrder=DESC

