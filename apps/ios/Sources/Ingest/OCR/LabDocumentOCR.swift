import Foundation
import Vision
import CoreGraphics

// MARK: - Locale-aware decimal parsing (pipeline step 2)

/// One numeric token found while scanning a line of OCR'd text, with enough positional
/// information (`range`) for the caller to split the rest of the line into "before" (the analyte
/// label) and "after" (unit/interval/flag) around it.
struct LabOCRNumberMatch {
    let range: Range<String.Index>
    /// The exact substring recognized as the number, pre-parse — preserved even when `value` is
    /// nil, so a human reviewer always sees what was actually printed.
    let text: String
    /// nil when the token could not be parsed as a number at all — never a guessed/defaulted
    /// value standing in for a parse failure.
    let value: Double?
    /// True when the separator reading was genuinely ambiguous (see `LabOCRNumberParser.parse`).
    let wasAmbiguousDecimal: Bool
}

/// Parses lab-report numerals the way Apple's Vision OCR actually emits them: plain Latin digits
/// ("3.5"), and Eastern Arabic-Indic digits with the Arabic decimal separator ("٣٫٥") — both real
/// OCR outputs for the SAME printed value depending on whether the source lab printed Western or
/// Arabic-Indic numerals.
///
/// This codebase's existing number-handling utility, `Numerals` (`Core/Localization/
/// AppLanguage.swift`), governs the OUTPUT direction only — formatting a known `Double` for
/// on-screen display via a locale-selected `NumberFormatter` — and has no INPUT/parsing
/// counterpart to reuse; `ValueFormatter` (`App/ValueFormatter.swift`) is built on top of it for
/// the same output direction. Rather than routing OCR'd strings through `NumberFormatter`'s own
/// locale/ICU parsing (whose exact behavior for a bare Arabic-Indic-digit string depends on ICU
/// data this codebase doesn't otherwise depend on, and which the existing `Numerals` cache isn't
/// shaped to expose for parsing), this type does the one thing an OCR numeral parser actually
/// needs deterministically: map each Arabic-Indic digit and the Arabic decimal separator to their
/// Latin equivalents, then parse with `Double.init`. Both directions of BADAN's number handling
/// still agree on WHICH characters count as digits — this is not a second, divergent notion of
/// "what is a digit," just a different (input vs. output) mechanism operating on the same set.
enum LabOCRNumberParser {
    private static let arabicIndicMap: [Character: Character] = [
        "٠": "0", "١": "1", "٢": "2", "٣": "3", "٤": "4",
        "٥": "5", "٦": "6", "٧": "7", "٨": "8", "٩": "9",
    ]
    private static let arabicDecimalSeparator: Character = "\u{066B}" // ٫ ARABIC DECIMAL SEPARATOR
    private static let arabicThousandsSeparator: Character = "\u{066C}" // ٬ ARABIC THOUSANDS SEPARATOR
    private static let numericCharacters = CharacterSet(charactersIn: "0123456789٠١٢٣٤٥٦٧٨٩")
    private static let numericAndSeparatorCharacters =
        Set("0123456789٠١٢٣٤٥٦٧٨٩.,\u{066B}\u{066C}")

    /// The first plausible numeric token in `text`, expanded outward from the first digit found to
    /// capture the whole numeric run (including up to one embedded decimal/thousands separator on
    /// either side). Returns nil when `text` contains no digit at all.
    static func firstNumber(in text: String) -> LabOCRNumberMatch? {
        guard let firstDigitRange = text.rangeOfCharacter(from: numericCharacters) else { return nil }

        var start = firstDigitRange.lowerBound
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard numericAndSeparatorCharacters.contains(text[previous]) else { break }
            start = previous
        }
        var end = firstDigitRange.upperBound
        while end < text.endIndex, numericAndSeparatorCharacters.contains(text[end]) {
            end = text.index(after: end)
        }

        // Trim a leading/trailing separator that isn't actually sitting between two digits (a
        // sentence's trailing period, a label's leading comma) — the expansion above is
        // deliberately greedy and relies on this trim to land on a clean token.
        var token = String(text[start..<end])
        while let last = token.last, !last.isNumber { token.removeLast() }
        while let first = token.first, !first.isNumber { token.removeFirst() }
        guard !token.isEmpty else { return nil }

