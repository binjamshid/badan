import SwiftUI
import Observation

// MARK: - View model

/// Everything the stress read needs off the main actor (PERF-01), mirroring `HealthMonitorFetchInputs`.
struct StressFetchInputs {
    var derivation: DerivationRepository
    var measurements: MeasurementRepository
    var registry: MetricRegistry
    /// EPIC-29. The context seam, read for one thing: the caveat beside the trend.
    var contextAnnotations: ContextAnnotationResolver
    var sensitiveModulesEnabled: Bool
    var clock: Clock
    var deviceId: String
    var now: Date
    var tz: String
}

/// What the card renders: today's surface state, the persisted history behind it, and any caveat for
/// the day it describes.
///
/// The two halves answer different questions and neither can answer the other's. `surface` is the
/// GATE's verdict — including, on a hidden day, the reason — and no stored row can express that (a
/// hidden day writes nothing at all, by design). `history` is what the derivation pipeline actually
/// persisted: the `stress.day_trend` rows that make this a trend with a past rather than a number
/// recomputed from scratch on every open.
struct StressCardData {
    var surface: StressSurface
    /// Persisted `stress.day_trend` rows over the recent window, oldest first — the days the gate
    /// cleared. Gaps are days it did not, and they stay gaps.
    var history: [(day: Date, value: Double)]
    /// EPIC-29 caveats for the day the surface describes. Empty on an ordinary day.
    var caveats: [LocalizedString]
}

/// EPIC-34's read path.
///
/// Calls `StressEngine.evaluate`, which **writes nothing**. That is the correct entry point for a
/// surface: the common answer on phone-and-watch-only data is "hidden", and an absence must not be
/// stored as a zero, a null row, or a "no data" sentinel — it is simply absent, and the card
/// explains it. Persisting a trend is the derivation pipeline's job (`DerivationCoordinator` step 5),
/// not a screen's — and this screen reads what that pipeline wrote for the history line, rather than
/// re-deriving a past it has no way to store.
@Observable
@MainActor
final class StressSurfaceViewModel {
    var state: LoadState<StressCardData> = .loading

    /// How many recent days of persisted trend the card shows behind today's value. A short window
    /// on purpose: the trend value already describes a multi-day span, so a long history line would
    /// be a rolling measure plotted against itself.
    static let historyDays = 14

    func load(_ env: AppEnvironment) async {
        let inputs = StressFetchInputs(
            derivation: env.derivation, measurements: env.measurements, registry: env.registry,
            contextAnnotations: env.contextAnnotations,
            sensitiveModulesEnabled: env.profile.sensitiveModulesEnabled,
            clock: env.clock, deviceId: env.deviceId, now: env.now(), tz: TimeZone.current.identifier)

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .success(let data):
            state = .loaded(data)
        case .failure(let error):
            LoadErrorLog.log(error, screen: "StressTrend")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    nonisolated static func fetch(_ inputs: StressFetchInputs) -> Result<StressCardData, Error> {
        do {
            let engine = StressEngine(derivation: inputs.derivation, measurements: inputs.measurements,
                                      registry: inputs.registry, clock: inputs.clock,
                                      deviceId: inputs.deviceId)
            let surface = try engine.evaluate(asOf: inputs.now, tz: inputs.tz)
            let history = try storedHistory(inputs)
            // A hidden day has no value to frame, so it gets no caveat either — the card is already
            // saying nothing about the person's pattern.
            let caveats = (surface.trend != nil && inputs.sensitiveModulesEnabled)
                ? try ContextCaveats.forDay(inputs.now, tz: inputs.tz, annotations: inputs.contextAnnotations)
                : []
            return .success(StressCardData(surface: surface, history: history, caveats: caveats))
        } catch {
            return .failure(error)
        }
    }

    /// The persisted trend rows for the recent window, oldest first. Latest-per-period (so a
    /// re-annotated or recomputed day shows its current row, with the superseded ones still on disk
    /// under I2), and days the gate refused are simply missing rather than zero-filled.
    private nonisolated static func storedHistory(_ inputs: StressFetchInputs) throws -> [(day: Date, value: Double)] {
        let earliest = DayAttribution.addingDays(-(historyDays - 1),
                                                 to: DayAttribution.startOfDay(inputs.now, tz: inputs.tz),
                                                 tz: inputs.tz)
        return try inputs.derivation.latestDerivedSeries(metricId: MetricID.stressDayTrend)
            .compactMap { row -> (day: Date, value: Double)? in
                guard row.periodKey.hasPrefix("day:"),
                      let day = DayAttribution.date(fromDayKey: String(row.periodKey.dropFirst(4)), tz: inputs.tz),
                      day >= earliest else { return nil }
                return (day: day, value: row.value)
            }
            .sorted { $0.day < $1.day }
    }
}

// MARK: - Presentation (pure, testable)

/// The pure mapping from `StressSurface` to what the card says. Extracted from the view so the two
/// rules that matter most here are unit-testable: a hidden surface renders the engine's own
/// device-factual explanation and nothing numeric, and every rendered trend carries the window it
/// describes rather than reading as "now".
enum StressPresentation {

