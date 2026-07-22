import Foundation

// MARK: - Lab notebook OCR pipeline: typed output (EPIC-41, Phase 3E MVP, LAB-06)
//
// The typed result `LabDocumentOCR` (Ingest/OCR/) produces. This is deliberately a pure data
// shape with no storage/UI logic of its own: a parallel lane owns the side-by-side review UI that
// renders one card per `OCRFieldExtraction`, and this file's whole job is to give that UI exactly
// the shape it needs (per-field confidence, ambiguity flags, bounding boxes) rather than a single
// row-level summary that would hide which specific field needs a human's eyes.

/// Confidence some pipeline stage has in one extracted field, 0...1. Kept as `Double` (not
/// Vision's own `Float`) to match this codebase's numeric convention elsewhere in the domain layer
/// (`BaselineComputation`, `DerivedTrend`, etc. are all `Double`).
public typealias OCRConfidence = Double

/// A recognized text region's location, in Vision's own normalized UNIT-SQUARE coordinate system
/// (origin bottom-left, both axes 0...1) — so the review UI's side-by-side highlight feature can
/// scale a box onto whatever size it renders the source page image at, without this type knowing
/// or caring about pixel dimensions.
public struct OCRBoundingBox: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One raw recognized line of text, before any field-level interpretation — pipeline step 1
/// (page-by-page text recognition). Kept on `OCRExtraction` in full (not discarded once fields are
/// extracted) so a totally-unmatched line is still visible to a human reviewer rather than
/// silently vanishing the moment this pipeline's own heuristics fail to make sense of it.
public struct OCRTextLine: Codable, Hashable, Sendable {
    public var pageIndex: Int
    public var text: String
    public var boundingBox: OCRBoundingBox
    public var confidence: OCRConfidence

