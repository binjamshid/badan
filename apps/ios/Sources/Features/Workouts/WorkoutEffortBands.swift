import Foundation

/// Time-in-band for a workout's heart-rate trace (EPIC-03 task 5, "zone-time bars if the data
/// supports it").
///
/// **Why these are "effort bands" and not training zones.** Every conventional zone model
/// (%HRmax, %HRR, lactate zones) needs a maximum heart rate, and the only way to get one without
/// a lab test is the age formula — `220 − age`, whose published standard error is roughly ±10–12
/// bpm. Feeding a birth year through it would produce five confident-looking boundaries built on
/// a number that could be wrong by two whole bands, and then label the result "your zones". Plan
/// §4.9 ("no false precision", "directional bands over decimal-precision absolutes") rules that
/// out, and the wellness-safe register rules out the prescription that usually follows it.
///
/// So the bands here are computed from two things BADAN actually observed: the person's own
/// resting heart rate baseline, and the highest rate recorded **in this session**. They describe
/// the shape of one workout — how much of it sat near the top of its own range — and the UI says
/// exactly that. They are deliberately not comparable between sessions as an absolute, and
/// nothing derives a score from them.
///
/// Pure and dependency-free so the arithmetic is unit-testable without a store or a view.
enum WorkoutEffortBands {

    /// The four bands, low to high. Names are descriptive of pace, never of merit — no "poor" or
    /// "optimal" band exists, and none is presented as a target.
    enum Band: String, CaseIterable, Identifiable, Sendable {
        case easy, steady, brisk, peak

        var id: String { rawValue }

        var label: LocalizedString {
            switch self {
            case .easy: return LocalizedString(en: "Easy", ar: "هادئ")
            case .steady: return LocalizedString(en: "Steady", ar: "ثابت")
            case .brisk: return LocalizedString(en: "Brisk", ar: "نشِط")
            case .peak: return LocalizedString(en: "Peak", ar: "الأعلى")
            }
        }

        /// Upper bound as a fraction of this session's own observed range above resting.
        /// Quarters — an even split, chosen precisely because it makes no physiological claim
        /// that unequal boundaries would smuggle in.
        var upperFraction: Double {
            switch self {
            case .easy: return 0.25
            case .steady: return 0.50
            case .brisk: return 0.75
            case .peak: return 1.0
            }
        }
    }

    struct BandTime: Identifiable, Sendable, Equatable {
        let band: Band
        let seconds: Double
        var id: String { band.rawValue }
    }

    struct Result: Sendable, Equatable {
        let bands: [BandTime]
        /// The resting rate the bands were measured up from.
        let restingBpm: Double
        /// The highest rate in this session — the top of the band range.
        let peakBpm: Double

        var totalSeconds: Double { bands.reduce(0) { $0 + $1.seconds } }

        func fraction(of band: Band) -> Double {
            let total = totalSeconds
            guard total > 0 else { return 0 }
            return (bands.first { $0.band == band }?.seconds ?? 0) / total
        }
    }

    /// A gap longer than this between consecutive samples is treated as a gap in recording
    /// rather than as time spent at the earlier reading.
    ///
    /// A watch samples heart rate every few seconds during a workout, so 90s is far outside
    /// normal spacing and only trips on a real interruption (wrist lifted, sensor lost contact,
    /// a paused session). Without the clamp, a five-minute sensor dropout would be silently
    /// credited to whatever band the last good reading happened to fall in — inventing five
    /// minutes of effort out of five minutes of no data.
    static let maxSampleGapSeconds: Double = 90

    /// The minimum spread between resting and peak for banding to mean anything.
    ///
    /// Below this, quarter-boundaries are only a few bpm apart and normal beat-to-beat noise
    /// alone would scatter samples across all four bands, producing a chart that looks like
    /// varied effort but is measuring jitter. Returning `nil` (and drawing nothing) is the honest
    /// outcome for a gentle walk — "the data doesn't support this" is a real answer.
    static let minimumRangeBpm: Double = 30

    /// The minimum number of samples worth banding. A handful of readings over an hour describes
    /// no shape, whatever the arithmetic says.
    static let minimumSampleCount = 10

    /// Band a workout's heart-rate samples.
    ///
    /// - Parameters:
    ///   - samples: heart-rate readings inside the workout window, any order.
    ///   - restingBpm: the person's own resting-heart-rate baseline. Nil means no baseline yet,
    ///     which is a legitimate early state and produces `nil` rather than a substituted
    ///     constant — a fabricated floor would shift every boundary.
    ///   - end: the workout's end, used to bound the final sample's dwell time so a trace that
    ///     stops early doesn't credit its last reading to the rest of the session.
    /// - Returns: `nil` whenever the data doesn't support banding, per the thresholds above.
    static func compute(samples: [(date: Date, value: Double)],
                        restingBpm: Double?,
                        end: Date) -> Result? {
        guard let restingBpm, restingBpm > 0 else { return nil }
        let ordered = samples
            .filter { $0.value.isFinite && $0.value > 0 }
            .sorted { $0.date < $1.date }
        guard ordered.count >= minimumSampleCount else { return nil }

        guard let peak = ordered.map(\.value).max() else { return nil }
        let range = peak - restingBpm
        guard range >= minimumRangeBpm else { return nil }

        var seconds: [Band: Double] = [:]
        for (index, sample) in ordered.enumerated() {
            // Each sample owns the interval until the next one (or until the workout ends for
            // the last). Attributing a sample the time BEFORE it instead would credit the first
            // reading with nothing and lose the final stretch entirely.
            let nextInstant = index + 1 < ordered.count ? ordered[index + 1].date : end
            let dwell = min(max(nextInstant.timeIntervalSince(sample.date), 0), maxSampleGapSeconds)
            guard dwell > 0 else { continue }
            seconds[band(for: sample.value, restingBpm: restingBpm, range: range), default: 0] += dwell
        }

        let bands = Band.allCases.map { BandTime(band: $0, seconds: seconds[$0] ?? 0) }
        // Every band empty means every dwell was clamped away (a trace of isolated samples with
        // large gaps). Nothing to draw.
        guard bands.contains(where: { $0.seconds > 0 }) else { return nil }
        return Result(bands: bands, restingBpm: restingBpm, peakBpm: peak)
    }

    /// Which band one reading falls in. Readings at or below resting land in `.easy` rather than
    /// being discarded: a heart rate below your own resting baseline during a workout is a real
    /// recorded moment (a warm-up, a pause), not an error to drop.
    static func band(for bpm: Double, restingBpm: Double, range: Double) -> Band {
        guard range > 0 else { return .easy }
        let fraction = (bpm - restingBpm) / range
        for band in Band.allCases where fraction <= band.upperFraction { return band }
        return .peak
    }
}
