import SwiftUI

// ============================================================================
// MARK: - LAB-10: CSV/JSON/PDF export, raw/normalized/derived/annotations kept SEPARATE
// ============================================================================
//
// Reuses this codebase's existing export primitives rather than re-deriving them: `CSVWriter`
// (RFC-4180 escaping/number formatting), `CanonicalJSON` (deterministic, correctly-null-safe JSON
// rendering), `ReportRenderer.renderPDF(html:)` (the same offline HTML->PDF stage `ReportRenderer`
// already uses for weekly/monthly reports), and `ShareSheet` (the same offline share-sheet wrapper
// every other export screen hands its files to). None of these are edited here — only called.
//
// Every result this screen can ever export lives in `badan_sensitive.db` (I7) — there is no
// non-sensitive subset of the lab notebook. So unlike a mixed-scope export surface, encryption here
// is unconditional, not a toggle: `ExportEncryptor`/`ExportContainerFile`/`ExportPassphrasePolicy`
// (`Export/ExportEncryption.swift`) and `ExportCopy`'s passphrase copy (`Export/
// ExportCenterScreen.swift`) are reused exactly as `ExportRunner` uses them for its own
// `includeSensitive` case — the only file this screen ever writes to disk is the resulting
// `.badanenc` container.
//
// The four sections below are NEVER blended into one flat table — each is its own CSV file / its
// own top-level JSON key / its own labeled PDF section, so a reader can always tell which of the
// four reference-range concepts (or "as entered" vs "BADAN computed") a number came from (I5).

private enum LabExportFormat: String, CaseIterable, Identifiable {
    case csv, json, pdf
    var id: String { rawValue }
    var label: LocalizedString {
        switch self {
        case .csv: return LocalizedString(en: "CSV", ar: "CSV")
        case .json: return LocalizedString(en: "JSON", ar: "JSON")
        case .pdf: return LocalizedString(en: "PDF", ar: "PDF")
        }
    }
}

private struct LabExportBundle {
    var reports: [LabReport]
    var results: [LabResult]
    var ranges: [String: ReferenceRange]           // keyed by result id
    var trends: [String: DerivedTrend]              // keyed by analyteKey
    var thresholds: [String: ReferenceRangeEngine.UserLabThreshold]  // keyed by analyteKey
    var corrections: [UserCorrection]

    var isEmpty: Bool { results.isEmpty }
}

// MARK: - Section builders (shared by all three formats, so they can never drift apart)

private enum LabExportSections {
    /// Concept #1/#2 + as-entered values, verbatim. Never blended with anything BADAN computed.
    static func rawRows(_ bundle: LabExportBundle) -> [[String: String]] {
        let reportsById = Dictionary(uniqueKeysWithValues: bundle.reports.map { ($0.id, $0) })
        return bundle.results.map { r in
            let range = bundle.ranges[r.id]
            return [
                "result_id": r.id,
                "report_id": r.reportId,
                "lab_name": reportsById[r.reportId]?.sourceLabName ?? "",
                "marker": r.customLabel ?? r.analyteId ?? r.analyteKey,
                "is_custom_marker": r.analyteId == nil ? "true" : "false",
                "raw_value_text": r.rawValueText,
                "comparator": r.comparator?.rawValue ?? "",
                "raw_unit": r.rawUnit ?? "",
                "source_interval_low": range?.sourceIntervalLow.map(LabNumberFormat.string) ?? "",
                "source_interval_high": range?.sourceIntervalHigh.map(LabNumberFormat.string) ?? "",
                "source_interval_text": range?.sourceIntervalText ?? "",
                "source_flag": range?.sourceFlag ?? "",
                "ingestion_path": r.provenance.ingestionPath.rawValue,
                "measured_at": TimestampFormatting.string(r.provenance.measuredAt, tzId: r.provenance.measuredTimezone),
                "revision": String(r.revision),
            ]
        }
    }

