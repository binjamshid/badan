import Foundation

/// Which physical database owns a measured metric's rows (A21/D-26 scope-gap closure).
///
/// This is the ONE place the rule lives. `MeasurementRepository` asks it on every read and write;
/// `SensitiveMeasurementRelocator` asks it to decide what to move off an upgrading install's
/// `badan.db`. Nothing else re-derives it.
///
/// That single-definition discipline is deliberate, and it is the direct lesson of two prior bugs
/// in this codebase where the same classification logic existed in two layers and silently drifted
/// apart: the Source Priority Editor's `ClassificationKey` bridge (which lived in the UI while
/// ingestion constructed candidates without it, so the editor had zero real effect), and
/// `CyclePhaseCovariateCoordinator`'s baseline routing (which wrote a reproductive-phase word into
/// the main DB because two `DerivationRepository`s could be collapsed into one connection). Both
/// were found by audit, not by tests. A routing rule that can be re-implemented at a call site is
/// a routing rule that will eventually disagree with itself, and here disagreement means either a
/// sensitive row in the wrong file or a read that cannot find rows that exist.
enum MeasurementRouting {
    /// Metrics whose measurement rows belong in `badan_sensitive.db` rather than `badan.db`.
    ///
    /// The rule is the registry's own `sensitiveClass`, NOT a hardcoded metric list — `body.glucose`
    /// is the only metric it selects today, but a future sensitive-plus measured metric inherits
    /// the correct placement with no code change here, which is the whole point.
    ///
    /// Unknown ids (absent from the registry) route to `main`. That is the same posture
    /// `ExportRunner.metricAllowed` already takes for an unknown id, and it is sound in the
    /// direction that matters: nothing can be sensitive-plus without the registry saying so, so an
    /// id the registry has never heard of cannot be a sensitive-plus id whose placement we got
    /// wrong — it is an id with no data flowing for it at all.
    static func isSensitive(metricId: String, registry: MetricRegistry = .shared) -> Bool {
        registry.definition(metricId)?.sensitiveClass == .sensitivePlus
    }

    /// Every sensitive-plus metric id the registry currently defines, for the relocator's sweep of
    /// an upgrading install. Computed on demand from the registry rather than cached in a `static
    /// let`, because tests construct registries with injected metric sets.
    static func sensitiveMetricIds(registry: MetricRegistry = .shared) -> [String] {
        registry.all.filter { $0.sensitiveClass == .sensitivePlus }.map(\.metricId)
    }
}
