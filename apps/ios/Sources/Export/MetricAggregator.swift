import Foundation

/// EPIC-13: rolls BADAN's canonical rows up into hourly/daily/weekly/monthly buckets for export
/// (plan §12 EPIC-13).
///
/// ## Why this does not call HealthKit's statistics APIs
///
/// The platform will happily hand back a daily step total, and it is tempting: one query, no
/// bucketing code, no timezone arithmetic. It is also the wrong number. HealthKit's collection
/// queries aggregate *HealthKit's* view of the store — every contributing sample from every app
/// and device, with Apple's own de-duplication rules. BADAN's export exists to publish **BADAN's
/// reconciled store**: rows that went through this app's ingestion, source-priority reconciliation
/// (I4) and dedup journal (I3), with the losers marked `suppressed_by` and excluded unless the
/// user asked for them. Those two totals differ whenever a phone and a watch both recorded a walk,
/// which is most days for most users.
///
/// Exporting the platform's number under BADAN's manifest — which states a `dedup_policy` and
/// per-metric row counts — would make the manifest a false description of the file. If someone
/// later "optimizes" this into a statistics query because it is faster, the export stops being an
/// export of BADAN and becomes an export of Apple Health that BADAN happened to write.
///
/// ## Why the GROUP BY is here and not in SQL
///
/// §12 EPIC-13 specifies "SQL `GROUP BY` aggregation over canonical tables", and the *selection*
/// half of that is exactly what happens: the caller pulls the in-scope rows out of
/// `raw_samples` / `interval_records` through the repositories, which is the query. The
/// **bucketing** cannot be a `GROUP BY strftime('%Y-%m-%d', start_at, ...)` because day boundaries
/// have to be computed in each row's own `tz_id` (below), and SQLite carries no timezone database:
/// `strftime` knows UTC and the device's current local time and nothing else. A `GROUP BY` in SQL
/// would silently bucket a trip to Dubai by the phone's timezone today, or by UTC, and would get
/// DST-transition days wrong by an hour at both ends of the year.
///
/// So this is a pure function over already-selected canonical rows. That also makes it testable
/// against a fixture without a database, which is what `packages/fixtures/aggregation/` is.
///
/// ## Day boundaries
///
/// Every row is assigned to the calendar unit that contains it **in the row's own `tz_id`**, not
/// in the device's current zone and not in UTC. A run at 23:30 in Dubai belongs to that Dubai day
/// even if the phone is now in New York, because that is the day the person lived. The
/// consequences are deliberate and fixture-tested:
///
/// - A spring-forward day is 23 hours long and a fall-back day is 25. Both are one bucket. The
///   bucket's `start`/`end` instants report the real length, so a consumer computing coverage
///   against 86,400 seconds gets a truthful answer rather than a hidden hour.
/// - When the user changes timezone mid-range, rows on both sides of the change that share a local
///   date land in the **same** bucket — one calendar day by local date. Its instant boundaries are
///   anchored in the earliest contributing row's zone (so the bucket is a normal-length day *in
///   that zone*, not the longer or shorter span the traveller actually lived), and
///   `contributingTimezones` lists every zone that fed it — so a mixed-zone day is visible in the
///   data rather than inferred from a gap in a chart.
enum AggregateGranularity: String, CaseIterable {
    case hour, day, week, month

    /// The CSV `granularity` stamp (column 25). Every produced record carries one — this is the
    /// half of the ambiguity gap that answers "what window does this number describe".
    var csvGranularity: ExportSchema.Granularity {
        switch self {
        case .hour: return .hour
        case .day: return .day
        case .week: return .week
        case .month: return .month
        }
    }
}

/// The concrete statistic a produced record carries.
///
/// Distinct from `ExportAggregationMethod`, which is what the *user asked for* on a template.
/// The two differ in exactly one place and that place is the point of this type: `minAvgMax` is a
/// request for three numbers, and a CSV row has one value column. Stamping three rows
/// `aggregation_method=min_avg_max` would leave them mutually indistinguishable — the precise
/// ambiguity EPIC-13 exists to close — so a `minAvgMax` request expands into three records
/// stamped `min`, `mean` and `max`.
///
/// Case order is the emission order for a metric's records and for the wide layout's columns:
/// min, mean, max reads as a range, which alphabetical order (max, mean, min) does not.
enum AggregateStat: String, CaseIterable {
    case min, mean, max, sum, duration, latest

