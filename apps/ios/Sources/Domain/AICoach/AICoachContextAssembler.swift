import Foundation

/// On-device retrieval for the AI coach (A9 / ADR-0010 / D-22's "on-device retrieval" half).
/// Assembles a small, explicit, NAMED context bundle from ONLY non-sensitive derived summary
/// data — the append-only `DerivedValue` rows in `badan.db`, read through `DerivationRepository`
/// (INVARIANT I2: latest `computedAt` wins). Never raw measurements, never anything from
/// `badan_sensitive.db` (medications, symptoms, cycle, labs, journal — A9's own text: "never raw
/// health rows, never an export bundle"), never anything routed through `LoggingRepository` or
/// any sensitive-connection repository.
///
/// This IS structural, and the guarantee is `NonSensitiveDerivation` below, not a bare
/// `DerivationRepository`: `assembleToday`'s parameter type only ever wraps a repository that
/// type itself just bound to `Database.main` — its initializer takes a whole `Database` and
/// resolves `.main` internally, so there is no argument a caller could pass that binds it to
/// `.sensitive` instead.
///
/// (Independent audit finding, 2026-07-23, corrected the claim this comment used to make: a
/// bare `DerivationRepository` is a generic wrapper over ANY `SQLiteConnection`, and this exact
/// codebase already constructs sensitive-bound instances of it in three other places —
/// `HomeScreen.swift`, `BodyScreen.swift`, `CycleModuleServices.swift` — so accepting one as a
/// parameter here would have made the "impossible by construction" claim false: nothing but
/// caller discipline would have stopped a future edit from passing a sensitive-bound instance in.
/// `NonSensitiveDerivation` closes that gap for real, at the type level, rather than just
/// softening the comment.)
///
/// `AICoachContextAssemblerTests` exercises this empirically too
/// (`testNeverSurfacesSensitiveDataEvenWhenPresentInTheSameDatabaseInstance`: seeds the sensitive
/// DB with a distinctive value and asserts it never appears in the rendered output) — belt and
/// braces alongside the type-level guarantee above, not a substitute for it.
///
/// Mirrors `HomeScreen`'s own "latest scoreable value + confidence + algorithm label" resolution
/// (`HomeData` assembly, `DerivationRepository.latestDerived(metricId:periodKey:)`) rather than
/// reinventing it — same metric ids, same latest-read-wins semantics.
enum AICoachContextAssembler {

    /// A `DerivationRepository` proven, at construction, to be bound to `Database.main` — never
    /// `Database.sensitive`. The only initializer takes a whole `Database` and always resolves
    /// `.main` itself, so unlike a bare `DerivationRepository` value (which reveals nothing about
    /// which connection backs it, and which this codebase does bind to `Database.sensitive` in
    /// `HomeScreen`/`BodyScreen`/`CycleModuleServices`), there is no argument this type's
    /// initializer accepts that could bind it to the sensitive connection instead. Exists
    /// entirely so `AICoachContextAssembler.assembleToday`'s parameter type can make its own
    /// header's "structural" claim actually true rather than caller-discipline-only.
    struct NonSensitiveDerivation {
        fileprivate let repository: DerivationRepository
        init(_ database: Database) {
            self.repository = DerivationRepository(database.main)
        }
    }

    /// One named, provenance-carrying context item — a derived SCORE, never a raw measurement,
    /// always carrying its confidence/provisional/algorithm identity. This is exactly the shape
    /// the consent screen promises leaves the device: "the query + minimal retrieved context...
    /// never raw health rows."
    struct ContextItem: Equatable {
        let metricId: String
        let label: LocalizedString
        let value: Double
        let unit: String
        let confidence: Double?
        let provisional: Bool
        let algorithmId: String
        let algorithmVersion: String
    }

    /// The full bundle for one request. An empty bundle (no scores computed yet — day one of a
    /// fresh install) is an honest, expected state, never an error.
    struct ContextBundle: Equatable {
        let items: [ContextItem]
        let asOfDayKey: String

        var isEmpty: Bool { items.isEmpty }
    }

    /// The published daily scores (docs/algorithms/{readiness,effort,sleep}.md) — the exact three
    /// the recon named as safe, non-sensitive, provenance-carrying context: Readiness, Effort,
    /// Sleep. Deliberately a short, fixed list rather than "everything in `badan.db`" — minimal by
    /// construction, not by runtime filtering.
    private static let dailyMetrics: [(id: String, label: LocalizedString)] = [
        (MetricID.readinessScore, LocalizedString(en: "Readiness", ar: "الجاهزية")),
        (MetricID.effortDay, LocalizedString(en: "Effort", ar: "الجهد")),
        (MetricID.sleepPerformance, LocalizedString(en: "Sleep", ar: "النوم")),
    ]

    /// Assemble today's context bundle (in `tz`, the device's current zone at call time — the
    /// same "today" boundary every other live-read surface in this app uses). One
    /// `latestDerived` call per published score; a score with no row yet is simply omitted, never
    /// synthesized or defaulted.
    static func assembleToday(derivation: NonSensitiveDerivation, now: Date, tz: String) throws -> ContextBundle {
        let dayKey = DayAttribution.localDayKey(now, tz: tz)
        let periodKey = "day:" + dayKey
        var items: [ContextItem] = []
        for entry in dailyMetrics {
            guard let dv = try derivation.repository.latestDerived(metricId: entry.id, periodKey: periodKey) else { continue }
            items.append(ContextItem(
                metricId: dv.metricId, label: entry.label, value: dv.value, unit: dv.unit,
                confidence: dv.confidence, provisional: dv.provisional,
                algorithmId: dv.algorithmId, algorithmVersion: dv.algorithmVersion))
        }
        return ContextBundle(items: items, asOfDayKey: dayKey)
    }

    /// Render the bundle as the compact plain-text block that actually accompanies a query in the
    /// outgoing request — and the same text `AICoachChatScreen` shows back to the user as "what
    /// was included in this turn" (transparency, not a hidden black box). Deliberately short: a
    /// few labeled numbers, never prose that could smuggle in more than the consent screen
    /// promised.
    static func renderForRequest(_ bundle: ContextBundle, language: AppLanguage) -> String {
        guard !bundle.isEmpty else {
            return AICoachContextStrings.noScoresYet.resolved(language) + " (\(bundle.asOfDayKey))"
        }
        let lines = bundle.items.map { item -> String in
            let confidenceText = item.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
            let provisionalText = item.provisional
                ? " " + AICoachContextStrings.provisionalSuffix.resolved(language) : ""
            return "\(item.label.resolved(language)): \(String(format: "%.1f", item.value)) \(item.unit)"
                + " — \(AICoachContextStrings.confidenceLabel.resolved(language)) \(confidenceText)\(provisionalText)"
                + " (\(item.algorithmId)@\(item.algorithmVersion))"
        }
        let header = AICoachContextStrings.contextHeader.resolved(language) + " \(bundle.asOfDayKey):"
        return ([header] + lines).joined(separator: "\n")
    }
}

private enum AICoachContextStrings {
    static let contextHeader = LocalizedString(en: "Today's context", ar: "سياق اليوم")
    static let noScoresYet = LocalizedString(
        en: "No scores available yet", ar: "لا توجد نتائج متاحة بعد")
    static let confidenceLabel = LocalizedString(en: "confidence", ar: "مستوى الثقة")
    static let provisionalSuffix = LocalizedString(en: "(still settling in)", ar: "(لا يزال قيد الاستقرار)")
}
