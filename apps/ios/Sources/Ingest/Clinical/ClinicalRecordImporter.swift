import Foundation

/// LAB-11 — turns parsed clinical records into lab-notebook rows.
///
/// Split from `FHIRObservationParser` (pure, over `Data`) and from `HealthKitClinicalStore` (the
/// HealthKit call) so the mapping — which is where a clinical record becomes part of someone's
/// medical record — is testable end to end without an entitlement or a device. Given that no
/// physical device with real clinical records was available while this was built, making the
/// verifiable part as large as possible is the honest response, the same reasoning the GATT parsing
/// layer used when no BLE accessory was available.
///
/// **Placement:** everything written here lands in `badan_sensitive.db` through the existing
/// `LabReportRepository`/`LabResultRepository`, which are already sensitive-bound. Clinical records
/// are the most sensitive data BADAN ingests; they inherit the lab notebook's existing encryption,
/// purge, and export-gating behaviour rather than getting a parallel path.
public enum ClinicalRecordImporter {
    /// One provider's records, grouped as they will be filed.
    public struct Batch: Hashable, Sendable {
        public let sourceName: String
        public let observations: [FHIRLabObservation]

        public init(sourceName: String, observations: [FHIRLabObservation]) {
            self.sourceName = sourceName
            self.observations = observations
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var reportsCreated = 0
        public var resultsImported = 0
        /// Observations skipped because an identical result is already on file. Reported rather
        /// than hidden — "imported 0 of 14" with no explanation reads as a broken import.
        public var duplicatesSkipped = 0
        /// Observations that carried no usable date. Filed under nothing and skipped, never
        /// defaulted to today (see `FHIRObservationParser.date`).
        public var skippedMissingDate = 0
    }

    /// Files a batch into the notebook.
    ///
    /// Grouped into one `LabReport` per collection DAY per source, not one report per observation:
    /// a provider hands back a flat list of observations, but a person thinks in terms of "my blood
    /// work from March 14th". Grouping by day reconstructs that, and matches how a manually-entered
    /// or OCR'd report already looks in the notebook — so an imported report and a scanned one are
    /// the same kind of object rather than two shapes the UI has to distinguish.
    static func `import`(_ batch: Batch, reports: LabReportRepository, results: LabResultRepository,
                                analyteMatcher: AnalyteNameMatcher?, clock: Clock, deviceId: String) throws -> Outcome {
        var outcome = Outcome()
        let tz = TimeZone.current.identifier
        let now = clock.now()

        let dated = batch.observations.filter { $0.effectiveAt != nil }
        outcome.skippedMissingDate = batch.observations.count - dated.count

        let calendar = Calendar(identifier: .gregorian)
        let byDay = Dictionary(grouping: dated) { observation in
            calendar.startOfDay(for: observation.effectiveAt ?? now)
        }

        // Already-stored results for the whole notebook, read ONCE rather than per observation —
        // an import of a few hundred results should not issue a few hundred queries.
        let existing = try results.allLiveResults(includeSuppressed: true)
        var seen = Set(existing.map(duplicateKey))

        try results.transaction {
            for (day, observations) in byDay.sorted(by: { $0.key < $1.key }) {
                var reportId: String?

                for observation in observations {
                    let key = duplicateKey(observation: observation, day: day)
                    guard !seen.contains(key) else {
                        outcome.duplicatesSkipped += 1
                        continue
                    }
                    seen.insert(key)

                    // The report is created lazily, so a day whose every observation turns out to
                    // be a duplicate does not leave an empty report behind.
                    if reportId == nil {
                        let report = makeReport(day: day, sourceName: batch.sourceName, tz: tz,
                                                now: now, deviceId: deviceId)
                        try reports.insertReport(report)
                        reportId = report.id
                        outcome.reportsCreated += 1
                    }

                    guard let reportId else { continue }
                    try results.insertResult(makeResult(observation, reportId: reportId, day: day,
                                                        sourceName: batch.sourceName,
                                                        analyteMatcher: analyteMatcher,
                                                        now: now, tz: tz, deviceId: deviceId))
                    outcome.resultsImported += 1
                }
            }
        }
        return outcome
    }