    /// The directional chip. Never "high stress"/"low stress" — a direction relative to the
    /// person's own usual, which is all a `bandNeutralHalfWidth` around 50 can honestly support.
    static func chipSpec(_ band: StressTrendBand) -> (status: StatusChip.Status, label: LocalizedString) {
        switch band {
        case .higherThanUsual: return (.above, StressStrings.bandHigher)
        case .aboutUsual: return (.inBand, StressStrings.bandAbout)
        case .lowerThanUsual: return (.below, StressStrings.bandLower)
        }
    }

    /// The casual altitude's one sentence.
    static func sentence(_ band: StressTrendBand) -> LocalizedString {
        switch band {
        case .higherThanUsual: return StressStrings.sentenceHigher
        case .aboutUsual: return StressStrings.sentenceAbout
        case .lowerThanUsual: return StressStrings.sentenceLower
        }
    }

    /// "7 days" / "7 أيام" — a day-count fragment with correct Arabic agreement (1 singular ·
    /// 2 dual · 3–10 plural · 11+ indeclinable), mirroring `CalibrationCount`'s rule. Needed because
    /// the window length is contract data (`trendWindowDays`), so the copy cannot hardcode "week".
    static func dayCount(_ n: Int, language: AppLanguage, format: ValueFormatter) -> String {
        let number = format.integer(n)
        guard language == .ar else { return "\(number) days" }
        switch n {
        case 1: return "يوم واحد"
        case 2: return "يومان"
        case 3...10: return "\(number) أيام"
        default: return "\(number) يوماً"
        }
    }

    /// The window disclosure, on every rendered trend. `StressTrend` carries `windowDays` and its
    /// end day precisely so a surface cannot quietly relabel it "now"; this is where that guarantee
    /// becomes visible to the reader.
    static func windowNote(_ trend: StressTrend, language: AppLanguage, format: ValueFormatter) -> String {
        let day = DayAttribution.date(fromDayKey: trend.dayKey, tz: TimeZone.current.identifier)
            .map { ContextStatusDates.day($0, language: language) } ?? trend.dayKey
        return StressStrings.windowNote.filling([
            "span": dayCount(trend.windowDays, language: language, format: format),
            "day": day,
        ]).resolved(language)
    }

    /// The power-depth stat line. Label-and-value pairs rather than prose: it keeps the Arabic free
    /// of counted-noun agreement traps and matches the register the other power lines use.
    static func powerLine(_ trend: StressTrend, language: AppLanguage, format: ValueFormatter) -> String {
        StressStrings.powerLine.filling([
            "value": format.integer(Int(trend.value.rounded())),
            "confidence": String(format: "%.2f", trend.confidence),
            "present": format.integer(trend.daysPresent),
            "window": format.integer(trend.windowDays),
        ]).resolved(language)
    }

    /// The measured density behind a rendered trend, shown at power depth — "here is the evidence
    /// the gate ruled on" is what lets a reader judge the trend rather than take it, and it is the
    /// one thing that says whether a different device would change the answer.
    ///
    /// A trend is the only place it can appear: this reads `StressTrend.density`, and `.hidden`
    /// carries a reason and nothing else, so a refused surface has no density to print at any depth
    /// (`hiddenBody`).
    static func densityLine(_ density: StressDensity, language: AppLanguage, format: ValueFormatter) -> String {
        StressStrings.densityLine.filling([
            "samples": format.integer(density.daytimeSamples),
            "hours": format.integer(Int(density.daytimeHours.rounded())),
            "rate": String(format: "%.2f", density.samplesPerHour),
        ]).resolved(language)
    }

    /// The line under the stored-history sparkline. It says how many days the app has actually
    /// KEPT, which is the honest description of a series with gaps in it — the days the gate
    /// refused are missing, not zero, so a plain "last 14 days" would overstate what is plotted.
    static func historyNote(dayCount: Int, language: AppLanguage, format: ValueFormatter) -> String {
        StressStrings.historyNote
            .filling(["span": Self.dayCount(dayCount, language: language, format: format)])
            .resolved(language)
    }

