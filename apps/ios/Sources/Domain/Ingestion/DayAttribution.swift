import Foundation

/// Timezone-aware day and "local night" attribution. Days are computed in the timezone at
/// measurement (never the device's current tz), so a night recorded in Riyadh stays a Riyadh
/// night even if you fly to London — and DST 23/25-hour days resolve correctly via Calendar.
enum DayAttribution {
    static func calendar(tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz) ?? .current
        return c
    }

    /// "YYYY-MM-DD" for the calendar day containing `date` in `tz`.
    static func localDayKey(_ date: Date, tz: String) -> String {
        let c = calendar(tz: tz).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A sleep session is attributed to the morning it ends (the "last night" label).
    static func localNight(sessionEnd: Date, tz: String) -> String {
        localDayKey(sessionEnd, tz: tz)
    }

    /// Period key used by derived values / baselines for a daily metric.
    static func dayPeriodKey(_ date: Date, tz: String) -> String {
        "day:" + localDayKey(date, tz: tz)
    }

    static func startOfDay(_ date: Date, tz: String) -> Date {
        calendar(tz: tz).startOfDay(for: date)
    }

    static func addingDays(_ days: Int, to date: Date, tz: String) -> Date {
        calendar(tz: tz).date(byAdding: .day, value: days, to: date) ?? date
    }

    /// Parse a "YYYY-MM-DD" day key back to that day's start instant in `tz`.
    static func date(fromDayKey key: String, tz: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return calendar(tz: tz).date(from: comps)
    }
}
