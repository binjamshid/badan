import Foundation

// MARK: - Status taxonomy

/// The curated set of circumstances a user can declare (plan §9.10). Small and closed on purpose:
/// these are the circumstances an engine has a defensible reason to caveat around. Anything else
/// is a `customLabel` — recorded and displayed, but it annotates the same way, because BADAN has
/// no basis for treating one user-invented circumstance differently from another.
///
/// Deliberately NOT diagnostic: `illness` means "the user said they were unwell", nothing more.
/// No code anywhere may read it as a condition, a severity, or a reason to change a number.
public enum ContextStatusKind: String, Codable, Hashable, Sendable, CaseIterable {
    case travel, illness, fasting, altitude, injury

    public var displayLabel: LocalizedString {
        switch self {
        case .travel: return LocalizedString(en: "Travelling", ar: "سفر")
        case .illness: return LocalizedString(en: "Feeling unwell", ar: "توعّك")
        case .fasting: return LocalizedString(en: "Fasting", ar: "صيام")
        case .altitude: return LocalizedString(en: "At altitude", ar: "على ارتفاع عالٍ")
        case .injury: return LocalizedString(en: "Injury", ar: "إصابة")
        }
    }

    /// The caveat an engine attaches to a value computed while this status was open. Phrased as
    /// "your usual pattern may not apply", never as an instruction and never as an explanation of
    /// the number — the value is what it is; this says only that the personal baseline it is read
    /// against was built from days that didn't look like this one.
    public var caveat: LocalizedString {
        switch self {
        case .travel:
            return LocalizedString(en: "Computed while you were travelling — your usual pattern may not apply.",
                                   ar: "حُسب أثناء سفرك — قد لا ينطبق نمطك المعتاد.")
        case .illness:
            return LocalizedString(en: "Computed while you noted feeling unwell — your usual pattern may not apply.",
                                   ar: "حُسب أثناء تسجيلك شعورًا بالتوعّك — قد لا ينطبق نمطك المعتاد.")
        case .fasting:
            return LocalizedString(en: "Computed during a fasting period you noted — your usual pattern may not apply.",
                                   ar: "حُسب خلال فترة صيام سجّلتها — قد لا ينطبق نمطك المعتاد.")
        case .altitude:
            return LocalizedString(en: "Computed while you noted being at altitude — your usual pattern may not apply.",
                                   ar: "حُسب أثناء وجودك على ارتفاع عالٍ سجّلته — قد لا ينطبق نمطك المعتاد.")
        case .injury:
            return LocalizedString(en: "Computed while you noted an injury — your usual pattern may not apply.",
                                   ar: "حُسب أثناء تسجيلك إصابة — قد لا ينطبق نمطك المعتاد.")
        }
    }
}

// MARK: - Context status (interval)