    /// One spoken phrase for the whole card. Numbers are read as labelled values rather than as a
    /// punctuation-dense stat line. Any context caveat is read LAST, as the frame the reading should
    /// be taken in — the same order a sighted reader meets it in.
    static func spokenLabel(_ surface: StressSurface, depth: DepthPolicy, language: AppLanguage,
                            format: ValueFormatter, caveats: [LocalizedString] = []) -> String {
        var parts = [StressStrings.title.resolved(language)]
        switch surface {
        case .hidden(let reason):
            parts.append(reason.explanation.resolved(language))
        case .dense(let trend), .moderate(let trend):
            parts.append(chipSpec(trend.band).label.resolved(language))
            parts.append(sentence(trend.band).resolved(language))
            parts.append(windowNote(trend, language: language, format: format))
            if depth.showsPowerDetail {
                parts.append(powerLine(trend, language: language, format: format))
            }
        }
        parts.append(contentsOf: caveats.map { $0.resolved(language) })
        return parts.joined(separator: ". ")
    }
}

// MARK: - Card

/// EPIC-34 — the stress surface, under the Health Monitor. **The gate is the feature.**
///
/// The card renders exactly the three states `StressSurface` can express and cannot assemble a
/// fourth, because the enum is closed and carries its payload:
///
/// * **hidden** — the engine's own explanation, which is always a statement about what the DEVICE
///   records ("your device doesn't record daytime heart-rate variability often enough for this").
///   Never phrased as the user having done something wrong, never as BADAN having failed, and never
///   styled as an error — no warning triangle, no retry, no red. This is the default for
///   Apple-Watch-only data and it is a shipped state, not an empty one.
/// * **moderate** — a daily, explicitly low-confidence trend. Casual gets a direction word and one
///   sentence; the number itself is power-only, because a 0–100 index printed large next to sparse
///   sampling is precisely the false precision the epic exists to refuse.
/// * **dense** — the same daily trend plus an honest note that the hour-by-hour view is not computed
///   in this build (`StressEngine.intradayIndexImplemented` is `false`, in code, not in a comment).
///
/// **There is no live number here and no code path that could produce one.** Every rendered value
/// comes from a `StressTrend`, which carries the window it describes and no timestamp at all, and
/// the window is printed on the card.
struct StressTrendCard: View {
    @Environment(AppEnvironment.self) private var env
    var vm: StressSurfaceViewModel

    var body: some View {
        StatefulContainer(
            vm.state,
            retryTitle: env.s(LoadErrorCopy.retry),
            onRetry: { Task { await vm.load(env) } }
        ) { data in
            let surface = data.surface
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    header(surface)
                    switch surface {
                    case .hidden(let reason):
                        hiddenBody(reason)
                    case .moderate(let trend):
                        trendBody(trend, isDense: false)
                    case .dense(let trend):
                        trendBody(trend, isDense: true)
                    }
                    // EPIC-29: "computed while you were travelling". Below the trend body so it
                    // frames everything above it; nothing on an ordinary day, and nothing on a
                    // hidden day (there is no reading to frame).
                    ContextCaveatNote(caveats: data.caveats, language: env.language)
                    // The persisted history the derivation pipeline wrote. Only shown once there is
                    // more than one day of it — a "history" of a single point is a number with a
                    // chart drawn round it.
                    if data.history.count > 1 {
                        historyLine(data.history)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StressPresentation.spokenLabel(
                surface, depth: env.depth, language: env.language, format: env.format,
                caveats: data.caveats))
        }
    }

