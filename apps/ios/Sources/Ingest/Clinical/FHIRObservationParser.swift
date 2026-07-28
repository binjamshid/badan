import Foundation

// LAB-11 — HealthKit Clinical Records import, parsing half.
//
// A clinical record from HealthKit is not structured Swift data: `HKClinicalRecord.fhirResource`
// hands back a `Data` blob of raw FHIR JSON that the provider's system authored. Everything
// interesting therefore happens in parsing, which is why that half lives here as a pure function
// over `Data` — testable against real FHIR shapes with no HealthKit, no entitlement, and no device.
// `ClinicalRecordImporter` owns the HealthKit half and does no interpretation of its own.
//
// **This parser is deliberately conservative and lossy in one direction only: it drops what it
// cannot understand, and never guesses.** A provider's FHIR is not a contract BADAN controls —
// systems vary in which fields they populate, DSTU2 and R4 disagree on shapes, and a mis-parse here
// writes a wrong number into someone's medical record. So every field is optional, every failure
// path skips the observation rather than substituting a default, and the raw printed value is
// preserved verbatim (`rawValueText`) exactly as the rest of the lab notebook already does for OCR
// and manual entry.

/// One lab observation lifted out of a FHIR resource, before it becomes a `LabResult`.
///
/// Mirrors `LabResult`'s own value model rather than inventing a second one: raw text always,
/// structure layered on top only where the source actually provided it.
public struct FHIRLabObservation: Hashable, Sendable {
    /// The analyte name exactly as the provider printed it. Always present — an observation with no
    /// usable name is skipped rather than imported as "Unknown".
    public var displayName: String
    /// LOINC code when the resource carries one, for a future code-based analyte match. Nil rather
    /// than guessed, matching `AnalyteDefinition.loincCode`'s own stated discipline.
    public var loincCode: String?
    /// The value as printed, e.g. "5.4", "<0.1", "Negative". Always present.
    public var rawValueText: String
    public var comparator: LabComparator?
    public var numericValue: Double?
    public var rawUnit: String?
    public var resultType: LabResultType
    /// When the specimen was taken/observed.
    public var effectiveAt: Date?
    /// The provider's own reference interval, when stated. This is the FOUR-CONCEPT model's
    /// *source interval* (concept 1) and nothing else — never a personal baseline, never a user
    /// threshold, and never merged with either. Keeping it separate is the whole point of that
    /// model, and a clinical import is exactly where the two are easiest to conflate.
    public var sourceRangeLow: Double?
    public var sourceRangeHigh: Double?
    /// The provider's own abnormal flag text ("H", "L", "A"), when stated — the model's *source
    /// flag* (concept 2), preserved as the provider's words rather than re-derived by BADAN from
    /// the interval above. A lab that flags a value we would not have flagged is telling us
    /// something; overwriting its judgement with our own arithmetic would erase that.
    public var interpretationCode: String?
    /// Provider-assigned identity for this observation, used for idempotent re-import.
    public var sourceIdentifier: String?

    public init(displayName: String, loincCode: String? = nil, rawValueText: String,
                comparator: LabComparator? = nil, numericValue: Double? = nil, rawUnit: String? = nil,
                resultType: LabResultType, effectiveAt: Date? = nil,
                sourceRangeLow: Double? = nil, sourceRangeHigh: Double? = nil,
                interpretationCode: String? = nil, sourceIdentifier: String? = nil) {
        self.displayName = displayName
        self.loincCode = loincCode
        self.rawValueText = rawValueText
        self.comparator = comparator
        self.numericValue = numericValue
        self.rawUnit = rawUnit
        self.resultType = resultType
        self.effectiveAt = effectiveAt
        self.sourceRangeLow = sourceRangeLow
        self.sourceRangeHigh = sourceRangeHigh
        self.interpretationCode = interpretationCode
        self.sourceIdentifier = sourceIdentifier
    }
}

