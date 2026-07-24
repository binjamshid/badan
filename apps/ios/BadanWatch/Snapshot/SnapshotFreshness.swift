import Foundation

/// A22/EPIC-42's own honest-degradation requirement: "if the snapshot is stale/missing, the watch
/// app must say so plainly, never show stale data as if fresh." This mirrors the SAME two
/// disciplines already established elsewhere in this codebase rather than inventing a new one:
///
///   1. **nil-collapse.** A missing value is shown as "no data yet", never fabricated —
///      `AmbientSnapshotDto`'s own optional fields, and every `BadanWidgets` widget view, already
///      follow this. `TodayViewState.build` gets this for free by reading `AmbientSnapshotDto`'s
///      optionals exactly the way a widget reads them.
///   2. **Relative "X ago" labelling**, off the SAME `RelativeDateTimeFormatter` pattern
///      `HomeDateFormatting.relative` (`Features/Home/HomeScreen.swift`) and `SourcesDateText
///      .relative` (`Features/Body/SourcesScreen.swift`) already use. This target cannot import
///      either (separate watchOS module — see `AmbientSnapshotDto.swift`'s header), so
///      `relativeLabel` below is a small hand-picked mirror, the same kind of mirror
///      `BadanWidgets`' own `WidgetCopy`/`WidgetLanguage` already are for ITS boundary.
///
/// What genuinely IS new here, stated plainly rather than borrowed from a threshold that doesn't
/// exist upstream: neither `BadanWidgets` nor anywhere else in this codebase has ever needed an
/// AGE-based staleness threshold — their nil-collapse discipline alone was always sufficient,
/// because an app-group file the SAME device's own recently-run app wrote is never meaningfully
/// "old" the way data relayed across two separate physical devices can be. A Watch can be out of
/// Bluetooth/Wi-Fi range of its phone, or the phone can simply not be running, for hours, with no
/// new `updateApplicationContext` landing the whole time — a real failure mode `BadanWidgets` never
/// faces. `staleAfter` below is this slice's own judgment call for that genuinely new problem.
enum SnapshotFreshness {
    /// Past this age, `generatedAt` is treated as stale enough to warn about explicitly — chosen to
    /// comfortably span one missed overnight sync (readiness/sleep/effort are each computed at most
    /// once a day) while still catching a watch that has genuinely lost touch with its phone for
    /// the better part of a day.
    static let staleAfter: TimeInterval = 6 * 3600

    enum State: Equatable {
        /// This watch has never received a snapshot at all (fresh install, or never yet in range of
        /// its phone) — a real, distinct, honestly-labelled state, never conflated with "received
        /// once, now old."
        case neverSynced
        /// Received at least once; `age` is how long ago the underlying data was GENERATED ON THE
        /// PHONE (`snapshot.generatedAt`), not when this watch happened to receive it — the number
        /// that actually answers "how current is what I'm looking at."
        case fresh(age: TimeInterval)
        case stale(age: TimeInterval)
    }

    static func state(generatedAt: Date?, now: Date) -> State {
        guard let generatedAt else { return .neverSynced }
        let age = max(0, now.timeIntervalSince(generatedAt))
        return age > staleAfter ? .stale(age: age) : .fresh(age: age)
    }

    /// A locale-aware "2 hours ago" / "منذ ساعتين" — see this type's own header for why this
    /// mirrors `HomeDateFormatting.relative`/`SourcesDateText.relative` rather than reinventing the
    /// approach, while necessarily reimplementing the few lines (this target cannot import either).
    static func relativeLabel(_ date: Date, isArabic: Bool, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: isArabic ? "ar" : "en_US")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
