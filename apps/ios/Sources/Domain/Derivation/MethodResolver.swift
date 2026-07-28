import Foundation

/// How a stored method choice becomes the `algorithmId` derivation actually runs (D-35).
///
/// A pure function of (metricId, profile, registry), deliberately: the interesting case is "the
/// stored id no longer exists" — the app updated and an entry was withdrawn — and that has to be
/// testable without a database, an engine or a screen.
///
/// The rule in one line: honour the user's choice when it is still a real producer of that metric,
/// otherwise fall back to the contract default AND say so. Never silently honour a withdrawn id,
/// never crash, and never resolve to "compute nothing" — an unavailable spec is how BADAN says it
/// has no constants, and a stale preference is not that.
enum MethodResolver {
    struct Resolution: Equatable {
        let algorithmId: String
        /// The id the profile asked for, when it could not be honoured. Non-nil means the surface
        /// must disclose that a fallback happened — a number computed by a method other than the
        /// one the user believes they selected is exactly the kind of quiet mismatch this codebase
        /// removes elsewhere.
        let withdrawnChoice: String?
    }

    /// Every algorithm entry that genuinely produces `metricId`, in contract order.
    ///
    /// **Filters the `"*"` wildcard.** `AlgorithmRegistry.producers(of:)` matches
    /// `producesMetricIds.contains("*") || producesMetricIds.contains(metricId)`, and
    /// `baseline.rolling_median_mad` declares `"*"` — so asking it for readiness's producers
    /// returns the baseline engine alongside the real ones. Without this filter the baseline would
    /// appear in the method picker as a selectable way to compute readiness, and a stored choice of
    /// it would validate. Match on the explicit id only.
    static func selectableMethods(for metricId: String,
                                  registry: AlgorithmRegistry) -> [AlgorithmDefinition] {
        registry.producers(of: metricId).filter { $0.producesMetricIds.contains(metricId) }
    }

    /// The method to run for `metricId`.
    ///
    /// - Parameter contractDefault: the id the engine used before methods were selectable. It stays
    ///   the fallback rather than "the first producer" because contract order is not a ranking, and
    ///   silently promoting whichever entry happens to sort first would change everyone's numbers
    ///   the moment a variant was added.
    static func resolve(metricId: String, contractDefault: String,
                        profile: CustomizationProfile,
                        registry: AlgorithmRegistry) -> Resolution {
        guard let chosen = profile.methodChoices[metricId], chosen != contractDefault else {
            return Resolution(algorithmId: contractDefault, withdrawnChoice: nil)
        }
        let available = selectableMethods(for: metricId, registry: registry).map(\.algorithmId)
        guard available.contains(chosen) else {
            return Resolution(algorithmId: contractDefault, withdrawnChoice: chosen)
        }
        return Resolution(algorithmId: chosen, withdrawnChoice: nil)
    }

    /// Convenience for engines and the coordinator, which need the id and nothing else.
    static func activeAlgorithmId(for metricId: String, contractDefault: String,
                                  profile: CustomizationProfile,
                                  registry: AlgorithmRegistry) -> String {
        resolve(metricId: metricId, contractDefault: contractDefault,
                profile: profile, registry: registry).algorithmId
    }
}