    /// ONLY the "safe" unit-conversion class ever appears here — a row is present ONLY when
    /// `canonicalValue`/`canonicalUnit` were actually populated by `UnitNormalization` at write
    /// time; every other analyte/unit pair is deliberately absent, never guessed.
    static func normalizedRows(_ bundle: LabExportBundle) -> [[String: String]] {
        bundle.results.compactMap { r -> [String: String]? in
            guard let canonicalValue = r.canonicalValue, let canonicalUnit = r.canonicalUnit else { return nil }
            return [
                "result_id": r.id,
                "marker": r.customLabel ?? r.analyteId ?? r.analyteKey,
                "original_value": r.numericValue.map(LabNumberFormat.string) ?? "",
                "original_unit": r.rawUnit ?? "",
                "canonical_value": LabNumberFormat.string(canonicalValue),
                "canonical_unit": canonicalUnit,
            ]
        }
    }

    /// Concept #3 — BADAN's own computed personal baseline, per analyte. Never a raw value.
    static func derivedRows(_ bundle: LabExportBundle) -> [[String: String]] {
        bundle.trends.keys.sorted().compactMap { key -> [String: String]? in
            guard let trend = bundle.trends[key] else { return nil }
            return [
                "analyte": key,
                "n_points": String(trend.nPoints),
                "band_low": LabNumberFormat.string(trend.bandLow),
                "band_high": LabNumberFormat.string(trend.bandHigh),
                "center": LabNumberFormat.string(trend.center),
                "unit": trend.unit,
                "provisional": trend.provisional ? "true" : "false",
                "algorithm_version": trend.algorithmVersion,
            ]
        }
    }

    /// Concept #4 (user thresholds) + the `UserCorrection` audit trail + revision markers. Never a
    /// value the lab or BADAN itself asserted.
    static func annotationRows(_ bundle: LabExportBundle) -> [[String: String]] {
        var rows: [[String: String]] = []
        for r in bundle.results {
            if r.isRevised {
                rows.append([
                    "kind": "revision", "result_id": r.id, "marker": r.customLabel ?? r.analyteId ?? r.analyteKey,
                    "field": "", "value": "", "note": "revision \(r.revision), supersedes \(r.supersedes ?? "")",
                ])
            }
            if let threshold = bundle.thresholds[r.analyteKey] {
                rows.append([
                    "kind": "user_threshold", "result_id": r.id, "marker": r.customLabel ?? r.analyteId ?? r.analyteKey,
                    "field": threshold.direction.rawValue,
                    "value": "\(LabNumberFormat.string(threshold.value)) \(threshold.unit)", "note": "",
                ])
            }
        }
        for c in bundle.corrections {
            rows.append([
                "kind": "correction", "result_id": c.targetType == .result ? c.targetId : "",
                "marker": "", "field": c.fieldName,
                "value": c.correctedValueText, "note": c.reason ?? "",
            ])
        }
        return rows
    }
}

// MARK: - CSV writer

private enum LabExportColumns {
    static let raw = ["result_id", "report_id", "lab_name", "marker", "is_custom_marker", "raw_value_text",
                      "comparator", "raw_unit", "source_interval_low", "source_interval_high",
                      "source_interval_text", "source_flag", "ingestion_path", "measured_at", "revision"]
    static let normalized = ["result_id", "marker", "original_value", "original_unit", "canonical_value", "canonical_unit"]
    static let derived = ["analyte", "n_points", "band_low", "band_high", "center", "unit", "provisional", "algorithm_version"]
    static let annotations = ["kind", "result_id", "marker", "field", "value", "note"]
}

private enum LabCSVExport {
    static func files(_ bundle: LabExportBundle) -> [String: String] {
        [
            "lab_raw.csv": table(columns: LabExportColumns.raw, rows: LabExportSections.rawRows(bundle)),
            "lab_normalized.csv": table(columns: LabExportColumns.normalized, rows: LabExportSections.normalizedRows(bundle)),
            "lab_derived.csv": table(columns: LabExportColumns.derived, rows: LabExportSections.derivedRows(bundle)),
            "lab_annotations.csv": table(columns: LabExportColumns.annotations, rows: LabExportSections.annotationRows(bundle)),
        ]
    }