    /// The CSV `aggregation_method` stamp (column 26).
    var csvMethod: ExportSchema.AggregationMethod {
        switch self {
        case .min: return .min
        case .mean: return .mean
        case .max: return .max
        case .sum: return .sum
        case .duration: return .duration
        case .latest: return .latest
        }
    }
}

/// One canonical row on its way into a bucket — the subset of `RawSample` / `IntervalRecord` the
/// aggregation actually reads.
///
/// A projection rather than the domain types themselves so that the fixture can express both
/// tables in one list and so a caller cannot accidentally feed in a row it has not decided is
/// in-scope (suppressed duplicates, soft-deleted rows and sensitive-namespace rows are all the
/// caller's filter to apply, upstream, where the scope lives).
struct AggregateInputRow {
    var metricId: String
    /// Canonical value and unit. Aggregation happens in canonical units only — mixing a
    /// display-profile value into a sum is a unit error that no column would reveal.
    var value: Double
    var unit: String
    var startAt: Date
    /// Present on intervals and sessions, `nil` on instant samples. Only `duration` reads it.
    var endAt: Date?
    /// IANA zone at measurement. The bucket boundary is computed in *this*, per row.
    var tzId: String
    /// `interval_records.aggregation` — how the stored row was itself already combined. `nil` for
    /// `raw_samples`, which are single readings. See `defaultStat` for how it is used.
    var storedAggregation: Aggregation?

    init(metricId: String, value: Double, unit: String, startAt: Date, endAt: Date? = nil,
         tzId: String, storedAggregation: Aggregation? = nil) {
        self.metricId = metricId; self.value = value; self.unit = unit
        self.startAt = startAt; self.endAt = endAt; self.tzId = tzId
        self.storedAggregation = storedAggregation
    }
}

/// One aggregated number, fully self-describing.
///
/// The stamps are the deliverable. HAE's exports leave a consumer to infer from a timestamp span
/// whether `8421` is a daily total, an hourly total or a single reading; every record here states
/// its granularity and its method, so the question is answered in the row rather than guessed from
/// the file.
struct AggregateRecord: Equatable {
    var metricId: String
    /// The local calendar key: `2026-03-08` (day), `2026-03-08T14` (hour), `2026-W11` (week),
    /// `2026-03` (month). Language- and locale-stable; this is the wide layout's `date` cell.
    var bucketKey: String
    /// First instant of the bucket, and the first instant of the *next* one (closed-open).
    /// Computed in `tzId`, so a DST day really is 23 or 25 hours wide here.
    var bucketStart: Date
    var bucketEnd: Date
    /// The zone the bucket's boundaries were computed in: the zone of the earliest contributing
    /// row. On an ordinary day this is the only zone involved.
    var tzId: String
    /// Every distinct zone that fed this bucket, sorted. More than one means the user crossed
    /// zones inside the local day — see the type doc for why that is one bucket and not two.
    var contributingTimezones: [String]
    var granularity: AggregateGranularity
    var stat: AggregateStat
    var value: Double
    var unit: String
    /// How many canonical rows went into this number. A daily mean over two readings and one over
    /// two hundred are both `mean`; without the count they read identically.
    var sampleCount: Int

    /// True when the local day was assembled from rows recorded in more than one zone.
    var spansMultipleTimezones: Bool { contributingTimezones.count > 1 }
}

/// Buckets canonical rows and computes the statistics. Stateless.
struct MetricAggregator {
    init() {}