        let (value, ambiguous) = parse(token)
        return LabOCRNumberMatch(range: start..<end, text: token, value: value, wasAmbiguousDecimal: ambiguous)
    }

    /// Returns the parsed value (nil if the token cannot be read as a number at all) and whether
    /// the separator reading was ambiguous. A bare comma with no dot present is genuinely
    /// ambiguous — "3,5" reads as 3.5 under a European decimal convention but as three thousand
    /// five hundred under an English thousands-grouping convention, and nothing in an isolated
    /// OCR'd token disambiguates the two. This parser resolves that case as a DECIMAL mark
    /// (documented MVP limitation: lab values are far more often small decimals than
    /// four-digit-plus counts) and reports the ambiguity via `wasAmbiguousDecimal` so the review UI
    /// can flag the guess rather than presenting it as fact — never blocking the import either way.
    private static func parse(_ rawToken: String) -> (Double?, Bool) {
        var token = rawToken
        if token.contains(where: { arabicIndicMap[$0] != nil }) {
            token = String(token.map { arabicIndicMap[$0] ?? $0 })
        }
        token = token.replacingOccurrences(of: String(arabicThousandsSeparator), with: "")
        token = token.replacingOccurrences(of: String(arabicDecimalSeparator), with: ".")

        let ambiguous = token.contains(",") && !token.contains(".")
        if ambiguous {
            token = token.replacingOccurrences(of: ",", with: ".")
        } else {
            token = token.replacingOccurrences(of: ",", with: "")
        }
        return (Double(token), ambiguous)
    }
}

// MARK: - Comparator recognition (pipeline step 3)

enum LabOCRComparatorParser {
    /// Recognizes a comparator immediately preceding `range` in `line` — including the ASCII
    /// approximations Vision's text recognizer frequently yields for "≤"/"≥" ("<=", ">=") instead
    /// of the single Unicode codepoint.
    static func recognize(in line: String, beforeValueAt range: Range<String.Index>) -> OCRComparator? {
        let prefix = String(line[line.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        if prefix.hasSuffix("<=") || prefix.hasSuffix("≤") { return .lessThanOrEqual }
        if prefix.hasSuffix(">=") || prefix.hasSuffix("≥") { return .greaterThanOrEqual }
        if prefix.hasSuffix("<") { return .lessThan }
        if prefix.hasSuffix(">") { return .greaterThan }
        return nil
    }
}

// MARK: - Candidate analyte-name matching (pipeline step 4)

/// Fuzzy/substring matcher for candidate analyte names against `analytes.json`'s bilingual
/// dictionary.
///
/// MVP LIMITATION, stated plainly: this is a case-insensitive substring match against each
/// dictionary entry's English/Arabic display name (and any aliases) — NOT a clinical-grade fuzzy
/// matcher (no edit distance, no LOINC lookup, no tokenization). A near-miss OCR reading of an
/// analyte name (one wrong character, a merged/split word) may fail to match and fall through to
/// `.unrecognized`. That failure mode is CORRECT and SAFE per LAB-06: an unrecognized analyte
/// becomes a first-class free-text row, never a blocked import and never a wrong dictionary entry
/// silently substituted for what the source actually printed.
///
/// `analytes.json` is owned by the parallel Domain/Labs lane (`AnalyteDefinition` in
/// `LabModels.swift`) and does not exist in this working tree as of this slice —
/// `loadFromBundle()` returns nil rather than throwing when the file is absent, so this whole
/// pipeline runs today with every candidate simply reading as `.unrecognized`, exactly as it will
/// keep doing for any marker the dictionary genuinely doesn't know once the file lands.
public struct AnalyteNameMatcher {
    private struct Entry { let id: String; let lowercasedNames: [String] }
    private let entries: [Entry]

    public init(entries: [(id: String, names: [String])]) {
        self.entries = entries.map { Entry(id: $0.id, lowercasedNames: $0.names.map { $0.lowercased() }) }
    }

    /// Loads `analytes.json` from `bundle` if present. Expected shape (matching this codebase's
    /// existing bilingual-dictionary convention — `behaviors.json`/`symptoms.json`):
    /// `{"analytes": [{"id": "...", "nameEn": "...", "nameAr": "...", "aliases": ["..."]}]}`.
    /// Any row missing `id` or carrying no usable name is skipped rather than failing the whole
    /// load — a malformed dictionary entry must never take down analyte matching for every other
    /// entry.
    public static func loadFromBundle(_ bundle: Bundle = .main) -> AnalyteNameMatcher? {
        guard let url = bundle.url(forResource: "analytes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let analytes = json["analytes"] as? [[String: Any]]
        else { return nil }

        let entries: [(id: String, names: [String])] = analytes.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            var names: [String] = []
            if let en = row["nameEn"] as? String, !en.isEmpty { names.append(en) }
            if let ar = row["nameAr"] as? String, !ar.isEmpty { names.append(ar) }
            if let aliases = row["aliases"] as? [String] { names.append(contentsOf: aliases.filter { !$0.isEmpty }) }
            return names.isEmpty ? nil : (id, names)
        }
        guard !entries.isEmpty else { return nil }
        return AnalyteNameMatcher(entries: entries)
    }

    public func match(_ candidateLabel: String) -> OCRAnalyteMatch {
        let needle = candidateLabel.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .unrecognized }
        for entry in entries {
            for name in entry.lowercasedNames where !name.isEmpty {
                if needle.contains(name) || name.contains(needle) { return .dictionary(analyteId: entry.id) }
            }
        }
        return .unrecognized
    }
}

// MARK: - Source-printed interval / flag capture (best-effort MVP; not one of the pipeline's
// required steps, but part of the shape `OCRFieldExtraction` needs to honor the four-concept law)

enum LabOCRRemainderParser {
    /// Matches "70-99", "70 - 99", "(70-99)", "70–99" (en dash) — the printed reference interval,
    /// captured only when the source's own line actually looks like it printed one immediately
    /// after the value. Never a looked-up or invented range (four-concept law, concept 1).
    static func interval(in remainder: String) -> String? {
        guard let match = remainder.range(
            of: #"\(?\s*[0-9٠-٩]+([.,][0-9٠-٩]+)?\s*[-–]\s*[0-9٠-٩]+([.,][0-9٠-٩]+)?\s*\)?"#,
            options: .regularExpression
        ) else { return nil }
        return String(remainder[match]).trimmingCharacters(in: CharacterSet(charactersIn: "() "))
    }

