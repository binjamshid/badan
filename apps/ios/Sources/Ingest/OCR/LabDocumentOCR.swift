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
/// LIMITATION, stated plainly: name matching here is exact-then-substring against each dictionary
/// entry's English/Arabic display name (and any aliases) — NOT a clinical-grade fuzzy matcher (no
/// edit distance, no tokenization). A near-miss OCR reading of an analyte name (one wrong
/// character, a merged/split word) may fail to match and fall through to `.unrecognized`. That
/// failure mode is CORRECT and SAFE per LAB-06: an unrecognized analyte becomes a first-class
/// free-text row, never a blocked import and never a wrong dictionary entry silently substituted
/// for what the source actually printed.
///
/// A LOINC code, when the caller has one, is consulted BEFORE any name. No caller has one today —
/// OCR and hand entry read a printed page, which carries a marker's name and not its code — so
/// that tier is dormant rather than dead: it exists for a source that supplies codes (a FHIR file
/// a portal exported, say), and costs nothing while none does.
///
/// `analytes.json` is owned by the parallel Domain/Labs lane (`AnalyteDefinition` in
/// `LabModels.swift`) and does not exist in this working tree as of this slice —
/// `loadFromBundle()` returns nil rather than throwing when the file is absent, so this whole
/// pipeline runs today with every candidate simply reading as `.unrecognized`, exactly as it will
/// keep doing for any marker the dictionary genuinely doesn't know once the file lands.
public struct AnalyteNameMatcher {
    private struct Entry { let id: String; let loincCode: String?; let normalizedNames: [String] }
    private let entries: [Entry]

    public init(entries: [(id: String, names: [String])]) {
        self.init(entries: entries.map { (id: $0.id, loincCode: nil, names: $0.names) })
    }

    public init(entries: [(id: String, loincCode: String?, names: [String])]) {
        self.entries = entries.map {
            Entry(id: $0.id,
                  loincCode: $0.loincCode.map(Self.normalizedCode).flatMap { $0.isEmpty ? nil : $0 },
                  normalizedNames: $0.names.map(Self.normalized).filter { !$0.isEmpty })
        }
    }