    /// Aggregates `rows` into `granularity` buckets.
    ///
    /// `method` is what the user chose on the template. Pass `nil` to fall back per metric to
    /// `defaultStat` — the hint path. Output is sorted by (metric id, bucket key, stat order) so
    /// two runs over the same data produce the same file; nothing downstream re-sorts.
    func aggregate(rows: [AggregateInputRow],
                   granularity: AggregateGranularity,
                   method: ExportAggregationMethod?,
                   definitions: [String: MetricDefinition]) -> [AggregateRecord] {
        // Bucket first, statistics second. Grouping by (metric, local key) rather than by
        // (metric, key, tz) is the deliberate choice documented on `AggregateGranularity`: the
        // unit is the calendar day the person lived, not the calendar day of a particular zone.
        var buckets: [BucketKey: [AggregateInputRow]] = [:]
        var order: [BucketKey] = []
        for row in rows {
            let key = BucketKey(metricId: row.metricId,
                                bucket: Self.bucketKey(for: row.startAt, tzId: row.tzId,
                                                       granularity: granularity))
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(row)
        }

        var records: [AggregateRecord] = []
        for key in order.sorted(by: { ($0.metricId, $0.bucket) < ($1.metricId, $1.bucket) }) {
            guard let members = buckets[key], !members.isEmpty else { continue }
            let sorted = members.sorted { $0.startAt < $1.startAt }
            // Boundaries come from the earliest contributing row's zone. On a mixed-zone day some
            // zone has to define the interval, and "the one the day started in" is the only choice
            // that does not depend on the order rows came out of the database.
            let primaryTz = sorted[0].tzId
            let interval = Self.bucketInterval(key: key.bucket, tzId: primaryTz, granularity: granularity)
            let zones = Array(Set(sorted.map(\.tzId))).sorted()

            let stats = Self.stats(for: method, metricId: key.metricId,
                                   rows: sorted, definitions: definitions)
            for stat in AggregateStat.allCases where stats.contains(stat) {
                guard let value = Self.compute(stat, over: sorted) else { continue }
                records.append(AggregateRecord(
                    metricId: key.metricId, bucketKey: key.bucket,
                    bucketStart: interval.start, bucketEnd: interval.end,
                    tzId: primaryTz, contributingTimezones: zones,
                    granularity: granularity, stat: stat,
                    // `duration` is a count of seconds regardless of what the metric measures;
                    // any other unit label on it would be a lie about the number.
                    value: value, unit: stat == .duration ? "s" : sorted[0].unit,
                    sampleCount: sorted.count))
            }
        }
        return records
    }

    // MARK: - Which statistic

    /// Expands the user's chosen method, or falls back to the per-metric hint.
    private static func stats(for method: ExportAggregationMethod?, metricId: String,
                              rows: [AggregateInputRow],
                              definitions: [String: MetricDefinition]) -> Set<AggregateStat> {
        switch method {
        case .none: return [defaultStat(metricId: metricId, rows: rows, definitions: definitions)]
        case .some(.minAvgMax): return [.min, .mean, .max]
        case .some(.sum): return [.sum]
        case .some(.mean): return [.mean]
        case .some(.min): return [.min]
        case .some(.max): return [.max]
        case .some(.duration): return [.duration]
        case .some(.latest): return [.latest]
        }
    }