    /// A short isolated token from the closed set of flag SPELLINGS a lab actually prints ("H",
    /// "L", "Critical", …) — never a wider guess, because the source-flag concept (concept 2) is
    /// only ever "what the lab itself printed"; matching anything outside this vocabulary would
    /// put words in the lab's mouth.
    private static let flagVocabulary: Set<String> =
        ["H", "L", "HH", "LL", "A", "AB", "CRITICAL", "ABNORMAL", "مرتفع", "منخفض", "حرج"]

    static func flag(in remainder: String) -> String? {
        for word in remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let token = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]*."))
            if flagVocabulary.contains(token.uppercased()) || flagVocabulary.contains(token) { return token }
        }
        return nil
    }

    /// The first remaining whitespace-delimited token once the interval/flag substrings (if any)
    /// are stripped out — units come immediately after the value on a source lab's line, before
    /// the interval and flag. Free-text, never validated against a closed unit list: an
    /// unrecognized unit must display exactly as printed, never be silently dropped.
    static func unit(in remainder: String) -> String? {
        var stripped = remainder
        if let interval = interval(in: remainder) { stripped = stripped.replacingOccurrences(of: interval, with: " ") }
        if let flag = flag(in: stripped) { stripped = stripped.replacingOccurrences(of: flag, with: " ") }
        let tokens = stripped.split(whereSeparator: { " \t()".contains($0) })
        return tokens.first.map(String.init)
    }
}

// MARK: - The pipeline (LAB-06)