/// A user-declared interval that conditions how a value should be READ — never what it is (§9.10).
///
/// Sensitive-plus (I7), same as `JournalEntry`: travel, illness and injury intervals disclose
/// circumstance. Rows live only in `badan_sensitive.db`.
///
/// **Interval semantics.** `endAt == nil` is the normal case, not a malformed row: a status is
/// declared when it starts ("I'm travelling") and closed later, so an open-ended row means "still
/// active as of now". Every reader must treat nil as ongoing. Membership is half-open
/// (`startAt <= t < endAt`) so two back-to-back statuses that share an instant don't both claim it.
///
/// **The behavioural rule this type enforces structurally.** Engines read active statuses to
/// annotate CONFIDENCE and COPY, and never to alter a stored value. That is not a convention here,
/// it is the surface area: this type exposes no metric id, no value, no offset, no multiplier and
/// no adjustment of any kind, and its only output is `ContextAnnotation` — which carries a
/// confidence ceiling and caveat sentences and nothing else. There is deliberately no
/// `apply(to:)`/`adjust(_:)` taking a measurement or a `DerivedValue`, so "a status quietly changed
/// my number" is not a bug that can be introduced by misuse; it would require adding new API, in a
/// review that would have to argue against this paragraph.
public struct ContextStatus: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Taxonomy key (`ContextStatusKind.rawValue`). Nil exactly when `customLabel` is set.
    public var statusId: String?
    /// The user's own words for a circumstance the taxonomy doesn't name. Nil when `statusId` is set.
    public var customLabel: String?
    public var startAt: Date
    /// Nil = still active. See the interval-semantics note above.
    public var endAt: Date?
    public var tzId: String
    public var note: String?
    public var provenance: Provenance
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, statusId: String? = nil, customLabel: String? = nil,
                startAt: Date, endAt: Date? = nil, tzId: String, note: String? = nil,
                provenance: Provenance, updatedAt: Date, originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.statusId = statusId; self.customLabel = customLabel
        self.startAt = startAt; self.endAt = endAt; self.tzId = tzId; self.note = note
        self.provenance = provenance; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }

    /// The taxonomy kind, or nil for a custom status. Nil is a normal, displayable state — a
    /// custom status is a real status, not an unrecognized one.
    public var kind: ContextStatusKind? { statusId.flatMap { ContextStatusKind(rawValue: $0) } }

    /// Still running (no declared end).
    public var isOpenEnded: Bool { endAt == nil }

    /// Whether `instant` falls inside this interval. Half-open: the start instant is inside, the
    /// end instant is not.
    public func isActive(at instant: Date) -> Bool {
        guard instant >= startAt else { return false }
        guard let endAt else { return true }
        return instant < endAt
    }

    /// Whether this interval touches `[from, to)` at all — the query a day- or window-scoped
    /// engine asks ("was anything declared during the night I just scored?").
    public func overlaps(from: Date, to: Date) -> Bool {
        guard to > from else { return isActive(at: from) }
        if let endAt, endAt <= from { return false }
        return startAt < to
    }

    /// Display name: the taxonomy label, or the user's own words. Never an empty string — a
    /// status with neither (a corrupt row) reads as the generic word rather than blank.
    public var displayLabel: LocalizedString {
        if let kind { return kind.displayLabel }
        if let customLabel { return LocalizedString(en: customLabel, ar: customLabel) }
        return LocalizedString(en: "Context", ar: "سياق")
    }

    /// The caveat sentence for this status. A custom status gets the same generic sentence
    /// naming the user's own label — BADAN has no basis for a bespoke caveat about a circumstance
    /// it has never heard of, and inventing one would be false precision.
    public var caveat: LocalizedString {
        if let kind { return kind.caveat }
        let label = customLabel ?? ""
        return LocalizedString(en: "Computed during \u{201C}{label}\u{201D}, which you noted — your usual pattern may not apply.",
                               ar: "حُسب خلال \u{201C}{label}\u{201D} الذي سجّلته — قد لا ينطبق نمطك المعتاد.")
            .filling(["label": label])
    }
}

// MARK: - Annotation

/// Everything a `ContextStatus` is allowed to do to a derived result: cap its confidence and add
/// sentences explaining why. There is no value field here, by construction.
///
/// `confidenceCeiling` is a CEILING, not a multiplier and not a replacement: `applying(to:)`
/// returns `min(confidence, ceiling)`, so an already-low confidence is never raised by a context
/// being active, and a high one is capped rather than rescaled by a made-up factor.
public struct ContextAnnotation: Hashable, Sendable {
    /// The most confidence a value computed inside these intervals may claim. 1.0 = no cap.
    public let confidenceCeiling: Double
    /// One sentence per active status, in declaration order, both languages.
    public let caveats: [LocalizedString]

    public static let none = ContextAnnotation(confidenceCeiling: 1.0, caveats: [])

    public init(confidenceCeiling: Double, caveats: [LocalizedString]) {
        self.confidenceCeiling = min(max(confidenceCeiling, 0), 1)
        self.caveats = caveats
    }

    public var isEmpty: Bool { caveats.isEmpty }

    /// The confidence a consumer should publish instead of `confidence`. Monotonic and
    /// non-increasing: a context can only ever make BADAN less sure, never more.
    public func applying(to confidence: Double?) -> Double? {
        guard let confidence else { return nil }
        return min(confidence, confidenceCeiling)
    }
}

/// Reads active statuses and produces the annotation for a moment or a window. A free function on
/// a caseless enum rather than a method on `ContextStatus`, because the answer depends on the whole
/// SET of open intervals, not on any one of them.
public enum ContextAnnotator {

    /// The confidence ceiling applied whenever any status is open.
    ///
    /// Deliberately UNIFORM across kinds, and deliberately not a table of per-kind numbers. BADAN
    /// has no evidence base for claiming travel disturbs a personal baseline more (or less) than
    /// illness or altitude, and a ranked table would be exactly the false precision §4.9 rules out
    /// — a published number implies a study behind it. One honest statement ("a day you told us
    /// was unusual should not be read as confidently as an ordinary one") is what this encodes.
    ///
    /// 0.7 rather than something lower because the value is still fully valid and fully shown; the
    /// cap governs how strongly it is presented, not whether it is trusted.
    public static let activeContextConfidenceCeiling = 0.7

