import Foundation

/// The safe/conditional/unsafe/none conversion-safety gate (LAB-08 / plan §7A.4's unit-normalization
/// requirement): only a `.safe`-class analyte ever gets an auto-computed value in a second
/// (canonical) unit. Every other class keeps ONLY the as-entered value/unit — normalization fields
/// are left ABSENT, never zero, never guessed — so a result reported in an unusual or ambiguous unit
/// is never silently reinterpreted.
///
/// This does NOT reuse `Units` (`Core/Units.swift`, the raw table-driven conversion BADAN already
/// uses for wearable metrics) as its conversion mechanism, and that is a deliberate choice, not an
/// oversight: `Units.table` holds exactly ONE global factor per unit symbol, which is correct for a
/// physical dimension (a kilogram is a kilogram everywhere) but WRONG for the lab conversions this
/// slice cares about — mg/dL↔mmol/L is a MOLAR-MASS conversion whose factor differs PER ANALYTE
/// (glucose's factor is not creatinine's, is not cholesterol's). A single global "mg/dL → mmol/L"
/// table entry would silently apply the wrong factor to whichever analyte asked first. `Units.table`
/// also simply does not contain most lab-specific unit symbols (mmol/mol, µmol/L, IU/L…) and this
/// file must not extend that table — `Core/Units.swift` is outside this slice's owned files.
///
/// Instead, `.safe`-class conversions are held here as a SMALL, EXPLICIT, per-analyte table
/// (`analyteConversions`), each entry citing the published clinical-chemistry factor or crosswalk it
/// implements. Growing this table is a deliberate, reviewed, cited addition — never a fallback
/// guess, matching this file's `AnalyteDefinition.loincCode` discipline of "absent rather than
/// guessed": an analyte whose conversion isn't in this table (including every `.conditional`/
/// `.unsafe`/`.none` analyte) simply never gets a `canonicalValue` — the as-entered value/unit is
/// the only thing ever shown for it.
public enum UnitNormalization {

    /// The additional (never-replacing) normalized pair. Both fields are set together or both are
    /// absent — there is no "canonicalValue with no unit" or vice versa.
    public struct Normalized: Equatable, Sendable {
        public let canonicalValue: Double?
        public let canonicalUnit: String?

        public static let absent = Normalized(canonicalValue: nil, canonicalUnit: nil)

        public init(canonicalValue: Double?, canonicalUnit: String?) {
            self.canonicalValue = canonicalValue
            self.canonicalUnit = canonicalUnit
        }
    }

    /// Computes the additional canonical pair for one as-reported value+unit, or `.absent` when the
    /// analyte's class forbids it, the analyte is unknown, the value/unit is missing, the pair isn't
    /// in `analyteConversions`, or `unit` already equals the canonical unit (nothing to add).
    public static func normalize(value: Double?, unit: String?, analyte: AnalyteDefinition?) -> Normalized {
        guard let analyte, analyte.conversionSafetyClass == .safe, let value, let unit,
              unit != analyte.canonicalUnit else { return .absent }
        guard let entry = analyteConversions.first(where: {
            $0.analyteId == analyte.id && $0.fromUnit == unit && $0.toUnit == analyte.canonicalUnit
        }) else { return .absent }
        return Normalized(canonicalValue: entry.convert(value), canonicalUnit: analyte.canonicalUnit)
    }

    /// One published, cited conversion this codebase is confident enough about to auto-apply. Keyed
    /// by (analyteId, fromUnit, toUnit) rather than by unit pair alone — see the type's header doc
    /// for why a global unit-pair table would be wrong here.
    private struct AnalyteConversion {
        let analyteId: String
        let fromUnit: String
        let toUnit: String
        let convert: (Double) -> Double
    }

