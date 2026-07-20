# BADAN Research: Implementing Health Auto Export–Class Export and Automation

## 1. Executive answer

Health Auto Export (HAE) is a mature, third-party iOS app that turns Apple HealthKit into a queryable, exportable, and automatable data source by combining four building blocks: (1) a wide HealthKit read surface (100+ metrics, 70+ workout types), (2) three export encodings — JSON, CSV, and GPX for routes, (3) a scheduling layer that is *not* true cron but a composite of in-app "Automations," iOS Shortcuts personal automations, and best-effort background delivery, and (4) a fan-out of destinations — iCloud Drive, Dropbox, Google Drive, REST APIs, MQTT, Home Assistant, Calendar, and a local TCP/MCP server. None of this requires an account or backend; everything is on-device and user-owned, which is central to its privacy pitch.[^1][^2][^3][^4][^5]

BADAN can reproduce essentially all of this with standard HealthKit, BackgroundTasks, and Shortcuts APIs, but three things are "deceptively hard" and must be designed for up front rather than bolted on: (a) HealthKit's per-type heterogeneous sample shapes (sleep, blood pressure, ECG, workouts, routes all have different native representations) demand a genuinely well-designed canonical schema, not ad hoc field mapping; (b) iOS gives no real "run at 8am daily" guarantee — HAE itself relies on Shortcuts + user-unlock windows to fake cron semantics; and (c) HKObserverQuery/background delivery is throttled, coalesced, and can silently stop firing after repeated failures, so any "automatic background export" promise needs honest reliability messaging and a checkpoint/replay design. BADAN's opportunity is to match HAE's export breadth while improving schema stability, provenance/metadata design, failure transparency, and a smoother on-device+optional-cloud hybrid — turning "exportability" into a trust feature rather than a hidden power setting.[^2][^4][^6][^7][^8][^9][^10]

## 2. Research method and scope

This study is based on HAE's official App Store listing, its public GitHub documentation repository (Lybron/health-auto-export), its help-center documentation (JSON export format specs, automations, TCP/MCP server docs), its 2022 "v6.0" REST/MQTT/Home Assistant feature announcement, community discussion (Reddit r/healthautoexport, Home Assistant community forum), and Apple's own HealthKit/BackgroundTasks developer documentation and developer-forum threads describing real-world background delivery behavior and limitations. Where HAE's own marketing claims (e.g., "automatic background sync") conflict with Apple's documented platform constraints, this report treats the platform constraints as authoritative and flags the gap explicitly.[^3][^4][^11][^12][^13][^14][^6][^7][^8][^15][^9][^10][^5][^1][^2]

## 3. Health Auto Export feature inventory

HAE's feature set clusters into eight functional groups, summarized below with tier availability (Free / Basic one-time purchase / Premium subscription):[^1][^3]

| Capability | Tier | Notes |
|---|---|---|
| Home/Lock Screen widgets (Activity, Statistics, Recent) | Free | Up to 6 metrics on largest widget [^3] |
| Quick Export (multi-metric CSV/JSON) | Basic | Manual, on-demand [^1][^16] |
| Per-metric detailed export (sleep phases, ECG, AFib, glucose metadata) | Basic | Greater granularity than Quick Export [^1] |
| Aggregation control (second → year) | Basic | User selects bucket granularity [^1][^3] |
| Workout export with routes, HR, HR recovery | Basic | GPX for routes [^1][^3] |
| Shortcuts automation | Basic/Premium | Simple vs. scheduled workflows [^1][^2] |
| Background/automatic sync | Premium | Best-effort, not exact-time [^1][^4] |
| iCloud Drive automated backup + encryption | Premium | [^1][^3][^12] |
| Dropbox / Google Drive export | Premium | [^1][^3] |
| REST API export (custom endpoints) | Premium | Multiple configs supported [^3][^11] |
| MQTT broker export | Premium | Added v6.0, 2022 [^11][^14] |
| Home Assistant entity export | Premium | Added v6.0 [^11][^13] |
| Calendar event logging | Premium | [^1] |
| Built-in TCP/MCP server (local network query) | Premium | Foreground-only, unencrypted [^5] |
| Auto Sync to Mac/iPad | Premium | Health data unavailable natively on Mac [^1][^3] |
| Activity Logs for automations | Premium | Tracks runs/errors [^3][^11] |
| Open-source web dashboard (GitHub) | Free (self-hosted) | Cross-platform viewing [^1] |