    private static func makeReport(day: Date, sourceName: String, tz: String, now: Date,
                                   deviceId: String) -> LabReport {
        LabReport(
            id: ULID.newID(), sourceLabName: sourceName, collectionAt: day, reportedAt: nil, tzId: tz,
            documentRef: nil,
            // `.verifiedStructured` — the state `LabReviewState` reserved from the start for "a
            // structured, non-OCR path with no extraction guess involved", noting no shipped path
            // produced it yet. This is that path: the provider's own system authored these values,
            // so there is no extraction confidence to review. This is the one place in the app
            // where a result arrives needing no human verification, and saying so is the point —
            // marking it `needsReview` would ask a person to proof-read their own lab's output.
            reviewState: .verifiedStructured,
            ingestionPath: .platformStore,
            // Conservative by default. Nothing in a FHIR observation reliably says "this result is
            // an HIV or pregnancy test"; guessing `.standard` for a record that turns out to be
            // one of those would under-protect it, and the tier only ever raises protection.
            sensitivityTier: .high,
            updatedAt: now, originDeviceId: deviceId)
    }

    private static func makeResult(_ observation: FHIRLabObservation, reportId: String, day: Date,
                                   sourceName: String, analyteMatcher: AnalyteNameMatcher?,
                                   now: Date, tz: String, deviceId: String) -> LabResult {
        let id = ULID.newID()
        // Dictionary match by NAME only. A LOINC-code match would be better and the code is carried
        // on the observation for exactly that, but `analytes.json` has no LOINC index today and
        // building one from guessed codes is the failure `AnalyteDefinition.loincCode`'s own doc
        // warns against. An unmatched marker becomes a first-class free-text row (LAB-06), never a
        // blocked import.
        let match = analyteMatcher?.match(observation.displayName)
        var analyteId: String?
        if case .dictionary(let matched)? = match { analyteId = matched }

        let provenance = Provenance(
            sourceId: sourceName, deviceId: nil, ingestionPath: .platformStore,
            // The provider's own identifier, so a re-import of the same record is recognisable as
            // the same record rather than a second copy.
            externalId: observation.sourceIdentifier,
            measuredAt: observation.effectiveAt ?? day, measuredTimezone: tz,
            recordedAt: now, ingestedAt: now)

        return LabResult(
            id: id, reportId: reportId, panelId: nil,
            analyteId: analyteId,
            customLabel: analyteId == nil ? observation.displayName : nil,
            rawValueText: observation.rawValueText,
            comparator: observation.comparator,
            numericValue: observation.numericValue,
            rawUnit: observation.rawUnit,
            // `canonicalValue`/`canonicalUnit` are deliberately left nil here rather than converted.
            // Unit normalization is gated on an analyte's `conversionSafetyClass`, and running that
            // gate needs the full analyte definition — a conversion applied without it is exactly
            // the unsafe auto-conversion `UnitNormalization` exists to prevent. The as-reported
            // value and unit are always preserved, which is what the notebook actually displays.
            canonicalValue: nil, canonicalUnit: nil,
            resultType: observation.resultType,
            reviewState: .verifiedStructured,
            sensitivityTier: .high,
            originalId: id, supersedes: nil, revision: 1,
            provenance: provenance, updatedAt: now, originDeviceId: deviceId)
    }

    /// Identity for duplicate suppression: same marker, same day, same printed value.
    ///
    /// Deliberately NOT the provider's identifier alone. Re-importing genuinely is the common case
    /// here (a person taps "import" again after a new result arrives), and providers are
    /// inconsistent about identifier stability across fetches — keying on something they may
    /// regenerate would duplicate the entire history on every import. Marker+day+value is stable
    /// regardless, and the cost of its one false positive (two genuinely identical readings of the
    /// same marker on the same day) is that the second is skipped, which is the safer error.
    private static func duplicateKey(observation: FHIRLabObservation, day: Date) -> String {
        "\(observation.displayName.lowercased())|\(Int(day.timeIntervalSince1970))|\(observation.rawValueText)"
    }

    private static func duplicateKey(_ result: LabResult) -> String {
        let label = (result.customLabel ?? result.analyteId ?? "").lowercased()
        let day = Calendar(identifier: .gregorian).startOfDay(for: result.provenance.measuredAt)
        return "\(label)|\(Int(day.timeIntervalSince1970))|\(result.rawValueText)"
    }
}