    /// The default statistic for a metric when the caller did not choose one.
    ///
    /// **The registry does not carry an aggregation field.** `packages/metric-ontology/registry.json`
    /// at v0.2.0 has `kind`, `canonicalUnit`, units and labels — no `aggregation` / `aggregationHint`
    /// key. So this hint is *derived*, not read, and the derivation is stated here rather than
    /// implied by whichever call site happened to need it first. When the registry does gain the
    /// field, this function becomes a lookup with this rule as its seed data; nothing else has to
    /// change.
    ///
    /// The derivation, in priority order:
    ///
    /// 1. **The rows' own `interval_records.aggregation`**, when every contributing interval row
    ///    agrees. This is real recorded data rather than a guess: a row that says it is a `sum`
    ///    over its window re-aggregates as a `sum` over the day. Rows that disagree fall through —
    ///    combining a `sum` row and a `max` row under either label would be wrong under both.
    /// 2. **Cumulative unit + `intervalAggregate` kind → `sum`.** Steps, distance, energy, sleep
    ///    seconds, grams of protein: quantities that accumulate over a window.
    /// 3. **Everything else → `mean`.** Levels and rates do not add up. `respiratory.rate` is an
    ///    `intervalAggregate` in breaths per minute and `body.wrist_temp_deviation` an
    ///    `intervalAggregate` in degrees — summing either produces a number with no meaning, which
    ///    is why the rule keys on the unit and not on `kind` alone.
    ///
    /// This is only ever a default. A template that names a method overrides it, and the produced
    /// record states which statistic it actually is, so a wrong default is visible in the file
    /// rather than silently baked into the number.
    static func defaultStat(metricId: String, rows: [AggregateInputRow],
                            definitions: [String: MetricDefinition]) -> AggregateStat {
        let stored = Set(rows.compactMap(\.storedAggregation))
        if stored.count == 1, let only = stored.first, let mapped = map(only) { return mapped }

        guard let definition = definitions[metricId] else { return .mean }
        if definition.kind == .intervalAggregate, cumulativeUnits.contains(definition.canonicalUnit) {
            return .sum
        }
        return .mean
    }

    /// Canonical units whose values accumulate. Listed explicitly rather than inferred from a
    /// dimension analysis: the set is small, closed by the registry, and a wrong entry here turns
    /// a daily average heart rate into a meaningless total.
    ///
    /// Anything rate- or level-shaped is deliberately absent: `bpm`, `mmHg`, `percent`, `m/s`,
    /// `breaths/min`, `degC`, `kg`.
    private static let cumulativeUnits: Set<String> = ["count", "m", "km", "kJ", "kcal", "s", "min", "h",
                                                       "g", "mg", "L", "mL"]

    /// `Aggregation` (what a stored interval row already is) into `AggregateStat` (what a produced
    /// record is). `duration` and `latest` map straight through; there is no case that does not.
    private static func map(_ aggregation: Aggregation) -> AggregateStat? {
        switch aggregation {
        case .sum: return .sum
        case .mean: return .mean
        case .min: return .min
        case .max: return .max
        case .duration: return .duration
        case .latest: return .latest
        }
    }

    // MARK: - The statistics

    /// Computes one statistic over a bucket's rows. `nil` when the statistic is not defined for
    /// this data — currently only `duration` over rows with no `endAt`, where emitting `0` would
    /// claim the activity took no time.
    private static func compute(_ stat: AggregateStat, over rows: [AggregateInputRow]) -> Double? {
        switch stat {
        case .sum: return rows.reduce(0) { $0 + $1.value }
        case .mean: return rows.reduce(0) { $0 + $1.value } / Double(rows.count)
        case .min: return rows.map(\.value).min()
        case .max: return rows.map(\.value).max()
        case .latest: return rows.last?.value
        case .duration:
            let spans = rows.compactMap { row in row.endAt.map { $0.timeIntervalSince(row.startAt) } }
            return spans.isEmpty ? nil : spans.reduce(0, +)
        }
    }

    // MARK: - Bucketing

    private struct BucketKey: Hashable {
        let metricId: String
        let bucket: String
    }