    private static func table(columns: [String], rows: [[String: String]]) -> String {
        var out = columns.map(CSVWriter.escape).joined(separator: ",")
        for row in rows {
            out += CSVWriter.newline
            out += columns.map { CSVWriter.escape(row[$0] ?? "") }.joined(separator: ",")
        }
        return out + CSVWriter.newline
    }
}

// MARK: - JSON writer (via CanonicalJSON)

private enum LabJSONExport {
    static func render(_ bundle: LabExportBundle) -> String {
        CanonicalJSON.object([
            "raw": .array(LabExportSections.rawRows(bundle).map(rowObject)),
            "normalized": .array(LabExportSections.normalizedRows(bundle).map(rowObject)),
            "derived": .array(LabExportSections.derivedRows(bundle).map(rowObject)),
            "annotations": .array(LabExportSections.annotationRows(bundle).map(rowObject)),
        ]).render()
    }

    private static func rowObject(_ row: [String: String]) -> CanonicalJSON {
        .object(row.mapValues { CanonicalJSON.string($0) })
    }
}

// MARK: - PDF writer (via the existing ReportRenderer.renderPDF(html:) stage)

private enum LabPDFExport {
    static func html(_ bundle: LabExportBundle, language: AppLanguage) -> String {
        let dir = language.isRTL ? "rtl" : "ltr"

        func section(_ title: String, _ rows: [[String: String]], columns: [String]) -> String {
            var out = "<h2>\(esc(title))</h2>"
            if rows.isEmpty {
                out += "<p class=\"empty\">—</p>"
                return out
            }
            out += "<table><tr>" + columns.map { "<th>\(esc($0))</th>" }.joined() + "</tr>"
            for row in rows {
                out += "<tr>" + columns.map { "<td>\(esc(row[$0] ?? ""))</td>" }.joined() + "</tr>"
            }
            out += "</table>"
            return out
        }

        var body = "<h1>\(esc(LocalizedString(en: "Lab notebook export", ar: "تصدير دفتر نتائج المختبر").resolved(language)))</h1>"
        body += section(LocalizedString(en: "Raw (as recorded / as printed)", ar: "خام (كما سُجّل / كما طُبع)").resolved(language),
                        LabExportSections.rawRows(bundle), columns: LabExportColumns.raw)
        body += section(LocalizedString(en: "Normalized (safe unit conversions only)", ar: "مُوَحَّد (تحويلات وحدات آمنة فقط)").resolved(language),
                        LabExportSections.normalizedRows(bundle), columns: LabExportColumns.normalized)
        body += section(LocalizedString(en: "Derived (BADAN-computed personal pattern)", ar: "مُشتَق (نمط شخصي محسوب بواسطة بدن)").resolved(language),
                        LabExportSections.derivedRows(bundle), columns: LabExportColumns.derived)
        body += section(LocalizedString(en: "Annotations (your own thresholds, notes, corrections)", ar: "ملاحظات (حدودك، ملاحظاتك، تصحيحاتك)").resolved(language),
                        LabExportSections.annotationRows(bundle), columns: LabExportColumns.annotations)

        return """
        <!DOCTYPE html>
        <html lang="\(language.rawValue)" dir="\(dir)">
        <head><meta charset="utf-8"><style>
        body { font-family: -apple-system, sans-serif; font-size: 11px; direction: \(dir); }
        h1 { font-size: 20px; } h2 { font-size: 14px; margin-top: 18px; border-bottom: 1px solid #ddd; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 10px; }
        th, td { border: 1px solid #ddd; padding: 3px 6px; text-align: \(language.isRTL ? "right" : "left"); }
        p.empty { color: #888; font-style: italic; }
        </style></head><body>\(body)</body></html>
        """
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Screen-local strings

private enum LabExportStrings {
    static let title = LocalizedString(en: "Export", ar: "تصدير")
    static let subtitle = LocalizedString(
        en: "Raw, normalized, derived, and your own annotations are always kept in separate sections — never blended into one table.",
        ar: "تُحفظ القيم الخام والمُوَحَّدة والمُشتقّة وملاحظاتك دائماً في أقسام منفصلة — لا تُدمج أبداً في جدول واحد.")
    static let format = LocalizedString(en: "Format", ar: "الصيغة")
    static let exportAction = LocalizedString(en: "Export", ar: "تصدير")
    static let empty = LocalizedString(en: "Nothing to export yet.", ar: "لا شيء لتصديره بعد.")
    static let loadFailed = LocalizedString(en: "Couldn't prepare your export right now.", ar: "تعذّر تحضير التصدير الآن.")
    static let exportFailed = LocalizedString(en: "Couldn't create the export. Try again.", ar: "تعذّر إنشاء التصدير. حاول مرة أخرى.")
}

// MARK: - Screen

/// Every byte this screen exports is I7 sensitive-tier lab data (`LabNotebookServices` reads
/// exclusively from `env.database.sensitive` — see that type's own doc comment), so encryption
/// here is unconditional, never an `includeSensitive`-style toggle: unlike
/// `AdvancedExportBuilderScreen`, there is no non-sensitive subset of the lab notebook to offer
/// exporting instead. Reuses this codebase's existing sensitive-export primitives exactly —
/// `ExportEncryptor`/`ExportContainerFile` (`Export/ExportEncryption.swift`) and
/// `ExportPassphrasePolicy`/`ExportCopy`'s passphrase copy (`Export/ExportCenterScreen.swift`) —
/// rather than re-deriving a second encryption/consent scheme.
struct LabExportScreen: View {
    @Environment(AppEnvironment.self) private var env
    let services: LabNotebookServices
    @State private var format: LabExportFormat = .csv
    @State private var state: LoadState<LabExportBundle> = .loading
    @State private var shareURLs: [URL]?
    @State private var passphrase = ""
    @State private var passphraseConfirm = ""
    @State private var exportFailed = false

    private var passphraseValid: Bool {
        ExportPassphrasePolicy.isValid(passphrase)
            && ExportPassphrasePolicy.matches(passphrase, confirmation: passphraseConfirm)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                Text(env.s(LabExportStrings.subtitle))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                StatefulContainer(state, emptyIcon: "square.and.arrow.up") { bundle in
                    VStack(alignment: .leading, spacing: BadanSpace.space4) {
                        Picker(env.s(LabExportStrings.format), selection: $format) {
                            ForEach(LabExportFormat.allCases) { f in Text(env.s(f.label)).tag(f) }
                        }
                        .pickerStyle(.segmented)

                        passphraseSection

                        if exportFailed {
                            Text(env.s(LabExportStrings.exportFailed))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.outOfBand)
                        }

                        Button {
                            export(bundle)
                        } label: {
                            Text(env.s(LabExportStrings.exportAction))
                                .font(BadanFont.body.weight(.semibold))
                                .foregroundStyle(BadanColor.onPrimary)
                                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                                .background(passphraseValid ? BadanColor.primary : BadanColor.separator,
                                           in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                        }
                        .disabled(!passphraseValid)
                    }
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(LabExportStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .sheet(item: Binding(
            get: { shareURLs.map { ShareURLs(urls: $0) } },
            set: { shareURLs = $0?.urls }
        )) { wrapped in
            ShareSheet(activityItems: wrapped.urls)
        }
    }

    // MARK: Passphrase

    private var passphraseSection: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(env.s(ExportCopy.passphraseIntro(env.format)))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(env.s(ExportCopy.passphrasePlaceholder), text: $passphrase)
                .textContentType(.newPassword)
                .autocorrectionDisabled()
                .padding(BadanSpace.space2)
                .background(BadanColor.surfaceElevated, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            SecureField(env.s(ExportCopy.passphraseConfirmPlaceholder), text: $passphraseConfirm)
                .textContentType(.newPassword)
                .autocorrectionDisabled()
                .padding(BadanSpace.space2)
                .background(BadanColor.surfaceElevated, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            if !passphrase.isEmpty && !ExportPassphrasePolicy.isValid(passphrase) {
                Text(env.s(ExportCopy.passphraseTooShort)).font(BadanFont.caption).foregroundStyle(BadanColor.outOfBand)
            } else if !passphraseConfirm.isEmpty && !ExportPassphrasePolicy.matches(passphrase, confirmation: passphraseConfirm) {
                Text(env.s(ExportCopy.passphraseMismatch)).font(BadanFont.caption).foregroundStyle(BadanColor.outOfBand)
            }
        }
    }

    private func load() {
        do {
            let reports = try services.reports.liveReports()
            let results = try services.results.allLiveResults()
            var ranges: [String: ReferenceRange] = [:]
            for r in results { ranges[r.id] = services.range(resultId: r.id) }
            var trends: [String: DerivedTrend] = [:]
            for key in Set(results.map(\.analyteKey)) { trends[key] = try? services.trends.latestTrend(analyteId: key) }
            var thresholds: [String: ReferenceRangeEngine.UserLabThreshold] = [:]
            for key in Set(results.map(\.analyteKey)) { thresholds[key] = services.thresholds.threshold(for: key) }
            var corrections: [UserCorrection] = []
            for r in results { corrections.append(contentsOf: (try? services.reports.corrections(targetType: .result, targetId: r.id)) ?? []) }
            let bundle = LabExportBundle(reports: reports, results: results, ranges: ranges, trends: trends,
                                        thresholds: thresholds, corrections: corrections)
            state = bundle.isEmpty ? .empty(env.s(LabExportStrings.empty)) : .loaded(bundle)
        } catch {
            state = .error(env.s(LabExportStrings.loadFailed))
        }
    }

    /// Builds every format's files entirely in memory and hands them straight to
    /// `ExportEncryptor.encrypt` — plaintext lab data (potentially HIV/beta-hCG-class analytes,
    /// per `DerivedTrendRepository`'s own doc comment) is never written to disk at all, not even
    /// transiently. Only the resulting `.badanenc` container ever touches the filesystem, and
    /// that's the one file handed to the share sheet.
    private func export(_ bundle: LabExportBundle) {
        guard passphraseValid else { return }
        exportFailed = false
        let files: [ExportContainerFile]
        switch format {
        case .csv:
            files = LabCSVExport.files(bundle).map { name, contents in
                ExportContainerFile(name: name, data: Data(contents.utf8))
            }
        case .json:
            files = [ExportContainerFile(name: "lab_export.json", data: Data(LabJSONExport.render(bundle).utf8))]
        case .pdf:
            let data = ReportRenderer.renderPDF(html: LabPDFExport.html(bundle, language: env.language))
            files = [ExportContainerFile(name: "lab_export.pdf", data: data)]
        }
        do {
            let containerData = try ExportEncryptor.encrypt(files: files, passphrase: passphrase)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BADAN-lab-export-\(ULID.newID())", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(ExportEncryptor.containerFileName)
            try containerData.write(to: url, options: .completeFileProtection)
            shareURLs = [url]
            passphrase = ""
            passphraseConfirm = ""
        } catch {
            exportFailed = true
        }
    }
}

/// `Identifiable` wrapper so `.sheet(item:)` can present a batch of share URLs at once (the
/// screen's own CSV export hands the share sheet four files simultaneously).
private struct ShareURLs: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.path).joined(separator: "|") }
}