/// On-device OCR pipeline for lab-report PDFs/photos (LAB-06). Uses Apple's Vision framework
/// exclusively (`VNRecognizeTextRequest`) and NEVER makes a network call — this is the
/// load-bearing distinction between what EPIC-41's MVP may ship (on-device OCR) and what is gated
/// behind A19 (any cloud/hosted OCR service, per `docs/HANDOFF.md`'s do-not-build list).
///
/// Implements, of the plan's fuller pipeline: (1) page-by-page text recognition per configured
/// language, (2) locale-aware decimal parsing (`LabOCRNumberParser`), (3) comparator-symbol
/// recognition (`LabOCRComparatorParser`), (4) candidate analyte-name matching against
/// `analytes.json` when available (`AnalyteNameMatcher`), (5) confidence scoring per extracted
/// field, and (6) bounding-box capture per recognized field.
///
/// EVERY extraction defaults `reviewState = .needsReview` (`OCRFieldExtraction`'s own default) —
/// this pipeline never auto-commits a value as verified. A page whose `VNImageRequestHandler`
/// throws never drops the rest of the document: `run(sourceDocumentId:pages:)` records an
/// `OCRPageError` for that page and continues with the next one, and even a run where EVERY page
/// fails (`.failed`) still returns a normal `OCRExtraction` value — the caller stores the
/// `SourceDocument` regardless (LAB-06's own "document stores even when extraction fails").
public final class LabDocumentOCR {
    /// Frozen pipeline identity, mirroring `BaselineEngine.baselineAlgorithm`'s own pattern (I2): a
    /// change to recognition or matching behavior is a version bump, never a silent behavior
    /// change under the same stored identity.
    public static let engineVersion = "lab_ocr.vision_v1"

    /// Below this per-line Vision confidence, a value/analyte match is flagged
    /// `.lowConfidenceRecognition` for the review UI rather than presented as a clean read.
    static let lowConfidenceThreshold: Float = 0.5

    public let recognitionLanguages: [String]
    private let clock: Clock
    private let analyteDictionary: AnalyteNameMatcher?

    public init(
        recognitionLanguages: [String] = ["en-US", "ar-SA"],
        clock: Clock = SystemClock(),
        analyteDictionary: AnalyteNameMatcher? = AnalyteNameMatcher.loadFromBundle()
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.clock = clock
        self.analyteDictionary = analyteDictionary
    }

    /// Runs the pipeline over one document's already-rasterized pages. Rasterizing a PDF into
    /// per-page `CGImage`s is deliberately kept OUT of this type (a caller's job, e.g. via
    /// PDFKit) — Vision's own input is an image regardless of source, and keeping that seam here
    /// means this pipeline is testable against a plain synthetic image with no PDF fixture
    /// required at all (see `LabDocumentOCRTests`).
    public func run(sourceDocumentId: String, pages: [CGImage]) -> OCRExtraction {
        let startedAt = clock.now()
        var rawLines: [OCRTextLine] = []
        var fields: [OCRFieldExtraction] = []
        var pageErrors: [OCRPageError] = []

        for (pageIndex, image) in pages.enumerated() {
            do {
                let lines = try recognizeText(in: image, pageIndex: pageIndex)
                rawLines.append(contentsOf: lines)
                fields.append(contentsOf: lines.compactMap { extractField(from: $0) })
            } catch {
                // Sanitized, value-free message (matches `export_runs.error_detail`'s own rule) —
                // a page-recognition failure never smuggles anything from the document into a
                // diagnostic string.
                pageErrors.append(OCRPageError(pageIndex: pageIndex, message: "text recognition failed on this page"))
            }
        }

        let status: OCRRunStatus
        if pages.isEmpty || pageErrors.count == pages.count {
            status = .failed
        } else if pageErrors.isEmpty {
            status = .completed
        } else {
            status = .completedWithErrors
        }

        return OCRExtraction(
            id: ULID.newID(clock: clock),
            sourceDocumentId: sourceDocumentId,
            engineVersion: Self.engineVersion,
            recognitionLanguages: recognitionLanguages,
            startedAt: startedAt,
            finishedAt: clock.now(),
            pageCount: pages.count,
            status: status,
            rawLines: rawLines,
            fields: fields,
            pageErrors: pageErrors)
    }

    // MARK: - Step 1: text recognition