public enum FHIRObservationParser {
    /// Parses one FHIR resource blob into whatever lab observations it contains.
    ///
    /// Returns an array rather than a single value because the two resource types HealthKit hands
    /// back for lab data differ in cardinality: an `Observation` is one result, while a
    /// `DiagnosticReport` carries `contained` observations for a whole panel. A caller should not
    /// have to know which it received.
    ///
    /// Returns empty — never throws — for anything unparseable. A provider sending a shape this
    /// build does not understand must not fail the whole import of everything else they sent.
    public static func parse(_ data: Data) -> [FHIRLabObservation] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return parse(resource: root)
    }

    static func parse(resource: [String: Any]) -> [FHIRLabObservation] {
        switch resource["resourceType"] as? String {
        case "Observation":
            return observation(from: resource).map { [$0] } ?? []
        case "DiagnosticReport":
            // A panel. `contained` holds the individual observations inline; `result` holds
            // references to observations stored elsewhere, which this build cannot resolve (it has
            // no FHIR server to fetch from) and therefore ignores rather than importing as empty
            // rows. That is a real limitation, disclosed in `ClinicalRecordImporter`'s UI copy.
            let contained = resource["contained"] as? [[String: Any]] ?? []
            return contained.flatMap { parse(resource: $0) }
        default:
            return []
        }
    }

    private static func observation(from resource: [String: Any]) -> FHIRLabObservation? {
        // Skip anything the provider has retracted or is still drafting. Importing an
        // `entered-in-error` observation would put a value into someone's record that the lab has
        // explicitly withdrawn.
        let status = (resource["status"] as? String)?.lowercased()
        if let status, ["entered-in-error", "cancelled", "preliminary", "registered"].contains(status) {
            return nil
        }

        let code = resource["code"] as? [String: Any]
        let coding = (code?["coding"] as? [[String: Any]]) ?? []
        let loinc = coding.first { ($0["system"] as? String)?.contains("loinc") == true }

        // Name, in descending order of how much the provider meant it for a human to read. Skipped
        // entirely when none is present — a nameless value cannot be filed under a marker.
        let displayName = (code?["text"] as? String)
            ?? (loinc?["display"] as? String)
            ?? (coding.first?["display"] as? String)
        guard let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var observation = FHIRLabObservation(
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            loincCode: loinc?["code"] as? String,
            rawValueText: "", resultType: .textual,
            effectiveAt: date(from: resource["effectiveDateTime"])
                ?? date(from: (resource["effectivePeriod"] as? [String: Any])?["start"])
                ?? date(from: resource["issued"]),
            interpretationCode: interpretation(from: resource),
            sourceIdentifier: identifier(from: resource))

        applyValue(resource, to: &observation)
        guard !observation.rawValueText.isEmpty else { return nil }
        applyReferenceRange(resource, to: &observation)
        return observation
    }

    /// FHIR's value is a polymorphic `value[x]`. Each variant maps onto the lab notebook's existing
    /// `LabResultType` rather than a new vocabulary.
    private static func applyValue(_ resource: [String: Any], to observation: inout FHIRLabObservation) {
        if let quantity = resource["valueQuantity"] as? [String: Any],
           let value = double(from: quantity["value"]) {
            observation.numericValue = value
            observation.rawUnit = (quantity["unit"] as? String) ?? (quantity["code"] as? String)
            observation.resultType = .numeric
            // FHIR's own comparator field ("<", ">") for detection limits — the same concept
            // `LabComparator` already models for printed values.
            observation.comparator = (quantity["comparator"] as? String).flatMap(LabComparator.init(rawValue:))
            let printed = trimmedNumber(value)
            observation.rawValueText = [observation.comparator?.rawValue, printed]
                .compactMap { $0 }.joined()
            return
        }
        if let concept = resource["valueCodeableConcept"] as? [String: Any] {
            let text = (concept["text"] as? String)
                ?? ((concept["coding"] as? [[String: Any]])?.first?["display"] as? String)
            if let text, !text.isEmpty {
                observation.rawValueText = text
                // Positive/Negative/Detected are qualitative; a graded read would be `.ordinal`,
                // but nothing in a coded concept distinguishes the two reliably, so this does not
                // pretend to tell them apart.
                observation.resultType = .qualitative
            }
            return
        }
        if let text = resource["valueString"] as? String, !text.isEmpty {
            observation.rawValueText = text
            observation.resultType = .textual
        }
    }

    private static func applyReferenceRange(_ resource: [String: Any], to observation: inout FHIRLabObservation) {
        guard let range = (resource["referenceRange"] as? [[String: Any]])?.first else { return }
        observation.sourceRangeLow = double(from: (range["low"] as? [String: Any])?["value"])
        observation.sourceRangeHigh = double(from: (range["high"] as? [String: Any])?["value"])
    }

    private static func interpretation(from resource: [String: Any]) -> String? {
        // R4 makes `interpretation` an array; DSTU2 a single object. Both appear in the wild.
        if let array = resource["interpretation"] as? [[String: Any]], let first = array.first {
            return code(from: first)
        }
        if let single = resource["interpretation"] as? [String: Any] { return code(from: single) }
        return nil
    }

    private static func code(from concept: [String: Any]) -> String? {
        if let coding = (concept["coding"] as? [[String: Any]])?.first,
           let value = coding["code"] as? String, !value.isEmpty { return value }
        if let text = concept["text"] as? String, !text.isEmpty { return text }
        return nil
    }

    private static func identifier(from resource: [String: Any]) -> String? {
        if let identifiers = resource["identifier"] as? [[String: Any]],
           let value = identifiers.first?["value"] as? String, !value.isEmpty { return value }
        if let id = resource["id"] as? String, !id.isEmpty { return id }
        return nil
    }

    /// Accepts both JSON numbers and numeric strings — providers send both for the same field.
    private static func double(from any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let text = any as? String { return Double(text) }
        return nil
    }

    /// Renders a parsed magnitude back to text without inventing precision: 5.4 stays "5.4" and 12
    /// stays "12" rather than "12.0". `rawValueText` is what a person reads, so it should look like
    /// what the lab printed.
    private static func trimmedNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    private static let formatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()

    /// FHIR dates come as full instants, or as a bare `YYYY-MM-DD`, or with fractional seconds.
    /// A date that parses under none of these is left nil rather than defaulted to "now" — filing a
    /// result under today's date because its real date was unreadable would silently corrupt the
    /// timeline the whole notebook is organised around.
    static func date(from any: Any?) -> Date? {
        guard let text = any as? String, !text.isEmpty else { return nil }
        for formatter in formatters {
            if let parsed = formatter.date(from: text) { return parsed }
        }
        if text.count == 10 {
            let dayOnly = DateFormatter()
            dayOnly.calendar = Calendar(identifier: .gregorian)
            dayOnly.locale = Locale(identifier: "en_US_POSIX")
            dayOnly.timeZone = TimeZone(identifier: "UTC")
            dayOnly.dateFormat = "yyyy-MM-dd"
            return dayOnly.date(from: text)
        }
        return nil
    }
}