    public init(pageIndex: Int, text: String, boundingBox: OCRBoundingBox, confidence: OCRConfidence) {
        self.pageIndex = pageIndex
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// A comparator symbol captured alongside a value (pipeline step 3) — "<0.1", "≥1000". There is
/// deliberately no `.equal` case: `OCRFieldExtraction.comparator == nil` already means "no
/// comparator seen, this is an exact value," and adding an `.equal` case would just be a second,
/// redundant way to say the same thing.
public enum OCRComparator: String, Codable, Hashable, Sendable, CaseIterable {
    case lessThan = "<"
    case lessThanOrEqual = "≤"
    case greaterThan = ">"
    case greaterThanOrEqual = "≥"
}

/// Where a candidate analyte NAME landed relative to `analytes.json`'s bilingual dictionary
/// (pipeline step 4). `.unrecognized` is an equally first-class outcome, never a failure state:
/// LAB-06 requires an unrecognized marker to become a free-text candidate row, not a dropped one,
/// and this case is exactly what a reader checks to render "not in our dictionary yet" without
/// that meaning extraction itself failed. The raw OCR'd label survives on
/// `OCRFieldExtraction.analyteLabelRaw` regardless of which case this is.
public enum OCRAnalyteMatch: Codable, Hashable, Sendable {
    /// Matched a dictionary entry by id — fuzzy/substring match (MVP limitation, see
    /// `AnalyteNameMatcher`'s own doc for why and what a false negative looks like).
    case dictionary(analyteId: String)
    /// No dictionary entry matched — including the case where no dictionary was available to
    /// match against at all (`analytes.json` absent from the bundle).
    case unrecognized
}

/// A field-level uncertainty this pipeline itself detected, surfaced to the review UI as a reason
/// to look twice at THIS specific field rather than the row as a whole.
public enum OCRAmbiguityFlag: String, Codable, Hashable, Sendable, CaseIterable {
    case lowConfidenceRecognition
    case lowConfidenceAnalyteMatch
    /// No dictionary was available to match against at all — distinct from a dictionary
    /// existing and genuinely not recognizing this marker.
    case noAnalyteDictionaryAvailable
    /// A bare comma with no dot present is genuinely ambiguous (a European decimal mark vs. a
    /// thousands grouping mark) — see `LabOCRNumberParser`'s own doc.
    case localeAmbiguousDecimal
}

/// Human-review state every extraction ships with. `.needsReview` is the ONLY value
/// `LabDocumentOCR` itself ever produces (LAB-06: this pipeline never auto-commits a value as
/// verified — a human always confirms). The other cases exist so this type can describe a result
/// AFTER a human (or a future structured-import path) has acted on it, reusing the same
/// vocabulary `LabModels.swift`'s `LabReviewState` already establishes for the domain layer, rather
/// than a second, parallel enum this pipeline would own alone.
public enum OCRReviewState: String, Codable, Hashable, Sendable, CaseIterable {
    case needsReview = "needs_review"
    case userEntered = "user_entered"
    case corrected
    case conflictFlagged = "conflict_flagged"
}

/// One candidate result row extracted from a source document — the unit the review UI renders one
/// side-by-side correction card for. Confidence, ambiguity flags, and bounding boxes are captured
/// PER FIELD (analyte name / value / unit / source interval / source flag), not once per row,
/// because a page can OCR a marker's name perfectly while its printed range is smudged —
/// collapsing that into one row-level number would hide exactly the case the review UI exists to
/// surface (pipeline steps 5 and 6).
///
/// `sourceIntervalTextRaw`/`sourceFlagTextRaw` exist so this type can honor the four-concept
/// reference-range law's first two concepts end to end: this pipeline only ever fills them in with
/// what the source line actually appears to print, never a looked-up or invented range — matching
/// `ReferenceRange`'s own "present only when the source printed one" rule (`LabModels.swift`).
public struct OCRFieldExtraction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var pageIndex: Int

    // MARK: Analyte identity (pipeline step 4)
    public var analyteLabelRaw: String
    public var analyteMatch: OCRAnalyteMatch
    public var analyteBoundingBox: OCRBoundingBox?
    public var analyteConfidence: OCRConfidence?

    // MARK: Value (pipeline steps 2 + 3)
    public var comparator: OCRComparator?
    /// The exact OCR'd numeral substring, pre-parse — preserved even when `parsedValue` is nil,
    /// so a human reviewer sees what was actually printed rather than nothing at all.
    public var valueText: String?
    /// nil when the token could not be parsed as a number at all — NEVER a guessed/defaulted
    /// value standing in for a parse failure.
    public var parsedValue: Double?
    public var valueBoundingBox: OCRBoundingBox?
    public var valueConfidence: OCRConfidence?

    // MARK: Unit
    public var unitTextRaw: String?
    public var unitBoundingBox: OCRBoundingBox?

    // MARK: Source-printed reference interval + flag (four-concept law, concepts 1 + 2 — best-
    // effort MVP capture; a parallel lane's `ReferenceRange`/review UI decides what to do with
    // whatever this pipeline manages to read here, including nothing at all)
    public var sourceIntervalTextRaw: String?
    public var sourceIntervalBoundingBox: OCRBoundingBox?
    public var sourceFlagTextRaw: String?
    public var sourceFlagBoundingBox: OCRBoundingBox?

    public var ambiguityFlags: [OCRAmbiguityFlag]
    /// Always `.needsReview` from `LabDocumentOCR` itself — see the type's own doc.
    public var reviewState: OCRReviewState

    public init(
        id: String,
        pageIndex: Int,
        analyteLabelRaw: String,
        analyteMatch: OCRAnalyteMatch,
        analyteBoundingBox: OCRBoundingBox? = nil,
        analyteConfidence: OCRConfidence? = nil,
        comparator: OCRComparator? = nil,
        valueText: String? = nil,
        parsedValue: Double? = nil,
        valueBoundingBox: OCRBoundingBox? = nil,
        valueConfidence: OCRConfidence? = nil,
        unitTextRaw: String? = nil,
        unitBoundingBox: OCRBoundingBox? = nil,
        sourceIntervalTextRaw: String? = nil,
        sourceIntervalBoundingBox: OCRBoundingBox? = nil,
        sourceFlagTextRaw: String? = nil,
        sourceFlagBoundingBox: OCRBoundingBox? = nil,
        ambiguityFlags: [OCRAmbiguityFlag] = [],
        reviewState: OCRReviewState = .needsReview
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.analyteLabelRaw = analyteLabelRaw
        self.analyteMatch = analyteMatch
        self.analyteBoundingBox = analyteBoundingBox
        self.analyteConfidence = analyteConfidence
        self.comparator = comparator
        self.valueText = valueText
        self.parsedValue = parsedValue
        self.valueBoundingBox = valueBoundingBox
        self.valueConfidence = valueConfidence
        self.unitTextRaw = unitTextRaw
        self.unitBoundingBox = unitBoundingBox
        self.sourceIntervalTextRaw = sourceIntervalTextRaw
        self.sourceIntervalBoundingBox = sourceIntervalBoundingBox
        self.sourceFlagTextRaw = sourceFlagTextRaw
        self.sourceFlagBoundingBox = sourceFlagBoundingBox
        self.ambiguityFlags = ambiguityFlags
        self.reviewState = reviewState
    }
}

/// A non-fatal per-page recognition failure. LAB-06's own requirement is that ONE bad page never
/// drops the rest of the document's fields, and that a totally-failed OCR run still leaves the
/// `SourceDocument` stored and browsable — this case is how that "still failed on this page" fact
/// is recorded instead of being silently swallowed. `message` is sanitized, value-free text (matches
/// this codebase's `background_runs.work_done`/`export_runs.error_detail` convention of never
/// smuggling a health value into a diagnostic string).
public struct OCRPageError: Codable, Hashable, Sendable {
    public var pageIndex: Int
    public var message: String