    /// The stored `stress.day_trend` rows as a plain sparkline plus its own disclosure of how many
    /// days it holds. Days the gate refused are absent from the series and stay absent — the line
    /// simply spans fewer points, never a zero-filled dip that would read as a calm day.
    private func historyLine(_ history: [(day: Date, value: Double)]) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            MetricChart(series: history.map { (date: $0.day, value: $0.value) },
                        style: .line,
                        language: env.language, arabicDigits: env.profile.arabicDigits)
                .frame(height: 64)
                .accessibilityHidden(true)
            Text(StressPresentation.historyNote(dayCount: history.count, language: env.language,
                                                format: env.format))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(_ surface: StressSurface) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: MetricFamily.stress.symbolName)
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            Text(StressStrings.title, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            if let trend = surface.trend {
                let spec = StressPresentation.chipSpec(trend.band)
                StatusChip(spec.status, label: env.s(spec.label), language: env.language)
            }
        }
    }

    // MARK: Hidden

    /// Calm and factual, and deliberately plain: no warning tint, no retry button, no "no data"
    /// placeholder. There is nothing for the user to fix, and offering an action would imply there
    /// is. The sentence itself comes from `StressAbsenceReason.explanation`, so an absence has no
    /// code path that reaches the screen unexplained.
    ///
    /// No density numbers here even at power depth: `.hidden` carries only the reason, by design —
    /// the state holds no `StressDensity`, so nothing downstream can rebuild a reading out of a
    /// surface that was refused.
    private func hiddenBody(_ reason: StressAbsenceReason) -> some View {
        Text(reason.explanation, language: env.language)
            .font(BadanFont.body)
            .foregroundStyle(BadanColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Trend

    @ViewBuilder
    private func trendBody(_ trend: StressTrend, isDense: Bool) -> some View {
        Text(StressPresentation.sentence(trend.band), language: env.language)
            .font(BadanFont.body)
            .foregroundStyle(BadanColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)

        // The window, always. This is the line that stops a daily trend from being read as a live
        // number, so it is not power-gated and not optional.
        Text(StressPresentation.windowNote(trend, language: env.language, format: env.format))
            .font(BadanFont.caption)
            .foregroundStyle(BadanColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        if trend.provisional {
            ProvisionalBadge(language: env.language)
        }

        if isDense {
            Text(StressStrings.intradayNote, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if env.depth.showsPowerDetail {
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                Text(StressPresentation.powerLine(trend, language: env.language, format: env.format))
                Text(StressPresentation.densityLine(trend.density, language: env.language, format: env.format))
            }
            .font(BadanFont.caption.monospacedDigit())
            .foregroundStyle(BadanColor.textSecondary)
            .environment(\.layoutDirection, .leftToRight)
        }
    }
}

// MARK: - Strings

/// Copy for the stress surface. Internal so `StressSurfacesTests` can assert every line carries real
/// Arabic and that nothing here claims a live reading.
enum StressStrings {
    static let title = LocalizedString(en: "Stress trend", ar: "اتجاه التوتر")

    static let bandHigher = LocalizedString(en: "Higher than usual", ar: "أعلى من المعتاد")
    static let bandAbout = LocalizedString(en: "About usual", ar: "قريب من المعتاد")
    static let bandLower = LocalizedString(en: "Lower than usual", ar: "أدنى من المعتاد")

    static let sentenceHigher = LocalizedString(
        en: "Your daytime load has been reading higher than your own usual.",
        ar: "كان الحِمل النهاري لديك أعلى من معتادك.")
    static let sentenceAbout = LocalizedString(
        en: "Your daytime load has been close to your own usual.",
        ar: "كان الحِمل النهاري لديك قريباً من معتادك.")
    static let sentenceLower = LocalizedString(
        en: "Your daytime load has been reading lower than your own usual.",
        ar: "كان الحِمل النهاري لديك أدنى من معتادك.")

    static let windowNote = LocalizedString(
        en: "Describes the {span} ending {day} — not a reading for right now.",
        ar: "يصف {span} تنتهي في {day} — وليست قراءة للحظة الحالية.")

    static let powerLine = LocalizedString(
        en: "Trend {value} of 100 · 50 is your own usual · confidence {confidence} · days used {present} of {window}",
        ar: "الاتجاه {value} من 100 · و50 هو معتادك · الثقة {confidence} · الأيام المستخدمة {present} من أصل {window}")

    static let densityLine = LocalizedString(
        en: "Daytime readings {samples} · waking hours {hours} · {rate} per hour",
        ar: "القراءات النهارية {samples} · ساعات اليقظة {hours} · {rate} لكل ساعة")

    static let historyNote = LocalizedString(
        en: "Saved daily trend from {span} your device could read. Days it couldn’t are left out, not filled in.",
        ar: "الاتجاه اليومي المحفوظ من {span} تمكّن جهازك من قراءتها. أما الأيام التي تعذّرت قراءتها فتُترك فارغة ولا تُملأ.")

    static let intradayNote = LocalizedString(
        en: "Your device samples often enough for an hour-by-hour view. BADAN doesn’t compute one yet, so this is the daily trend.",
        ar: "يقيس جهازك بتكرار يكفي لعرض ساعة بساعة. لكن بدن لا يحسب ذلك بعد، لذا ما يظهر هنا هو الاتجاه اليومي.")
}
