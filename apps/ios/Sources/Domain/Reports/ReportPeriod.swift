import Foundation

/// Resolves a report period (an ISO week or a calendar month) into the concrete set of local day
/// keys it spans, plus its start/end instants — in one place so `ReportBuilder`, the trigger, and
/// the screen all agree on where a week begins and which days a month contains.
///
/// Weeks are ISO-8601 (Monday-first, the week containing Jan 4 is week 1), matching the
/// `week:2026-W29` form the schema and `reports.period_key` use. Months are calendar months
/// (`month:2026-07`). Boundaries are computed in a single `timezone` (the profile's zone at
/// generation): a report is a snapshot framed by the zone the user was in when it was built, and
/// `ReportModel.timezone` records which zone that was so a later re-resolution can reproduce it.
public enum ReportPeriod {
    public struct Resolved: Equatable, Sendable {
        public let periodKey: String
        public let kind: ReportPeriodKind
        /// "YYYY-MM-DD" day keys, ascending. 7 for a week; 28–31 for a month.
        public let dayKeys: [String]
        /// Start of the first local day (inclusive).
        public let start: Date
        /// Start of the local day AFTER the last day (exclusive) — the period is [start, end).
        public let end: Date
        public let timezone: String

        /// The `day:<key>` period keys the derived store uses, ascending.
        public var dayPeriodKeys: [String] { dayKeys.map { "day:" + $0 } }
    }

    // ISO-8601 semantics: Monday-first, ≥4 days in the first week. `DayAttribution.calendar`'s
    // gregorian calendar is Sunday-first, so week numbering needs its own calendar; day-key
    // formatting and startOfDay still delegate to `DayAttribution` for a single source of truth.
    private static let isoLock = NSLock()
    private static var isoCache: [String: Calendar] = [:]

    static func isoCalendar(tz: String) -> Calendar {
        isoLock.lock(); defer { isoLock.unlock() }
        if let cached = isoCache[tz] { return cached }
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: tz) ?? .current
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        isoCache[tz] = c
        return c
    }

    // MARK: - Week

    /// The ISO week containing `date`.
    public static func week(containing date: Date, tz: String) -> Resolved {
        let cal = isoCalendar(tz: tz)
        let weekOfYear = cal.component(.weekOfYear, from: date)
        let yearForWOY = cal.component(.yearForWeekOfYear, from: date)
        let periodKey = String(format: "week:%04d-W%02d", yearForWOY, weekOfYear)

        var comps = DateComponents()
        comps.weekOfYear = weekOfYear
        comps.yearForWeekOfYear = yearForWOY
        comps.weekday = cal.firstWeekday  // Monday
        // Fall back to the day itself if the components fail to resolve (should not happen for a
        // valid `date`), so the caller always gets a usable 7-day window rather than a crash.
        let monday = cal.date(from: comps) ?? DayAttribution.startOfDay(date, tz: tz)
        let start = DayAttribution.startOfDay(monday, tz: tz)
        let dayKeys = (0..<7).map { DayAttribution.localDayKey(DayAttribution.addingDays($0, to: start, tz: tz), tz: tz) }
        let end = DayAttribution.startOfDay(DayAttribution.addingDays(7, to: start, tz: tz), tz: tz)
        return Resolved(periodKey: periodKey, kind: .week, dayKeys: dayKeys, start: start, end: end, timezone: tz)
    }

    // MARK: - Month

    /// The calendar month containing `date`.
    public static func month(containing date: Date, tz: String) -> Resolved {
        let cal = DayAttribution.calendar(tz: tz)
        let year = cal.component(.year, from: date)
        let month = cal.component(.month, from: date)
        let periodKey = String(format: "month:%04d-%02d", year, month)

        var firstComps = DateComponents()
        firstComps.year = year; firstComps.month = month; firstComps.day = 1
        let first = cal.date(from: firstComps) ?? DayAttribution.startOfDay(date, tz: tz)
        let start = DayAttribution.startOfDay(first, tz: tz)
        let dayCount = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let dayKeys = (0..<dayCount).map { DayAttribution.localDayKey(DayAttribution.addingDays($0, to: start, tz: tz), tz: tz) }
        let end = DayAttribution.startOfDay(DayAttribution.addingDays(dayCount, to: start, tz: tz), tz: tz)
        return Resolved(periodKey: periodKey, kind: .month, dayKeys: dayKeys, start: start, end: end, timezone: tz)
    }

    // MARK: - Parse / navigate

    /// Reconstruct a period from its key (`week:YYYY-Www` | `month:YYYY-MM`). Returns nil for a
    /// malformed key rather than guessing.
    public static func resolve(periodKey: String, tz: String) -> Resolved? {
        if periodKey.hasPrefix("week:") {
            let body = String(periodKey.dropFirst("week:".count))
            let parts = body.split(separator: "-")
            guard parts.count == 2, parts[1].hasPrefix("W"),
                  let year = Int(parts[0]), let weekNumber = Int(parts[1].dropFirst()) else { return nil }
            let cal = isoCalendar(tz: tz)
            var comps = DateComponents()
            comps.yearForWeekOfYear = year; comps.weekOfYear = weekNumber; comps.weekday = cal.firstWeekday
            guard let anchor = cal.date(from: comps) else { return nil }
            let resolved = week(containing: anchor, tz: tz)
            // Reject a key that doesn't round-trip (e.g. week 54), matching `DayAttribution.date`.
            return resolved.periodKey == periodKey ? resolved : nil
        }
        if periodKey.hasPrefix("month:") {
            let body = String(periodKey.dropFirst("month:".count))
            let parts = body.split(separator: "-")
            guard parts.count == 2, let year = Int(parts[0]), let monthNumber = Int(parts[1]),
                  (1...12).contains(monthNumber) else { return nil }
            let cal = DayAttribution.calendar(tz: tz)
            var comps = DateComponents()
            comps.year = year; comps.month = monthNumber; comps.day = 1
            guard let anchor = cal.date(from: comps) else { return nil }
            let resolved = month(containing: anchor, tz: tz)
            return resolved.periodKey == periodKey ? resolved : nil
        }
        return nil
    }

    /// The period immediately before the given one (prior week / prior month), used to compute
    /// period-over-period deltas.
    public static func prior(_ resolved: Resolved, tz: String) -> Resolved {
        let dayBefore = DayAttribution.addingDays(-1, to: resolved.start, tz: tz)
        switch resolved.kind {
        case .week: return week(containing: dayBefore, tz: tz)
        case .month: return month(containing: dayBefore, tz: tz)
        }
    }
}