HAE covers Health Metrics (steps, HR, sleep phases, blood pressure, SpO2, respiratory rate, body temperature, etc.), Workouts + Routes, State of Mind, Menstrual Cycle, ECG, Heart Rate Notifications/AFib, and Medications, spanning over 100 metrics and 70+ workout types.[^3][^1]

## 4. iOS / HealthKit capability map

Each HAE capability maps to a specific Apple framework or API, most of which have hard constraints:

- **HealthKit read access**: `HKHealthStore`, `HKSampleQuery`/`HKStatisticsCollectionQuery` for bucketed aggregation, `HKAnchoredObjectQuery` for incremental/delta fetches, and `HKWorkoutRoute` for GPS routes.[^17][^18]
- **Background wake-up**: `HKObserverQuery` + `enableBackgroundDelivery(for:frequency:)`, gated by the `com.apple.developer.healthkit.background-delivery` entitlement. This is fundamentally a "wake me when something changed" mechanism, not a scheduler — frequency options are `.immediate`, `.hourly`, `.daily`, `.weekly`, and even `.immediate` is throttled by the OS depending on battery, complications, and device state (observed real-world coalescing to ~once/hour or worse).[^19][^8][^20][^10]
- **Data access while locked**: The HealthKit store is encrypted at rest and inaccessible while the device is locked; queries issued during a locked-screen background wake return empty results until unlock.[^9][^21]
- **Reliability failure mode**: If an app fails to respond to background delivery callbacks (i.e., doesn't call the completion handler promptly) three times, HealthKit permanently stops sending background updates for that registration until re-enabled.[^10]
- **True scheduling**: iOS has no app-level cron. `BGTaskScheduler` (BGAppRefreshTask / BGProcessingTask) offers opportunistic, system-throttled scheduling with no fixed-time guarantee. HAE's actual answer to "8am every day" is the Shortcuts app's Personal Automation "Time of Day" trigger firing a "Run Automation" action that HAE exposes — and this only works reliably if the phone is unlocked at that moment, otherwise the shortcut errors out.[^4][^6][^22][^2]
- **File/cloud destinations**: iCloud Drive via `FileManager`/`NSFileCoordinator` document storage, Dropbox/Google Drive via their respective OAuth SDKs, REST/MQTT/Home Assistant via `URLSession`/socket libraries, Calendar via `EventKit`, local network server via `Network.framework` TCP sockets plus MCP protocol handling, requiring the Local Network permission and (per HAE's own docs) currently shipped unencrypted.[^5]
- **Workout routes**: `HKWorkoutRoute` + `CLLocation` samples, exported as GPX (an XML-based GPS interchange format), requiring `HKWorkoutRouteQuery`.[^3]
- **Widgets**: WidgetKit extensions with HealthKit entitlement sharing via App Groups.

## 5. Export format architecture

HAE's JSON schema (documented publicly) reveals a deliberate design pattern BADAN should study closely:[^15]

- **Top-level shape**: an array called `metrics`, each element a metric object with `name` (snake_case), `units` (string, e.g., "count", "bpm", "mg/dL"), and `data` (array of per-sample or per-bucket dictionaries).[^15]
- **Naming convention**: strict snake_case transformation of the human label ("Blood Pressure" → `blood_pressure`), giving a stable, machine-parseable key space.[^15]
- **Heterogeneous per-type payloads**: rather than forcing every metric into one rigid `{qty, date}` shape, HAE defines type-specific extensions — blood pressure carries `systolic`/`diastolic`; heart rate carries `Min`/`Avg`/`Max` (bucketed) instead of `qty`; sleep analysis has two entirely different shapes depending on whether aggregation is on (day-level summary with `totalSleep`, `core`, `deep`, `rem`, `sleepStart/End`, `inBed*`) or off (per-segment `startDate`/`endDate`/`value` enum of sleep stage). Blood glucose adds `mealTime` enum; insulin delivery adds a `reason` enum (`Bolus`/`Basal`); sexual activity and handwashing/toothbrushing use categorical count fields.[^15]
- **Dates**: ISO-like but non-ISO-8601 strict format `yyyy-MM-dd HH:mm:ss Z` with explicit UTC-offset suffix rather than `Z` — this bakes in local-time offset per sample, which is important for timezone-correct bucketing but is *not* a standard machine-parseable format in every language without a custom parser.[^15]
- **CSV**: one file per metric or per export bundle, essentially a flattened version of the same JSON records — practical for spreadsheet use but forces a choice between wide (one column per stat, e.g., separate `min/avg/max` columns) and long/tidy (one row per sample) layouts, and HAE appears to favor a wide, human-scannable table per metric.
- **GPX**: standard GPS Exchange XML for workout routes — track points with lat/long/elevation/time, directly importable into mapping tools (Strava, QGIS, Google Earth).[^3]
- **Bundling**: Quick Export produces multi-metric single-file JSON/CSV bundles; per-metric detailed exports produce separate files; automated backups zip/organize by date into iCloud Drive folders.[^1][^3]

**Implication for BADAN**: a single flat schema across all metric types is insufficient — HealthKit data is inherently polymorphic (quantity samples, category samples, correlation samples like blood pressure, clinical/ECG samples, workout samples with route/HR-recovery metadata). BADAN needs a *tagged union* schema: a common envelope (`name`, `units`, `source`, `device`, `data`) plus a per-type payload contract that is versioned so downstream consumers (scripts, AI tools, dashboards) don't break silently when Apple or BADAN adds new fields.

## 6. Automation and scheduling architecture

HAE's automation stack is genuinely a three-tier hybrid, not a single scheduler, and BADAN should adopt the same layered honesty rather than promise "cron":

**Tier 1 — In-app Automations (opportunistic background).** The user defines an automation (metrics, destination, format, aggregation) that HAE attempts to run "occasionally" in the background using observer queries and background delivery entitlements, with no fixed-time guarantee. This is the "set and mostly forget" tier, best suited to near-real-time integrations like Home Assistant/MQTT feeds where slight delay is fine.[^11][^1][^3]

**Tier 2 — Shortcuts-driven "fake cron."** Because iOS forbids apps from waking at an exact wall-clock time, HAE exposes a "Run Automation" Shortcuts action; the user builds a Shortcuts Personal Automation with a Time of Day trigger that calls this action. Apple's own restriction is explicit: the device must be unlocked at trigger time to access HealthKit data, or the shortcut fails outright; HAE's own docs recommend the "Run After Confirmation" option and choosing a time when the phone is normally unlocked (e.g., right after waking). Users can stack multiple Time-of-Day automations (e.g., 8:00 and 20:00) to simulate a fixed twice-daily schedule. Community discussion confirms HAE itself cannot schedule a fixed time natively — Shortcuts is the only path, and it inherits Shortcuts' own memory/execution-time limits.[^6][^2][^4]

**Tier 3 — Manual/on-demand.** Quick Export and per-metric export are always available as an escape hatch when automation silently fails, which is critical for user trust.

**Reliability engineering underneath all tiers:**
- **Checkpointing**: HAE-style automation should track a per-automation "last successful export" anchor (using `HKAnchoredObjectQuery`'s anchor token) so re-runs are incremental, not full re-scans, and idempotent on retry.[^18]
- **Change-based triggers**: Observer queries fire on "something changed," not "what changed" — the app must always re-query to know what's new, which is exactly the anchored-query pattern Apple recommends over trusting observer payloads alone.[^17][^9]
- **Failure budget**: Apple silently disables background delivery after 3 missed completion-handler calls, so BADAN's automation engine must be defensive about completion handling and proactively re-enable delivery, and must surface this failure state to the user rather than fail invisibly.[^10]
- **Activity Logs**: HAE keeps a visible log of automation runs and errors per automation — BADAN should adopt this as a mandatory trust surface, not an optional debug screen.[^11][^3]
- **iCloud backup of automation config**: HAE backs up automation *settings* (not just data) to iCloud so users don't lose configured pipelines on reinstall/device change.[^12]
- **Charging/mirroring tip**: HAE's own docs note that keeping the device charging and using iPhone Mirroring reduces OS throttling of background work and keeps the device "unlocked-equivalent" for automation purposes — a real, if awkward, workaround worth documenting for BADAN power users.[^5]

**How "cron-like" can BADAN realistically get on iOS?** Not very, natively. The honest architecture is: opportunistic background sync for "eventually consistent" destinations (MQTT/Home Assistant/REST feeds where minor delay is acceptable), Shortcuts-based time-of-day triggers for anything the user wants at a predictable time (which requires unlock and cannot be perfectly silent), and a server-assisted push model as the one true way to get real fixed-schedule automation — if BADAN has an optional companion backend, it can pull data whenever the app last synced and perform true cron-based downstream processing (digest emails, scheduled backups) *server-side*, decoupling reliability from iOS's background limits entirely.

## 7. Destination and integration architecture

| Destination | Protocol/SDK | Best-fit use case | On-device or hybrid |
|---|---|---|---|
| iCloud Drive | FileManager + iCloud container | Passive personal backup | On-device only |
| Dropbox / Google Drive | OAuth + provider SDK | Cross-device file access | On-device w/ 3rd-party auth |
| REST API | URLSession POST/PUT, JSON body | Custom personal database, AI/analytics pipelines | Hybrid — user's own backend |
| MQTT broker | MQTT client library | Home automation event stream | Hybrid — local/self-hosted broker |
| Home Assistant | HA REST/webhook or native entities | Smart-home dashboards | Hybrid |
| Calendar (EventKit) | EventKit | Lightweight event logging (e.g., workouts as calendar entries) | On-device only |
| TCP/MCP local server | Network.framework sockets, MCP protocol | LLM/agent tool access to live health data on LAN | On-device, foreground-only, unencrypted today [^5] |
| Mac/iPad Auto Sync | Custom sync protocol, since HealthKit isn't native on Mac | Desktop dashboards | On-device peer sync |

The MCP server detail is particularly relevant to BADAN's AI-research audience: HAE explicitly supports the Model Context Protocol so LLM agents/tools on the same network can query live health data, but the current implementation is foreground-only and unencrypted, explicitly restricted to trusted networks. This is a meaningful gap BADAN can improve on (see Section 12).[^5]

## 8. Feature-by-feature implementation analysis

**Quick Export (multi-metric JSON/CSV)**
- What it does: bundles multiple selected metrics into one file on demand.[^16][^1]
- Why valued: fastest path to a usable backup or LLM-ready dataset.
- HealthKit need: `HKSampleQuery`/`HKStatisticsCollectionQuery` across selected types, batched.
- Other frameworks: `Foundation` file I/O, `UniformTypeIdentifiers` for share sheet.
- Background feasible: no, this is a foreground/manual action.
- Local-only vs cloud: local-only.
- Data modeling implication: needs the tagged-union schema from Section 5.
- UX implication: metric multi-select with search/filter, remembered presets.
- Privacy implication: minimal risk since it's user-initiated and stays on-device unless shared.
- Reliability challenge: large date ranges can be slow/memory-heavy; needs streaming/chunked writes.
- BADAN recommendation: **Match**, then **Improve** with saved export presets and background chunked processing for huge ranges.

**Per-metric detailed export (sleep phases, ECG waveform, AFib, glucose metadata)**
- What it does: exposes granular, type-specific fields beyond the common schema.[^1][^15]
- Why valued: clinical-grade detail for power users/researchers.
- HealthKit need: `HKElectrocardiogram` + voltage sample queries for ECG, `HKCategorySample` for sleep, `HKCorrelation`/metadata dictionaries for glucose meal-time context.
- Background feasible: partially, for the underlying sync; export generation is foreground.
- Local-only vs cloud: local-only (ECG/AFib is highly sensitive clinical data — should default to strictly local export, opt-in only for any network destination).
- Data modeling implication: exactly why a common schema alone fails; per-type payload extension is mandatory.
- UX implication: needs progressive disclosure — casual users shouldn't see raw ECG voltage arrays by default.
- Privacy implication: highest sensitivity category; needs explicit extra consent screens.
- Reliability challenge: ECG waveform arrays are large; export size management needed.
- BADAN recommendation: **Match**, **Improve** with explicit sensitivity tiering and stricter default consent gating for clinical types.

**Aggregation control (seconds → years)**
- What it does: lets users choose bucket granularity for time-series metrics.[^1][^3]
- HealthKit need: `HKStatisticsCollectionQuery` with `NSDateComponents` interval, or raw `HKSampleQuery` for per-sample.
- Background feasible: yes for scheduled jobs, compute cost scales with range.
- Data modeling implication: same metric name must be able to emit both raw and bucketed shapes; the schema should carry an explicit `granularity` field so downstream consumers know what they're looking at (HAE's JSON does not always make this explicit, which is a real gap).
- BADAN recommendation: **Improve** — add an explicit `granularity` and `aggregation_method` field (sum/avg/min/max) to every emitted record, closing an ambiguity gap in HAE's current JSON docs.[^15]

**Workout + route export (GPX)**
- What it does: exports workouts with calories, cadence, HR, HR recovery, distance, and GPS route as GPX.[^3]
- HealthKit need: `HKWorkout`, `HKWorkoutRoute`, `HKWorkoutRouteQuery`, `HKSeriesSample` for HR-during-workout streams.
- Other frameworks: CoreLocation for route point metadata, MapKit optionally for in-app preview.
- Background feasible: yes for the sync; GPX generation is lightweight.
- Data modeling implication: workouts should be modeled as a parent object referencing (a) summary metrics, (b) a time-series of HR samples, (c) an optional route sub-resource — not flattened into the generic metrics array.
- Privacy implication: GPS routes are highly sensitive (reveal home/work location); route export should have its own separate consent toggle, distinct from general workout metrics.
- BADAN recommendation: **Match**, **Improve** by decoupling "export workout summary" from "export route" as separate opt-ins.

**Scheduled/background Automations**
- Already covered in depth in Section 6. BADAN recommendation: **Match** the layered opportunistic + Shortcuts model, but **Improve** transparency by clearly labeling in the UI which tier of reliability each automation is using ("Best-effort background," "Requires unlock via Shortcuts," "Manual only").

**Destinations: iCloud/Dropbox/Google Drive/REST/MQTT/Home Assistant/Calendar/TCP-MCP**
- Covered in Section 7. BADAN recommendation: **Match** REST API and iCloud (near-universal utility); **Extend** MQTT/Home Assistant only if BADAN's audience includes smart-home users (likely a secondary audience per Abdulrahman's profile, given AI/dev focus over home automation); **Improve** the MCP server by adding TLS and background-safe operation instead of foreground-only, unencrypted LAN sockets.[^5]

**Widgets**
- What it does: Home/Lock Screen glanceable stats, free tier.[^3]
- HealthKit need: WidgetKit + App Group shared HealthKit cache.
- BADAN recommendation: **Match**, low effort relative to trust value (widgets build daily brand presence).

**Activity Logs**
- What it does: per-automation run history and error surfacing.[^11][^3]
- BADAN recommendation: **Match and elevate** — make this a first-class "Export & Automation Health" dashboard rather than a buried log, since transparency about *whether automation actually worked* is the single biggest determinant of user trust in this category.

**Auto Sync to Mac/iPad**
- What it does: works around HealthKit's absence on macOS by peer-syncing from iPhone.[^1][^3]
- BADAN recommendation: **Skip initially** unless BADAN ships a desktop companion; **Extend later** by making the "desktop view" a thin client of BADAN's own export files/API rather than a proprietary sync protocol.

## 9. Recommended BADAN export data model

BADAN should adopt a versioned, envelope-plus-payload JSON schema:

```
{
  "export_schema_version": "1.0",
  "generated_at": "2026-07-20T18:42:00+04:00",
  "source_app": "BADAN",
  "device": { "model": "iPhone", "os_version": "iOS 18.5" },
  "range": { "start": "...", "end": "..." },
  "metrics": [
    {
      "name": "heart_rate",
      "canonical_key": "heart_rate",
      "units": "bpm",
      "granularity": "hourly",
      "aggregation_method": "min_avg_max",
      "provenance": { "source_bundle_id": "com.apple.health", "device_name": "Apple Watch" },
      "data": [ { "date": "2026-07-20T08:00:00+04:00", "min": 58, "avg": 64, "max": 79 } ]
    }
  ],
  "workouts": [ { "id": "...", "type": "Running", "summary": {...}, "hr_series_ref": "...", "route_ref": "route_0012.gpx" } ]
}
```

Key improvements over HAE's current design: (1) an explicit `export_schema_version` for forward compatibility, addressed head-on since HAE's own JSON docs show ad hoc, per-type evolution without versioning; (2) ISO 8601 timezone-aware timestamps by default, since HAE's non-standard `yyyy-MM-dd HH:mm:ss Z` format requires custom parsing in most languages; (3) explicit `granularity`/`aggregation_method` fields on every bucketed record, removing ambiguity present in HAE's docs; (4) explicit `provenance` (source app/device) per record, since HealthKit already carries this metadata natively and dropping it loses valuable signal for multi-device users (Watch + iPhone + third-party apps); (5) workouts as first-class parent objects with references to route/HR sub-resources rather than flattened arrays.[^15]

For CSV, BADAN should emit one file per metric using a tidy/long layout (`date, value_type, value, unit, granularity, source`) rather than wide ad hoc columns, to keep spreadsheet pivoting and downstream scripting predictable, while offering an optional "wide" export mode for users who specifically want single-row-per-day dashboards.

## 10. Recommended BADAN product UX for exports

Exportability should be surfaced as a primary tab, not buried in settings — mirroring HAE's positioning of "Take Ownership of Your Health Data" as its top-line value proposition. Recommended surface:[^3]

- **Quick Export card**: one-tap common presets (Last 7 days, Last 30 days, All-time), format toggle (JSON/CSV), instant share sheet.
- **Advanced builder**: metric picker with search, category grouping (Vitals, Activity, Sleep, Reproductive, Cardiac, Mind), date range picker, granularity slider.
- **Automation setup wizard**: explicitly labels reliability tier (Section 6) and requires the user to acknowledge unlock requirements for time-based Shortcuts triggers, avoiding the "silently didn't run" complaints seen in HAE's Reddit community.[^6]
- **Export & Automation Health dashboard**: last successful run per automation, next expected opportunistic window, error detail, one-tap "run now" fallback.
- **File naming/folder convention**: predictable `BADAN_{metric-or-bundle}_{YYYYMMDD}-{YYYYMMDD}.{ext}` pattern with a stable folder hierarchy (`BADAN/Exports/{year}/{month}/`), improving on HAE's less-documented naming for scripting reliability.
- **Permission explainers**: contextual, per-category consent screens (explain *why* route data, ECG, or cycle data specifically needs extra trust), rather than one blanket HealthKit prompt.

## 11. What BADAN should match

- Full JSON + CSV + GPX export trio.
- Aggregation from per-sample to yearly buckets.
- Workout and route export with HR/cadence/calorie metadata.
- REST API and iCloud Drive as baseline destinations.
- Shortcuts integration for time-based automation triggers.
- Visible Activity/Automation logs as a trust surface.
- Widgets for glanceable daily engagement.
- No-account, on-device-first privacy posture as the default.

## 12. What BADAN should improve

- **Schema versioning and stability** — explicit `export_schema_version`, documented changelog, and backward-compatible field additions, addressing a real gap in HAE's current ad hoc JSON evolution.[^15]
- **Standardized ISO 8601 timestamps** instead of HAE's non-standard date string format.[^15]
- **Explicit granularity/aggregation metadata** on every bucketed record, removing ambiguity.
- **Sensitivity-tiered consent** for clinical data (ECG, AFib, glucose, cycle tracking, mental health/state-of-mind) with separate opt-ins rather than one blanket permission model.
- **Route export as an independent consent toggle**, separate from workout summary export, given the location-privacy sensitivity of GPS traces.
- **Encrypted, background-tolerant local network/MCP-style server** instead of HAE's current foreground-only, unencrypted TCP server  — critical if BADAN wants to support AI-agent tooling access safely.[^5]
- **Reliability transparency UI**: label each automation's real-world reliability tier instead of implying seamless background magic, addressing the confusion visible in HAE's own community support threads about missed scheduled runs.[^6]
- **Server-assisted true scheduling** as an optional layer: if BADAN offers a companion backend, users who want guaranteed fixed-time digests/exports can opt into cloud-side scheduling fed by periodic device sync, sidestepping iOS's inherent background limits entirely.

## 13. What BADAN should delay or skip

- **Mac/iPad Auto Sync as a bespoke peer-sync protocol** — skip initially; if BADAN builds a desktop companion, base it on BADAN's own export/API format rather than a proprietary sync layer.
- **MQTT/Home Assistant destinations** — worthwhile long-term but not first-priority given BADAN's likely core audience (health-data owners, developers, AI researchers) versus HAE's overlapping smart-home hobbyist niche; treat as a Phase 2 integration once REST API and file destinations are solid.
- **Menstrual/cycle and sexual activity category-specific export formats** — technically straightforward to add later, but should be sequenced behind core vitals/workouts/sleep given engineering bandwidth, while still respecting that these are sensitive categories worth extra design care whenever built.
- **Multiple simultaneous REST/MQTT/H

---

## References

1. [Health Auto Export - JSON+CSV - App Store - Apple](https://apps.apple.com/ge/app/health-auto-export-json-csv/id1115567069) - Automate exports as JSON, CSV & GPX; Export 150+ health and fitness metrics from iPhone in CSV, JSON...

2. [Shortcuts ile bir otomasyonu zamanlama - Help Center - HealthyApps](https://help.healthyapps.dev/tr/health-auto-export/automations/schedule-automations-using-shortcuts/) - Health Auto Export otomasyonunu programa göre çalıştırmak için Shortcuts uygulamasını günün saati te...

3. [Lybron/health-auto-export](https://github.com/Lybron/health-auto-export) - This repository provides documentation for the API Export feature of Health Auto Export. - Lybron/he...

4. [Schedule An Automation Using Shortcuts - Help Center](https://help.healthyapps.dev/en/health-auto-export/automations/schedule-automations-using-shortcuts/) - Use the Shortcuts app with a time-of-day trigger to run a Health Auto Export automation on a schedul...

5. [Connect to Server - Help Center - HealthyApps](https://help.healthyapps.dev/en/health-auto-export/automations/server-connection) - The TCP/MCP Server allows you to query your health data directly from other devices over your local ...

6. [Set specific time for automation to run](https://www.reddit.com/r/healthautoexport/comments/16thddy/set_specific_time_for_automation_to_run/) - Set specific time for automation to run

7. [HKObserverQuery BackgroundDelivery not executed](https://developer.apple.com/forums/thread/690974?page=2)

8. [Abnormal Background Delivery Frequ…](https://developer.apple.com/forums/thread/814914)

9. [How to use HealthKit background delivery?](https://stackoverflow.com/questions/25088956/how-to-use-healthkit-background-delivery) - What is the correct way to use background delivery in iOS 8 HealthKit? The following is my code to e...

10. [enableBackgroundDelivery(for:frequency:withCompletion:)](https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:)) - If your app fails to respond three times, HealthKit assumes your app can't receive data and stops se...

11. [Export Apple Health Data to REST APIs, MQTT Brokers and Home ...](https://www.healthyapps.dev/blog/export-apple-health-data-to-rest-apis-mqtt-brokers-and-home-assistant) - Manage HealthKit data with HealthWatch | Automatically Export Apple Health Data as JSON or CSV to RE...

12. [Automations - Help Center - HealthyApps](https://help.healthyapps.dev/en/health-auto-export/automations) - Health Auto Export can back up your automation settings to iCloud Drive so you can restore them on a...

13. [Applehealth Autoexport - Third party integrations](https://community.home-assistant.io/t/applehealth-autoexport/419983) - Export Apple Health Data to Dropbox, REST API, MQTT Brokers and Home Assistant. This isn't free alth...

14. [Export Apple Health Data to REST APIs, MQTT Brokers, and Home Assistant](https://www.reddit.com/r/healthautoexport/comments/rboz80/export_apple_health_data_to_rest_apis_mqtt/) - Export Apple Health Data to REST APIs, MQTT Brokers, and Home Assistant

15. [Health Metrics - JSON Export Format - Help Center - HealthyApps](https://help.healthyapps.dev/en/health-auto-export/export-format/health-metrics/) - Documentation for health metrics structure in JSON exports

16. [How to Export Apple Health Data as a CSV or JSON [Bulk ...](https://www.youtube.com/watch?v=lms3fQyUuD0) - Use Health Auto Export's Quick Export to quickly export multiple Apple Health metrics into a single ...

17. [HKObserverQuery in Background mode](https://stackoverflow.com/questions/44555628/hkobserverquery-in-background-mode/44572197) - I have an application that need to track user heart rate readings from apple watch, so I did all the...

18. [Reading data from HealthKit | Apple Developer Documentation](https://developer.apple.com/documentation/healthkit/reading-data-from-healthkit) - Use queries to request sample data from HealthKit.

19. [com.apple.developer.healthkit.background-delivery](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.healthkit.background-delivery) - If this key is true , your app can enable background delivery of HKObserverQuery instances by callin...

20. [Some questions about background notifications and HealthKit](https://www.reddit.com/r/SwiftUI/comments/1qkpjmi/some_questions_about_background_notifications_and/) - Some questions about background notifications and HealthKit

21. [About HealthKit background delivery](https://developer.apple.com/forums/thread/13077)

22. [HealthKit Background Sync: How Clo… | Apple Developer Forums](https://developer.apple.com/forums/thread/825304)