    /// The local calendar key for an instant in a zone.
    ///
    /// Week keys are ISO-8601 (`2026-W11`, Monday-start, week 1 contains the first Thursday) and
    /// are computed arithmetically from the local date rather than through `Calendar`'s
    /// week-of-year components. That is not distrust of Foundation — it is that Android's half of
    /// this has to produce the same string, and "both platforms' calendar libraries agree on ISO
    /// week numbering at every year boundary" is an assumption with no cheap way to hold it true.
    /// The Thursday rule is four lines and provably identical.
    static func bucketKey(for instant: Date, tzId: String, granularity: AggregateGranularity) -> String {
        let zone = TimeZone(identifier: tzId) ?? TimeZone(identifier: "UTC")!
        let local = CivilTime.from(epochSeconds: epochSeconds(instant) + Int64(zone.secondsFromGMT(for: instant)))
        switch granularity {
        case .hour:
            return "\(pad(local.year, 4))-\(pad(local.month, 2))-\(pad(local.day, 2))T\(pad(local.hour, 2))"
        case .day:
            return "\(pad(local.year, 4))-\(pad(local.month, 2))-\(pad(local.day, 2))"
        case .month:
            return "\(pad(local.year, 4))-\(pad(local.month, 2))"
        case .week:
            // The ISO week-year is the year of that week's Thursday, and the week number is the
            // Thursday's ordinal position in it. Both fall out of one date shift.
            let days = CivilTime.days(year: local.year, month: local.month, day: local.day)
            let thursday = CivilTime.civil(fromDays: days - Int64(isoWeekdayIndex(days)) + 3)
            let weekOfYear = (thursday.dayOfYear - 1) / 7 + 1
            return "\(pad(thursday.year, 4))-W\(pad(weekOfYear, 2))"
        }
    }

    /// The bucket's half-open instant interval, in `tzId`.
    ///
    /// Derived from the *key* rather than from the instant that produced it, so every row in a
    /// bucket yields the same boundaries. Deriving from the instant would make a fall-back day's
    /// start depend on which side of the transition the first row happened to sit on.
    static func bucketInterval(key: String, tzId: String,
                               granularity: AggregateGranularity) -> (start: Date, end: Date) {
        let zone = TimeZone(identifier: tzId) ?? TimeZone(identifier: "UTC")!
        let start = parseKey(key, granularity: granularity)
        let end = advance(start, by: granularity)
        return (instant(localSeconds: CivilTime.epochSeconds(start), zone: zone),
                instant(localSeconds: CivilTime.epochSeconds(end), zone: zone))
    }

    /// Local civil fields back out of a bucket key.
    private static func parseKey(_ key: String, granularity: AggregateGranularity) -> CivilTime {
        func number(_ substring: Substring) -> Int64 { Int64(substring) ?? 0 }
        switch granularity {
        case .hour:
            let parts = key.split(separator: "T")
            let date = parts[0].split(separator: "-")
            return CivilTime(year: number(date[0]), month: number(date[1]), day: number(date[2]),
                             hour: number(parts[1]), minute: 0, second: 0)
        case .day:
            let date = key.split(separator: "-")
            return CivilTime(year: number(date[0]), month: number(date[1]), day: number(date[2]),
                             hour: 0, minute: 0, second: 0)
        case .month:
            let date = key.split(separator: "-")
            return CivilTime(year: number(date[0]), month: number(date[1]), day: 1,
                             hour: 0, minute: 0, second: 0)
        case .week:
            // Invert the Thursday rule: week N's Monday is Jan 4's week's Monday plus
            // (N-1) weeks, and Jan 4 is in week 1 by definition.
            let parts = key.split(separator: "W")
            let year = number(parts[0].dropLast())   // trailing '-'
            let week = number(parts[1])
            let jan4 = CivilTime.days(year: year, month: 1, day: 4)
            let firstMonday = jan4 - Int64(isoWeekdayIndex(jan4))
            return CivilTime.civil(fromDays: firstMonday + (week - 1) * 7)
        }
    }

    private static func advance(_ time: CivilTime, by granularity: AggregateGranularity) -> CivilTime {
        switch granularity {
        case .hour:
            return CivilTime.from(epochSeconds: CivilTime.epochSeconds(time) + 3_600)
        case .day:
            return CivilTime.civil(fromDays: CivilTime.days(year: time.year, month: time.month, day: time.day) + 1)
        case .week:
            return CivilTime.civil(fromDays: CivilTime.days(year: time.year, month: time.month, day: time.day) + 7)
        case .month:
            let rolled = time.month == 12
            return CivilTime(year: rolled ? time.year + 1 : time.year,
                             month: rolled ? 1 : time.month + 1, day: 1, hour: 0, minute: 0, second: 0)
        }
    }

