import Foundation

/// Which derived score `GetLatestScoreIntent` returns.
///
/// A closed set, not a free metric id, because an intent that returned "the latest value of any
/// metric" would be a raw-data read path competing with the export intent, and because these two
/// are the only *scores* (0–100 composites) the app derives today. New composites (Readiness v2,
/// EPIC-25) extend this enum; a raw vital does not belong here.
enum IntentScoreKind: String, CaseIterable {
    case readiness
    case sleepEfficiency

    var metricId: String {
        switch self {
        case .readiness: return "readiness.score"
        case .sleepEfficiency: return MetricID.sleepEfficiency
        }
    }

    var label: LocalizedString {
        switch self {
        case .readiness: return IntentStrings.scoreReadiness
        case .sleepEfficiency: return IntentStrings.scoreSleepEfficiency
        }
    }
}

/// EPIC-19 — reads the latest derived score for `GetLatestScoreIntent` to hand to a user's
/// automation.
///
/// **This service fabricates nothing.** The task's rule is that scores are honestly empty until
/// Phase 2 fills them in, so this reads only what `BaselineEngine` has already appended to
/// `derived_values` and returns `nil` when there is none. A user without enough history to have a
/// readiness score gets "no value yet", never a placeholder number an automation would act on.
///
/// Reads through `DerivationRepository` — the same append-only store every score UI reads, so the
/// intent, the Home hero and the metric detail screen can never disagree about "today's number".
@MainActor
struct IntentScoreService {
    let env: AppEnvironment

    /// One score reading: the value, the day it is for, and whether the baseline behind it is
    /// still provisional (which changes what the number *means*, so the intent says a different
    /// sentence — see `IntentStrings.scoreAnswerProvisional`).
    struct ScoreReading {
        let value: Double
        let day: Date
        let provisional: Bool
    }

    /// The most recent derived value for `kind`, or `nil` if none exists yet.
    ///
    /// "Most recent" is by period key (the day the score is *for*), not by `computed_at` (when it
    /// was calculated): a backfill run today can append a value for last Tuesday, and an
    /// automation asking "what's my readiness" means the latest day scored, not the latest write.
    func latest(_ kind: IntentScoreKind) -> ScoreReading? {
        guard let series = try? env.derivation.latestDerivedSeries(metricId: kind.metricId),
              !series.isEmpty else { return nil }
        // `latestDerivedSeries` returns one row per period, ordered by period_key ascending, so
        // the last element is the newest day.
        guard let newest = series.last,
              let day = Self.day(fromPeriodKey: newest.periodKey) else { return nil }
        return ScoreReading(value: newest.value, day: day, provisional: newest.provisional)
    }

    /// Parse a `day:YYYY-MM-DD` period key back to a `Date` at local midnight. Composites are
    /// always day-keyed (see `BaselineEngine.makeDerived`); a non-day key (a future weekly or
    /// per-session composite) has no single calendar day and returns `nil` rather than a guess.
    private static func day(fromPeriodKey key: String) -> Date? {
        guard key.hasPrefix("day:") else { return nil }
        let dayKey = String(key.dropFirst("day:".count))
        return DayAttribution.date(fromDayKey: dayKey, tz: TimeZone.current.identifier)
    }
}