    /// Case-, diacritic- and whitespace-insensitive. Diacritic folding matters in both languages
    /// here: it absorbs Arabic tashkeel, which a lab may or may not print.
    private static func normalized(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func normalizedCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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

        let entries: [(id: String, loincCode: String?, names: [String])] = analytes.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            var names: [String] = []
            if let en = row["nameEn"] as? String, !en.isEmpty { names.append(en) }
            if let ar = row["nameAr"] as? String, !ar.isEmpty { names.append(ar) }
            if let aliases = row["aliases"] as? [String] { names.append(contentsOf: aliases.filter { !$0.isEmpty }) }
            return names.isEmpty ? nil : (id, row["loincCode"] as? String, names)
        }
        guard !entries.isEmpty else { return nil }
        return AnalyteNameMatcher(entries: entries)
    }

    /// Resolves a printed marker name (and, when the caller has one, its LOINC code) to a
    /// dictionary id.
    ///
    /// Three tiers, in this order, because a substring hit alone is not evidence of identity:
    ///
    /// 1. **LOINC code.** The provider's own identifier for the marker. Unambiguous where present.
    /// 2. **Exact normalized name.** "Hemoglobin A1c" IS the `hba1c` entry, whatever else it also
    ///    contains as a substring.
    /// 3. **Closest-length substring**, either direction, ties broken by dictionary order.
    ///
    /// Tier 3's ranking is the part worth reading twice. The previous implementation returned the
    /// FIRST substring hit in dictionary order, which filed every "Hemoglobin A1c" under
    /// `hemoglobin` — a wrong marker on a medical record, since `hemoglobin` precedes `hba1c` in
    /// `analytes.json`. Ranking by the smaller length difference fixes that (`|14−14| = 0` beats
    /// `|14−10| = 4`) and is deliberately NOT "longest name wins", which would break the mirror
    /// case: a bare "LDL" printed by a lab must resolve to `ldl` (`|3−15|`), not to the longer
    /// `ldl_calculated` (`|3−28|`).
    ///
    /// This never widens what is recognized — a label that matched nothing before still matches
    /// nothing, and `.unrecognized` remains a first-class, safe outcome. It only changes WHICH
    /// entry wins among several that already matched.
    public func match(_ candidateLabel: String, loincCode: String? = nil) -> OCRAnalyteMatch {
        if let code = loincCode.map(Self.normalizedCode), !code.isEmpty,
           let entry = entries.first(where: { $0.loincCode == code }) {
            return .dictionary(analyteId: entry.id)
        }

        let needle = Self.normalized(candidateLabel)
        guard !needle.isEmpty else { return .unrecognized }

        if let entry = entries.first(where: { $0.normalizedNames.contains(needle) }) {
            return .dictionary(analyteId: entry.id)
        }

        var best: (id: String, distance: Int)?
        for entry in entries {
            for name in entry.normalizedNames where needle.contains(name) || name.contains(needle) {
                let distance = abs(name.count - needle.count)
                if best == nil || distance < best!.distance { best = (entry.id, distance) }
            }
        }
        if let best { return .dictionary(analyteId: best.id) }
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

    /// The first token after the value that is neither the printed interval nor the printed flag —
    /// units come immediately after the value on a source lab's line, before the interval and flag.
    /// Free-text, never validated against a closed unit list: an unrecognized unit must display
    /// exactly as printed, never be silently dropped.
    ///
    /// **Tokenized, not substring-replaced, and that distinction is load-bearing.** This previously
    /// deleted the flag text wherever it appeared with `replacingOccurrences` — so a row reading
    /// `21 ng/mL (30-100) L` had its flag `L` removed from the FIRST place an `L` occurs, which is
    /// inside the unit, and the unit was recorded as `ng/m`. Every unit a lab actually prints for a
    /// flagged result is affected: mL, mmol/L, mIU/L, µg/L. A corrupted unit is worse than a
    /// missing one, because it looks like a reading of the page rather than a bug — observed on a
    /// real report on 2026-08-01. Matching the flag as a WHOLE token cannot reach inside a unit.
    static func unit(in remainder: String) -> String? {
        let printedFlag = flag(in: remainder)
        var scanned = remainder
        // The interval is removed by RANGE, so an interval-shaped run elsewhere on the line is left
        // alone — same discipline, same reason.
        if let interval = interval(in: remainder), let range = scanned.range(of: interval) {
            scanned.replaceSubrange(range, with: " ")
        }
        for token in scanned.split(whereSeparator: { " \t()[]".contains($0) }) {
            let text = String(token)
            let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: "()[]*."))
            if let printedFlag, bare == printedFlag { continue }
            return text
        }
        return nil
    }
}

// MARK: - Row assembly (pipeline step 1b) — putting a printed row back together

/// Rebuilds printed table rows out of the fragments Vision actually returns.
///
/// **The problem this exists to solve, verified against a real column-aligned lab PDF on
/// 2026-08-01:** every parser below assumes one printed row arrives as one `OCRTextLine` carrying
/// label, value, unit, interval and flag. `VNRecognizeTextRequest` does not promise that and
/// frequently does the opposite — on a report whose columns are separated by wide whitespace it
/// returns each COLUMN as its own observation, so
///
/// ```text
/// Ferritin        32 ng/mL     (30-400)
/// ```
///
/// arrives as three unrelated lines. Fed to `extractField` one at a time, the label column yields
/// nothing (no number), and the interval column yields a field whose "marker name" is `(` and whose
/// unit is `-400`. That is not a wrong reading of the report — it is a reading of a fragment as if
/// it were a row.
///
/// **The fix is geometric, not textual.** Vision already reports where each fragment sits, so
/// fragments that share a horizontal band are the same printed row and are joined back together.
/// Nothing here interprets content; it only decides what belongs on a line before the existing
/// parsers see it.
///
/// **This never discards a fragment.** Every input ends up in exactly one output row, and
/// `OCRExtraction.rawLines` keeps Vision's own observations untouched — the stored artifact is
/// still what the recognizer said, not what this assembler made of it.
enum LabOCRRowAssembler {
    /// Two fragments belong to the same row when their vertical extents overlap by at least this
    /// fraction of the shorter one. 0.5 is deliberately loose: printed rows are near-perfectly
    /// aligned, so the realistic failure is a superscript or a slightly taller glyph run being
    /// split off, not two genuinely different rows being merged. A merged pair still lands in the
    /// review UI as one editable candidate; a split pair produces the junk row described above.
    static let overlapThreshold = 0.5