    /// Standard clinical-chemistry conversion factors (molar-mass-derived, unless noted) and the
    /// NGSP→IFCC HbA1c crosswalk — the flagship example this slice's brief names explicitly. Only
    /// the ONE direction each analyte's `canonicalUnit` actually needs is listed (`normalize` only
    /// ever looks up `toUnit == analyte.canonicalUnit`) — `analytes.json` picks the SI unit as
    /// canonical for each of these (the more globally standard convention, and the one BADAN's
    /// GCC-facing market more commonly reports in), converting FROM the US-conventional mass/volume
    /// unit a US-trained lab or an imported American PDF is more likely to print. Deliberately
    /// small; see the type's own doc for why this table is never treated as a place to guess an
    /// unpublished factor.
    private static let analyteConversions: [AnalyteConversion] = [
        // HbA1c: IFCC (mmol/mol) -> NGSP (%), the standard published master-equation crosswalk
        // (NGSP.org): percent = mmol/mol ÷ 10.929 + 2.15.
        AnalyteConversion(analyteId: "hba1c", fromUnit: "mmol/mol", toUnit: "%") { $0 / 10.929 + 2.15 },
        // Glucose (molar mass 180.16 g/mol): mg/dL × 0.0555 = mmol/L. Same factor across every
        // glucose-family analyte below — duplicated per id rather than factored out, since each id
        // is an independent, individually-reviewable contract row.
        AnalyteConversion(analyteId: "glucose_fasting", fromUnit: "mg/dL", toUnit: "mmol/L") { $0 * 0.0555 },
        AnalyteConversion(analyteId: "glucose_random", fromUnit: "mg/dL", toUnit: "mmol/L") { $0 * 0.0555 },
        AnalyteConversion(analyteId: "ogtt_2h_glucose", fromUnit: "mg/dL", toUnit: "mmol/L") { $0 * 0.0555 },
        // Creatinine (molar mass 113.12 g/mol): mg/dL × 88.4 = µmol/L.
        AnalyteConversion(analyteId: "creatinine", fromUnit: "mg/dL", toUnit: "umol/L") { $0 * 88.4 },
        // Urea nitrogen (BUN): mg/dL × 0.357 = mmol/L urea (the standard BUN→urea crosswalk).
        AnalyteConversion(analyteId: "bun", fromUnit: "mg/dL", toUnit: "mmol/L") { $0 * 0.357 },
        // Calcium (molar mass 40.08 g/mol): mg/dL × 0.2495 = mmol/L.
        AnalyteConversion(analyteId: "calcium", fromUnit: "mg/dL", toUnit: "mmol/L") { $0 * 0.2495 },
        // Cholesterol family (molar mass ~386.65 g/mol): mg/dL × 0.02586 = mmol/L. Same factor for
        // total/LDL/HDL — they are the same molecule measured in different fractions.
        AnalyteConversion(analyteId: "total_cholesterol", fromUnit: "mg/dL", toUnit: "mmol/L") { $0 * 0.02586 },
        AnalyteConversion(analyteId: "ldl", fromUnit: "mg/dL", toUnit: "mmol/L") { $0 * 0.02586 },
        AnalyteConversion(analyteId: "hdl", fromUnit: "mg/dL", toUnit: "mmol/L") { $0 * 0.02586 },
        // Triglycerides (molar mass ~885 g/mol average): mg/dL × 0.01129 = mmol/L.
        AnalyteConversion(analyteId: "triglycerides", fromUnit: "mg/dL", toUnit: "mmol/L") { $0 * 0.01129 },
        // Uric acid (molar mass 168.11 g/mol): mg/dL × 59.48 = µmol/L.
        AnalyteConversion(analyteId: "uric_acid", fromUnit: "mg/dL", toUnit: "umol/L") { $0 * 59.48 },
        // Bilirubin (total + direct; molar mass 584.66 g/mol): mg/dL × 17.1 = µmol/L.
        AnalyteConversion(analyteId: "total_bilirubin", fromUnit: "mg/dL", toUnit: "umol/L") { $0 * 17.1 },
        AnalyteConversion(analyteId: "direct_bilirubin", fromUnit: "mg/dL", toUnit: "umol/L") { $0 * 17.1 },
    ]

    /// Convenience overload operating directly on a `LabResult`'s own as-reported fields.
    public static func normalize(_ result: LabResult, analyte: AnalyteDefinition?) -> Normalized {
        normalize(value: result.numericValue, unit: result.rawUnit, analyte: analyte)
    }

    /// Applies `normalize` to `result`, returning a copy with `canonicalValue`/`canonicalUnit`
    /// (re)computed from its current `numericValue`/`rawUnit` — the write path a repository or
    /// import pipeline calls after a value is entered or corrected. Every other field is untouched.
    public static func applying(to result: LabResult, analyte: AnalyteDefinition?) -> LabResult {
        let normalized = normalize(result, analyte: analyte)
        var updated = result
        updated.canonicalValue = normalized.canonicalValue
        updated.canonicalUnit = normalized.canonicalUnit
        return updated
    }
}