    /// 0 for Monday … 6 for Sunday. 1970-01-01 was a Thursday, so day 0 is index 3.
    private static func isoWeekdayIndex(_ days: Int64) -> Int {
        Int(((days + 3) % 7 + 7) % 7)
    }

    /// The instant whose local representation in `zone` is `localSeconds`.
    ///
    /// The inverse of "instant + offset = local" needs the offset, and the offset depends on the
    /// instant — so it is solved by iteration, not algebra. Two candidates cover every case the
    /// IANA database produces:
    ///
    /// - **Ordinary time**: the first candidate already lands on a matching local time.
    /// - **Overlap** (fall-back; a local time that happens twice): the first candidate is the
    ///   *earlier* of the two, which is what `java.time`'s `ZonedDateTime.of` also picks. Both
    ///   platforms therefore choose the same instant for `01:00` on a fall-back day without either
    ///   one encoding a policy.
    /// - **Gap** (spring-forward; a local time that never happens, and a real case for a midnight
    ///   day boundary in `America/Santiago` and `Australia/Lord_Howe`): neither candidate matches,
    ///   and the first one is the local time shifted forward by the gap — again what `java.time`
    ///   returns.
    ///
    /// Only `secondsFromGMT(for:)` is taken from the platform, and that reads the same IANA
    /// database on both.
    private static func instant(localSeconds: Int64, zone: TimeZone) -> Date {
        func date(_ seconds: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
        func matches(_ candidate: Int64) -> Bool {
            candidate + Int64(zone.secondsFromGMT(for: date(candidate))) == localSeconds
        }
        let first = localSeconds - Int64(zone.secondsFromGMT(for: date(localSeconds)))
        if matches(first) { return date(first) }
        let second = localSeconds - Int64(zone.secondsFromGMT(for: date(first)))
        return date(matches(second) ? second : first)
    }

    private static func epochSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        var text = String(value)
        while text.count < width { text = "0" + text }
        return text
    }
}

/// Proleptic-Gregorian civil time and the two conversions between it and a second count.
///
/// Hand-rolled rather than taken from `Calendar` / `java.time` because this arithmetic has to be
/// **bit-identical on both platforms**, and it is the half of timezone handling that needs no
/// timezone database: shifting an instant by an offset and reading off the calendar fields is pure
/// integer arithmetic. Everything that genuinely requires the IANA database — what the offset *is*
/// at a given instant — still goes through the platform. `MetricAggregator` and `GPXWriter` both
/// use this, which is also why it is not private to either.
///
/// The date conversions are Howard Hinnant's `days_from_civil` / `civil_from_days`, valid for any
/// year the type can hold and correct across the proleptic Gregorian range — not the
/// "divide by 365.25" approximation that drifts a day around March in leap years.
struct CivilTime: Equatable {
    var year: Int64
    var month: Int64
    var day: Int64
    var hour: Int64
    var minute: Int64
    var second: Int64

    /// 1-based ordinal day within `year`.
    var dayOfYear: Int64 {
        CivilTime.days(year: year, month: month, day: day) - CivilTime.days(year: year, month: 1, day: 1) + 1
    }

    static func from(epochSeconds: Int64) -> CivilTime {
        var secondsOfDay = epochSeconds % 86_400
        if secondsOfDay < 0 { secondsOfDay += 86_400 }
        var time = civil(fromDays: (epochSeconds - secondsOfDay) / 86_400)
        time.hour = secondsOfDay / 3_600
        time.minute = (secondsOfDay % 3_600) / 60
        time.second = secondsOfDay % 60
        return time
    }

    static func epochSeconds(_ time: CivilTime) -> Int64 {
        days(year: time.year, month: time.month, day: time.day) * 86_400
            + time.hour * 3_600 + time.minute * 60 + time.second
    }

    /// Days since 1970-01-01 for a proleptic-Gregorian date.
    static func days(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The inverse of `days(year:month:day:)`. Time fields come back zeroed.
    static func civil(fromDays days: Int64) -> CivilTime {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return CivilTime(year: month <= 2 ? year + 1 : year, month: month, day: day,
                         hour: 0, minute: 0, second: 0)
    }
}