    static func rows(from fragments: [OCRTextLine]) -> [OCRTextLine] {
        guard fragments.count > 1 else { return fragments }

        // Vision's normalized space is y-up (0 at the bottom of the page), so descending midY is
        // top-to-bottom reading order.
        let ordered = fragments.sorted { midY($0) > midY($1) }

        var grouped: [[OCRTextLine]] = []
        for fragment in ordered {
            // Compared against the row's ANCHOR (its first, topmost fragment) rather than the
            // running union: a union grows taller with every member, and a tall-enough band starts
            // absorbing the row beneath it. The anchor's height stays put.
            if let anchor = grouped.last?.first, overlapRatio(anchor, fragment) >= overlapThreshold {
                grouped[grouped.count - 1].append(fragment)
            } else {
                grouped.append([fragment])
            }
        }

        return grouped.compactMap(join)
    }

    private static func midY(_ line: OCRTextLine) -> Double { line.boundingBox.y + line.boundingBox.height / 2 }

    /// Vertical overlap as a fraction of the SHORTER fragment's height — so a short unit token
    /// ("ng/mL") sitting inside a taller label's band reads as fully overlapping, which it visually
    /// is. Using the taller one would penalize exactly the pairing this needs to make.
    private static func overlapRatio(_ a: OCRTextLine, _ b: OCRTextLine) -> Double {
        let top = min(a.boundingBox.y + a.boundingBox.height, b.boundingBox.y + b.boundingBox.height)
        let bottom = max(a.boundingBox.y, b.boundingBox.y)
        let overlap = top - bottom
        guard overlap > 0 else { return 0 }
        let shorter = min(a.boundingBox.height, b.boundingBox.height)
        guard shorter > 0 else { return 0 }
        return overlap / shorter
    }

    private static func join(_ group: [OCRTextLine]) -> OCRTextLine? {
        guard let first = group.first else { return nil }
        guard group.count > 1 else { return first }

        // Reading order within the row, and it is not always left-to-right. On an Arabic report the
        // marker name sits at the RIGHT edge with its value to the left; joining by ascending x
        // would put the number first, leaving `extractField` with no label before it and dropping
        // a row that was read perfectly well. Direction is decided by which script the row's
        // LETTERS are in — digits are excluded deliberately, since Arabic-Indic numerals appear in
        // otherwise-Latin reports and a numeric column must not flip a row's direction.
        let ascending = group.sorted { $0.boundingBox.x < $1.boundingBox.x }
        let ordered = isRightToLeft(group) ? ascending.reversed().map { $0 } : ascending

        let minX = ascending.map(\.boundingBox.x).min() ?? first.boundingBox.x
        let maxX = ascending.map { $0.boundingBox.x + $0.boundingBox.width }.max() ?? first.boundingBox.x
        let minY = group.map(\.boundingBox.y).min() ?? first.boundingBox.y
        let maxY = group.map { $0.boundingBox.y + $0.boundingBox.height }.max() ?? first.boundingBox.y

        return OCRTextLine(
            pageIndex: first.pageIndex,
            text: ordered.map(\.text).joined(separator: " "),
            boundingBox: OCRBoundingBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            // The row is only as trustworthy as its least-confident fragment. Averaging would let a
            // confidently-read label hide a doubtful value, which is the one direction this must
            // not fail in — the low-confidence flag is what tells the reviewer where to look.
            confidence: group.map(\.confidence).min() ?? first.confidence)
    }