    private func recognizeText(in image: CGImage, pageIndex: Int) throws -> [OCRTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages
        // `VNRecognizeTextRequestRevision3` (the newest revision this SDK ships, and comfortably
        // within this app's iOS 17 deployment target — it has required iOS 16 since introduction)
        // is set explicitly per this slice's own brief, rather than left to whatever Vision
        // resolves as its default for an unset `revision`.
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observations = request.results else { return [] }

        return observations.compactMap { observation -> OCRTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRTextLine(
                pageIndex: pageIndex,
                text: candidate.string,
                boundingBox: OCRBoundingBox(x: box.minX, y: box.minY, width: box.width, height: box.height),
                confidence: Double(candidate.confidence))
        }
    }

    // MARK: - Steps 2-6: per-line field extraction

    /// One line becomes one candidate field row iff it contains a plausible value AND a
    /// non-empty analyte label before it. A line with no number (a page header, a lab's address)
    /// or no label before its first number (a lone page number) simply yields no field — this is
    /// `compactMap`'s ordinary skip, not a dropped/blocked page: every OTHER line on the same page
    /// is still processed independently (LAB-06's "one bad/unmatched line never blocks the rest").
    private func extractField(from line: OCRTextLine) -> OCRFieldExtraction? {
        guard let valueMatch = LabOCRNumberParser.firstNumber(in: line.text) else { return nil }
        let beforeValue = String(line.text[line.text.startIndex..<valueMatch.range.lowerBound])
        let comparator = LabOCRComparatorParser.recognize(in: line.text, beforeValueAt: valueMatch.range)
        let analyteLabel = Self.strippingTrailingComparator(from: beforeValue, matched: comparator)
            .trimmingCharacters(in: .whitespaces)
        guard !analyteLabel.isEmpty else { return nil }

        let remainder = String(line.text[valueMatch.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        let match = analyteDictionary?.match(analyteLabel) ?? .unrecognized

        var ambiguity: [OCRAmbiguityFlag] = []
        if valueMatch.wasAmbiguousDecimal { ambiguity.append(.localeAmbiguousDecimal) }
        if Float(line.confidence) < Self.lowConfidenceThreshold { ambiguity.append(.lowConfidenceRecognition) }
        if case .unrecognized = match {
            ambiguity.append(analyteDictionary == nil ? .noAnalyteDictionaryAvailable : .lowConfidenceAnalyteMatch)
        }

        return OCRFieldExtraction(
            id: ULID.newID(clock: clock),
            pageIndex: line.pageIndex,
            analyteLabelRaw: analyteLabel,
            analyteMatch: match,
            analyteBoundingBox: line.boundingBox,
            analyteConfidence: line.confidence,
            comparator: comparator,
            valueText: valueMatch.text,
            parsedValue: valueMatch.value,
            valueBoundingBox: line.boundingBox,
            valueConfidence: line.confidence,
            unitTextRaw: LabOCRRemainderParser.unit(in: remainder),
            unitBoundingBox: line.boundingBox,
            sourceIntervalTextRaw: LabOCRRemainderParser.interval(in: remainder),
            sourceIntervalBoundingBox: line.boundingBox,
            sourceFlagTextRaw: LabOCRRemainderParser.flag(in: remainder),
            sourceFlagBoundingBox: line.boundingBox,
            ambiguityFlags: ambiguity,
            reviewState: .needsReview)
    }

    /// Removes exactly one trailing comparator spelling from the analyte-label side of a line, so
    /// `"hs-CRP <"` reads as the label `"hs-CRP"` rather than carrying the comparator symbol into
    /// what is meant to be a bare marker name. Accepts both the literal Unicode symbol and the
    /// ASCII approximation Vision commonly yields for "≤"/"≥", matching
    /// `LabOCRComparatorParser.recognize`'s own tolerance.
    private static func strippingTrailingComparator(from text: String, matched: OCRComparator?) -> String {
        guard let matched else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let candidates: [String]
        switch matched {
        case .lessThanOrEqual: candidates = ["<=", "≤"]
        case .greaterThanOrEqual: candidates = [">=", "≥"]
        case .lessThan: candidates = ["<"]
        case .greaterThan: candidates = [">"]
        }
        for candidate in candidates where trimmed.hasSuffix(candidate) {
            return String(trimmed.dropLast(candidate.count))
        }
        return trimmed
    }
}