    public init(pageIndex: Int, message: String) {
        self.pageIndex = pageIndex
        self.message = message
    }
}

/// The outcome of one whole-document OCR run.
public enum OCRRunStatus: String, Codable, Hashable, Sendable, CaseIterable {
    /// Every page was processed without a page-level error (pages may still have yielded zero
    /// fields — a blank or non-lab page is not itself an error).
    case completed
    /// At least one page processed successfully, but at least one other page errored.
    case completedWithErrors
    /// No page could be processed at all. The `SourceDocument` is still stored and browsable
    /// (LAB-06) — a `.failed` `OCRExtraction` is not an exception, it is this pipeline's normal,
    /// typed way of saying "nothing to review yet, try again or enter this one by hand."
    case failed
}

/// The whole-document OCR run — one per `SourceDocument`. `engineVersion` is a frozen algorithm
/// identity, matching the convention `BaselineEngine.baselineAlgorithm`/
/// `ReferenceRangeEngine`'s own algorithm-version fields already establish: a change to
/// recognition or matching behavior is a version bump, never a silent behavior change under the
/// same stored identity, so a saved extraction always says what produced it.
public struct OCRExtraction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sourceDocumentId: String
    public var engineVersion: String
    public var recognitionLanguages: [String]
    public var startedAt: Date
    public var finishedAt: Date
    public var pageCount: Int
    public var status: OCRRunStatus
    public var rawLines: [OCRTextLine]
    public var fields: [OCRFieldExtraction]
    public var pageErrors: [OCRPageError]

    public init(
        id: String,
        sourceDocumentId: String,
        engineVersion: String,
        recognitionLanguages: [String],
        startedAt: Date,
        finishedAt: Date,
        pageCount: Int,
        status: OCRRunStatus,
        rawLines: [OCRTextLine],
        fields: [OCRFieldExtraction],
        pageErrors: [OCRPageError]
    ) {
        self.id = id
        self.sourceDocumentId = sourceDocumentId
        self.engineVersion = engineVersion
        self.recognitionLanguages = recognitionLanguages
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.pageCount = pageCount
        self.status = status
        self.rawLines = rawLines
        self.fields = fields
        self.pageErrors = pageErrors
    }
}