    private static func isRightToLeft(_ group: [OCRTextLine]) -> Bool {
        var arabic = 0, latin = 0
        for scalar in group.map(\.text).joined().unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            if isArabicLetter(scalar) { arabic += 1 } else { latin += 1 }
        }
        return arabic > latin
    }

    private static func isArabicLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0620...0x064A, 0x066E...0x06D3, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }
}

// MARK: - Non-marker row suppression (pipeline step 1c)

/// Rejects rows that a lab printed for the reader's orientation rather than as a result: page
/// markers ("Report page 2 of 3") and bare dates ("Collected 2026-03-14"). Both contain a number
/// preceded by a word, which is all `extractField` requires, so both were being offered as markers
/// to confirm — "Report page = 2 of" and "Collected = 2026 (03-14)".
///
/// **Deliberately narrow, and it stays narrow.** This suppresses only what it can positively
/// identify as page furniture; it is not a general "does this look like a marker?" classifier, and
/// nothing here is allowed to grow into one. LAB-06's rule — an unrecognized marker becomes a
/// first-class free-text row, never a blocked import — governs everything else. A suppressed row
/// costs the user nothing they can't recover: the source page is stored and shown, and hand entry
/// is one tap away on the same screen.
enum LabOCRRowFilter {
    private static let pagePatterns = [
        #"(?i)page\s*[0-9٠-٩]+\s*(of|/)\s*[0-9٠-٩]+"#,
        #"صفحة\s*[0-9٠-٩]+"#,
    ]

    /// Numeric date shapes only — 2026-03-14, 14/03/2026, 14-3-26 — plus a clock time. A month
    /// NAME is not matched on purpose: "Vitamin D3 25-OH" and friends make word-adjacent matching
    /// risky, and a spelled-out month is rare on the value line of a lab table.
    private static let datePatterns = [
        #"[0-9٠-٩]{4}[-/.][0-9٠-٩]{1,2}[-/.][0-9٠-٩]{1,2}"#,
        #"[0-9٠-٩]{1,2}[-/.][0-9٠-٩]{1,2}[-/.][0-9٠-٩]{2,4}"#,
        #"[0-9٠-٩]{1,2}:[0-9٠-٩]{2}(:[0-9٠-٩]{2})?"#,
    ]

    static func isMarkerCandidate(_ text: String) -> Bool {
        for pattern in pagePatterns where text.range(of: pattern, options: .regularExpression) != nil {
            return false
        }
        // A row is a date line when removing every date-shaped run leaves no digits at all. A row
        // that still has a number after the dates come out is a result reported alongside its
        // collection date ("Glucose 2026-03-14 5.4 mmol/L") and must survive.
        var stripped = text
        for pattern in datePatterns {
            stripped = stripped.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return stripped.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789٠١٢٣٤٥٦٧٨٩")) != nil
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
                // `rawLines` stores what Vision returned, fragment by fragment. Field extraction
                // works on the REASSEMBLED rows (`LabOCRRowAssembler`) — the artifact and the
                // interpretation are kept separate on purpose, so a future change to row assembly
                // can never be mistaken for a change to what the recognizer read.
                rawLines.append(contentsOf: lines)
                fields.append(contentsOf: LabOCRRowAssembler.rows(from: lines).compactMap { extractField(from: $0) })
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
        guard LabOCRRowFilter.isMarkerCandidate(line.text) else { return nil }
        guard let valueMatch = LabOCRNumberParser.firstNumber(in: line.text) else { return nil }
        let beforeValue = String(line.text[line.text.startIndex..<valueMatch.range.lowerBound])
        let comparator = LabOCRComparatorParser.recognize(in: line.text, beforeValueAt: valueMatch.range)
        let analyteLabel = Self.strippingTrailingComparator(from: beforeValue, matched: comparator)
            .trimmingCharacters(in: .whitespaces)
        // A marker name has letters in it. Requiring one kills the single worst junk row an
        // unassembled interval column produces — label `(`, value 30, unit `-400` — without
        // touching any real label, in either script. Punctuation alone is not a name.
        guard analyteLabel.rangeOfCharacter(from: .letters) != nil else { return nil }

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