    /// The annotation for a single instant.
    public static func annotation(at instant: Date, statuses: [ContextStatus]) -> ContextAnnotation {
        make(from: statuses.filter { $0.deletedAt == nil && $0.isActive(at: instant) })
    }

    /// The annotation for a window — what a nightly score or a day rollup asks, since it describes
    /// a span rather than a moment. Any overlap counts: a status that covered half the night is
    /// still a reason the night wasn't ordinary.
    public static func annotation(from: Date, to: Date, statuses: [ContextStatus]) -> ContextAnnotation {
        make(from: statuses.filter { $0.deletedAt == nil && $0.overlaps(from: from, to: to) })
    }

    /// Ceilings do NOT compound across statuses: travel + illness is capped once, not squared.
    /// Two reasons to read a day carefully are not twice the uncertainty, and multiplying them
    /// would invent a number nothing supports.
    private static func make(from active: [ContextStatus]) -> ContextAnnotation {
        guard !active.isEmpty else { return .none }
        return ContextAnnotation(confidenceCeiling: activeContextConfidenceCeiling,
                                 caveats: active.map(\.caveat))
    }
}

// MARK: - The I7 seam

/// How a declared context reaches a score engine **without that engine touching the sensitive
/// database**. `context_statuses` live in `badan_sensitive.db` (I7); every score engine holds a
/// connection to `badan.db` and only that. Handing an engine a `JournalRepository` to fix this would
/// put a sensitive connection in scope inside the derivation pipeline — the exact structural
/// property `JournalRepository`'s own header says makes I7 enforceable rather than remembered.
///
/// So the boundary is crossed by a FUNCTION, resolved once in the composition root (which already
/// holds both connections legitimately) and injected into each engine. An engine asks "what was
/// declared over `[from, to)`?" and receives a `ContextAnnotation` — a ceiling and some sentences.
/// It cannot ask which status, cannot enumerate rows, and cannot write one.
///
/// **What crosses, and what does not.** Only the CEILING is persisted, onto the `confidence` column
/// of a row in the main database — a bare number that names no circumstance. The caveat sentences
/// are never stored: a surface renders them by reading the sensitive store itself at display time
/// (see `ContextCaveats`), so no word like "travelling" or "unwell" is ever written to `badan.db`
/// and the sensitive purge remains a literal file deletion that takes the disclosure with it.
///
/// The window is per-value, not per-run, because a recompute covers many days and only some of them
/// may sit inside a declared interval.
typealias ContextAnnotationResolver = (Date, Date) throws -> ContextAnnotation

/// The resolver an engine gets when nobody wired one: no context, ever. The honest default — an
/// engine constructed without the seam annotates nothing rather than guessing.
let noContextAnnotations: ContextAnnotationResolver = { _, _ in .none }

// MARK: - Caveat read model (display side)

/// The display half of the seam: what a surface calls to show "computed while you were travelling"
/// beside a score, in the reader's language.
///
/// Deliberately separate from the engine side, and deliberately fed by the SAME
/// `ContextAnnotationResolver` the engines take rather than by the sensitive repository directly: a
/// caveat is sensitive-plus TEXT, and the fewer places that hold a sensitive connection, the less
/// there is to get wrong. The two halves cannot disagree, because both read the annotation for the
/// same day window through `ContextAnnotator`.
enum ContextCaveats {

    /// The caveat sentences for the local day a derived value is attributed to, or `[]` when the
    /// day sat inside no declared interval — which is the ordinary case, and renders as nothing.
    ///
    /// The window is the local day itself, matching the day attribution every engine scores by: a
    /// status the user declared for yesterday annotates yesterday's rows, not today's.
    static func forDay(_ day: Date, tz: String, annotations: ContextAnnotationResolver) throws -> [LocalizedString] {
        let from = DayAttribution.startOfDay(day, tz: tz)
        return try annotations(from, DayAttribution.addingDays(1, to: from, tz: tz)).caveats
    }

    /// Same, for a `"day:YYYY-MM-DD"` period key — the shape every per-day score row carries. A key
    /// in any other shape (a session key, a week rollup) resolves to no caveats rather than to a
    /// guessed day.
    static func forPeriodKey(_ periodKey: String, tz: String,
                             annotations: ContextAnnotationResolver) throws -> [LocalizedString] {
        guard periodKey.hasPrefix("day:"),
              let day = DayAttribution.date(fromDayKey: String(periodKey.dropFirst(4)), tz: tz) else { return [] }
        return try forDay(day, tz: tz, annotations: annotations)
    }
}
