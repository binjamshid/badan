import SwiftUI

// ============================================================================
// MARK: - CYCLE-08: scoped cycle-module export (Phase 3F slice 2)
// ============================================================================
//
// Mirrors `Features/Labs/LabExportScreen.swift` EXACTLY (read it in full first — including its
// post-audit-fix state — before touching this file): CSV/JSON export built entirely IN MEMORY
// (plaintext cycle data is never written to disk, not even transiently), encrypted via the SAME
// `ExportEncryptor`/`ExportContainerFile`/`ExportPassphrasePolicy` primitives
// (`Export/ExportEncryption.swift`) and `ExportCopy`'s shared passphrase copy
// (`Export/ExportCenterScreen.swift`) — reused, never re-derived. Every byte this screen can ever
// export is I7 sensitive-tier cycle data (`CycleModuleServices` reads exclusively from
// `env.database.sensitive` — this slice's shared cross-lane contract), so — exactly like Labs —
// encryption here is UNCONDITIONAL: there is no scope-toggle to skip it, because there is no
// non-sensitive subset of this data to offer exporting instead.
//
// Two sections, kept separate and NEVER blended (I5, this codebase's "raw vs derived never
// conflated" convention): raw cycle records / flow logs / contraceptive-method log in one group,
// derived predictions / phase estimates / anomaly events in a clearly separate group — six files
// for CSV (three `cycle_raw_*.csv`, three `cycle_derived_*.csv`), two top-level JSON keys
// (`"raw"`/`"derived"`) for the single JSON file. Reuses `CSVWriter`/`CanonicalJSON` exactly like
// `LabExportScreen` does — no re-derived CSV escaping or JSON rendering.
//
// PREDICTIONS/PHASE-ESTIMATES ARE SINGULAR, NOT A LIST — this is not a scope-narrowing choice by
// this file, it is what the already-committed repositories actually expose:
// `CyclePredictionRepository`/`CyclePhaseEstimateRepository` are append-only stores whose ONLY read
// method is "the latest one" (`latestPrediction()` / `latestEstimate(asOf:)`), matching
// `DerivedTrend`'s own "latest wins on read" convention — there is no "all predictions ever
// generated" query to export. `CycleAnomalyEventRepository.liveEvents()` DOES return a list, so the
// anomaly section is the one derived table that can have more than one row.
//
// Anomaly rows export BOTH `message_key` (the stored, non-diagnostic key —
// `CycleAnomalyEvent.messageKey`'s own doc: "a KEY, never rendered text") AND the resolved bilingual
// copy those keys already map to via `CycleAnomalyMessages.text(for:)` — the SAME pre-approved,
// wellness-safe templates the in-app anomaly cards render (a different, later screen's job), never a
// freshly-invented sentence. An unrecognized key (a future engine version) resolves to empty message
// fields rather than a fabricated fallback, matching that lookup's own "never invent a value" rule.

// MARK: - Format

enum CycleExportFormat: String, CaseIterable, Identifiable {
    case csv, json
    var id: String { rawValue }
    var label: LocalizedString {
        switch self {
        case .csv: return LocalizedString(en: "CSV", ar: "CSV")
        case .json: return LocalizedString(en: "JSON", ar: "JSON")
        }
    }
}

// MARK: - Bundle (everything this screen can ever export, gathered once per load)

struct CycleExportBundle {
    var cycles: [CycleRecord]
    var flowLogs: [FlowLog]
    var contraceptiveContext: [ContraceptiveContextLog]
    /// Singular — see file header for why (`CyclePredictionRepository` exposes only the latest).
    var prediction: CyclePrediction?
    /// Singular — see file header for why (`CyclePhaseEstimateRepository` exposes only the latest).
    var phaseEstimate: CyclePhaseEstimate?
    var anomalies: [CycleAnomalyEvent]

    var isEmpty: Bool {
        cycles.isEmpty && flowLogs.isEmpty && contraceptiveContext.isEmpty
            && prediction == nil && phaseEstimate == nil && anomalies.isEmpty
    }
}

// MARK: - Section builders (shared by both formats, so CSV and JSON can never drift apart —
// mirrors `LabExportSections` exactly). Internal rather than `private`, unlike `LabExportScreen`'s
// own section builders, specifically so `CycleExportScreenTests` can exercise them directly without
// standing up a live `CycleModuleServices`/database — this slice's own test file, which Labs never
// got one of.

enum CycleExportSections {
    // MARK: Raw

    static func cycleRecordRows(_ bundle: CycleExportBundle) -> [[String: String]] {
        bundle.cycles.map { r in
            let tz = r.provenance.measuredTimezone
            return [
                "record_id": r.id,
                "start_at": CSVWriter.iso8601(r.startAt, tzId: tz),
                "end_at": r.endAt.map { CSVWriter.iso8601($0, tzId: tz) } ?? "",
                "ongoing": r.ongoing ? "true" : "false",
                "note": r.note ?? "",
                "revision": String(r.revision),
                "is_original": r.isOriginal ? "true" : "false",
                "ingestion_path": r.provenance.ingestionPath.rawValue,
                "measured_at": CSVWriter.iso8601(r.provenance.measuredAt, tzId: tz),
            ]
        }
    }

    static func flowLogRows(_ bundle: CycleExportBundle) -> [[String: String]] {
        bundle.flowLogs.map { f in
            let tz = f.provenance.measuredTimezone
            return [
                "record_id": f.id,
                "cycle_id": f.cycleId,
                "occurred_at": CSVWriter.iso8601(f.occurredAt, tzId: tz),
                "original_label": f.originalLabel,
                "normalized_intensity": CSVWriter.decimal(f.normalizedIntensity),
                "note": f.note ?? "",
                "ingestion_path": f.provenance.ingestionPath.rawValue,
            ]
        }
    }

    static func contraceptiveContextRows(_ bundle: CycleExportBundle) -> [[String: String]] {
        bundle.contraceptiveContext.map { c in
            let tz = c.provenance.measuredTimezone
            return [
                "record_id": c.id,
                "method_type": c.methodType.rawValue,
                "start_at": CSVWriter.iso8601(c.startAt, tzId: tz),
                "end_at": c.endAt.map { CSVWriter.iso8601($0, tzId: tz) } ?? "",
                "is_active": c.isActive ? "true" : "false",
                "note": c.adherenceNote ?? "",
                "ingestion_path": c.provenance.ingestionPath.rawValue,
            ]
        }
    }

    // MARK: Derived
    //
    // No embedded `Provenance` on any of the three types below (they are computed, not measured —
    // see each type's own doc in `Domain/Cycle/CycleModels.swift`), so their own timestamps render
    // at UTC (+00:00), matching `JSONBundleWriter`'s identical convention for every other derived
    // value in this codebase ("Derived values have no measurement timezone of their own").

    static func predictionRows(_ bundle: CycleExportBundle) -> [[String: String]] {
        guard let p = bundle.prediction else { return [] }
        return [[
            "record_id": p.id,
            "generated_at": CSVWriter.iso8601(p.generatedAt, tzId: "UTC"),
            "predicted_next_start_low": p.predictedNextStartLow.map { CSVWriter.iso8601($0, tzId: "UTC") } ?? "",
            "predicted_next_start_center": p.predictedNextStartCenter.map { CSVWriter.iso8601($0, tzId: "UTC") } ?? "",
            "predicted_next_start_high": p.predictedNextStartHigh.map { CSVWriter.iso8601($0, tzId: "UTC") } ?? "",
            "confidence": CSVWriter.decimal(p.confidence),
            "method": p.method.rawValue,
            "status": p.status.rawValue,
            "suppression_reason": p.suppressionReason ?? "",
            "algorithm_version": p.algorithmVersion,
            "input_cycle_ids": p.inputCycleIds.joined(separator: ";"),
        ]]
    }

    static func phaseEstimateRows(_ bundle: CycleExportBundle) -> [[String: String]] {
        guard let e = bundle.phaseEstimate else { return [] }
        return [[
            "record_id": e.id,
            "date_range_start": CSVWriter.iso8601(e.dateRangeStart, tzId: "UTC"),
            "date_range_end": CSVWriter.iso8601(e.dateRangeEnd, tzId: "UTC"),
            "phase": e.phase.rawValue,
            "confidence": CSVWriter.decimal(e.confidence),
            "evidence_basis": e.evidenceBasis.rawValue,
            "algorithm_version": e.algorithmVersion,
            "computed_at": CSVWriter.iso8601(e.computedAt, tzId: "UTC"),
        ]]
    }

    static func anomalyRows(_ bundle: CycleExportBundle) -> [[String: String]] {
        bundle.anomalies.map { a in
            let template = CycleAnomalyMessages.text(for: a.messageKey)
            return [
                "record_id": a.id,
                "type": a.type.rawValue,
                "detected_at": CSVWriter.iso8601(a.detectedAt, tzId: "UTC"),
                "severity": a.severity.rawValue,
                "message_key": a.messageKey,
                "message_en": template?.en ?? "",
                "message_ar": template?.ar ?? "",
                "state": a.state.rawValue,
                "confidence": CSVWriter.decimal(a.confidence),
                "algorithm_version": a.algorithmVersion,
                "basis_window_cycle_ids": a.basisWindowCycleIds.joined(separator: ";"),
            ]
        }
    }
}

// MARK: - CSV writer

enum CycleExportColumns {
    static let cycleRecords = ["record_id", "start_at", "end_at", "ongoing", "note", "revision",
                              "is_original", "ingestion_path", "measured_at"]
    static let flowLogs = ["record_id", "cycle_id", "occurred_at", "original_label",
                           "normalized_intensity", "note", "ingestion_path"]
    static let contraceptiveContext = ["record_id", "method_type", "start_at", "end_at", "is_active",
                                       "note", "ingestion_path"]
    static let predictions = ["record_id", "generated_at", "predicted_next_start_low",
                              "predicted_next_start_center", "predicted_next_start_high", "confidence",
                              "method", "status", "suppression_reason", "algorithm_version", "input_cycle_ids"]
    static let phaseEstimates = ["record_id", "date_range_start", "date_range_end", "phase", "confidence",
                                "evidence_basis", "algorithm_version", "computed_at"]
    static let anomalies = ["record_id", "type", "detected_at", "severity", "message_key", "message_en",
                            "message_ar", "state", "confidence", "algorithm_version", "basis_window_cycle_ids"]
}

enum CycleCSVExport {
    static func files(_ bundle: CycleExportBundle) -> [String: String] {
        [
            "cycle_raw_records.csv": table(columns: CycleExportColumns.cycleRecords,
                                           rows: CycleExportSections.cycleRecordRows(bundle)),
            "cycle_raw_flow_logs.csv": table(columns: CycleExportColumns.flowLogs,
                                             rows: CycleExportSections.flowLogRows(bundle)),
            "cycle_raw_contraceptive_context.csv": table(columns: CycleExportColumns.contraceptiveContext,
                                                         rows: CycleExportSections.contraceptiveContextRows(bundle)),
            "cycle_derived_predictions.csv": table(columns: CycleExportColumns.predictions,
                                                   rows: CycleExportSections.predictionRows(bundle)),
            "cycle_derived_phase_estimates.csv": table(columns: CycleExportColumns.phaseEstimates,
                                                       rows: CycleExportSections.phaseEstimateRows(bundle)),
            "cycle_derived_anomalies.csv": table(columns: CycleExportColumns.anomalies,
                                                 rows: CycleExportSections.anomalyRows(bundle)),
        ]
    }

    static func table(columns: [String], rows: [[String: String]]) -> String {
        var out = columns.map(CSVWriter.escape).joined(separator: ",")
        for row in rows {
            out += CSVWriter.newline
            out += columns.map { CSVWriter.escape(row[$0] ?? "") }.joined(separator: ",")
        }
        return out + CSVWriter.newline
    }
}

// MARK: - JSON writer (via CanonicalJSON)

enum CycleJSONExport {
    static func render(_ bundle: CycleExportBundle) -> String {
        CanonicalJSON.object([
            "raw": .object([
                "cycle_records": .array(CycleExportSections.cycleRecordRows(bundle).map(rowObject)),
                "flow_logs": .array(CycleExportSections.flowLogRows(bundle).map(rowObject)),
                "contraceptive_context": .array(CycleExportSections.contraceptiveContextRows(bundle).map(rowObject)),
            ]),
            "derived": .object([
                "predictions": .array(CycleExportSections.predictionRows(bundle).map(rowObject)),
                "phase_estimates": .array(CycleExportSections.phaseEstimateRows(bundle).map(rowObject)),
                "anomalies": .array(CycleExportSections.anomalyRows(bundle).map(rowObject)),
            ]),
        ]).render()
    }

    static func rowObject(_ row: [String: String]) -> CanonicalJSON {
        .object(row.mapValues { CanonicalJSON.string($0) })
    }
}

// MARK: - Screen-local strings

enum CycleExportStrings {
    static let title = LocalizedString(en: "Export", ar: "تصدير")
    static let subtitle = LocalizedString(
        en: "Your cycle records, flow logs, and contraceptive-method log are kept separate from "
            + "BADAN's own predictions, phase estimates, and pattern notes — never blended into one "
            + "file section.",
        ar: "تُحفظ سجلات دورتك وتدفقك ووسيلة منع الحمل بشكل منفصل عن تنبؤات بدن وتقديرات المرحلة "
            + "وملاحظات النمط — لا تُدمج أبداً في قسم واحد.")
    static let format = LocalizedString(en: "Format", ar: "الصيغة")
    static let exportAction = LocalizedString(en: "Export", ar: "تصدير")
    static let empty = LocalizedString(en: "Nothing to export yet.", ar: "لا شيء لتصديره بعد.")
    static let loadFailed = LocalizedString(en: "Couldn't prepare your export right now.", ar: "تعذّر تحضير التصدير الآن.")
    static let exportFailed = LocalizedString(en: "Couldn't create the export. Try again.", ar: "تعذّر إنشاء التصدير. حاول مرة أخرى.")
}

// MARK: - Screen

/// Sensitive-tier cycle-module data export — see file header for why encryption here is
/// unconditional, exactly like `LabExportScreen`. Takes `CycleModuleServices` exactly like every
/// other Cycle-module screen (this slice's shared cross-lane contract), constructed once per
/// top-level screen instance by the caller.
struct CycleExportScreen: View {
    @Environment(AppEnvironment.self) private var env
    let services: CycleModuleServices
    @State private var format: CycleExportFormat = .csv
    @State private var state: LoadState<CycleExportBundle> = .loading
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
                Text(env.s(CycleExportStrings.subtitle))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                StatefulContainer(state, emptyIcon: "calendar") { bundle in
                    VStack(alignment: .leading, spacing: BadanSpace.space4) {
                        Picker(env.s(CycleExportStrings.format), selection: $format) {
                            ForEach(CycleExportFormat.allCases) { f in Text(env.s(f.label)).tag(f) }
                        }
                        .pickerStyle(.segmented)

                        passphraseSection

                        if exportFailed {
                            Text(env.s(CycleExportStrings.exportFailed))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.outOfBand)
                        }

                        Button {
                            export(bundle)
                        } label: {
                            Text(env.s(CycleExportStrings.exportAction))
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
        .navigationTitle(env.s(CycleExportStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .sheet(item: Binding(
            get: { shareURLs.map { CycleExportShareURLs(urls: $0) } },
            set: { shareURLs = $0?.urls }
        )) { wrapped in
            ShareSheet(activityItems: wrapped.urls)
        }
    }

    // MARK: Passphrase (identical shape to `LabExportScreen`'s own — same shared primitives)

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

    // MARK: Load

    private func load() {
        do {
            let cycles = try services.cycleRecords.liveRecords()
            var flowLogs: [FlowLog] = []
            for cycle in cycles { flowLogs.append(contentsOf: try services.flowLogs.liveLogs(cycleId: cycle.id)) }
            let contraceptiveContext = try services.contraceptiveContext.liveContexts()
            let prediction = try services.predictions.latestPrediction()
            let phaseEstimate = try services.phaseEstimates.latestEstimate(asOf: env.now())
            let anomalies = try services.anomalies.liveEvents()
            let bundle = CycleExportBundle(cycles: cycles, flowLogs: flowLogs, contraceptiveContext: contraceptiveContext,
                                           prediction: prediction, phaseEstimate: phaseEstimate, anomalies: anomalies)
            state = bundle.isEmpty ? .empty(env.s(CycleExportStrings.empty)) : .loaded(bundle)
        } catch {
            state = .error(env.s(CycleExportStrings.loadFailed))
        }
    }

    // MARK: Export
    //
    /// Builds every format's files entirely in memory and hands them straight to
    /// `ExportEncryptor.encrypt` — plaintext cycle data (this codebase's single highest-sensitivity
    /// family, per `docs/legal/reproductive-threat-model.md` §1) is never written to disk at all,
    /// not even transiently. Only the resulting `.badanenc` container ever touches the filesystem.
    private func export(_ bundle: CycleExportBundle) {
        guard passphraseValid else { return }
        exportFailed = false
        let files: [ExportContainerFile]
        switch format {
        case .csv:
            files = CycleCSVExport.files(bundle).map { name, contents in
                ExportContainerFile(name: name, data: Data(contents.utf8))
            }
        case .json:
            files = [ExportContainerFile(name: "cycle_export.json", data: Data(CycleJSONExport.render(bundle).utf8))]
        }
        do {
            let containerData = try ExportEncryptor.encrypt(files: files, passphrase: passphrase)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BADAN-cycle-export-\(ULID.newID())", isDirectory: true)
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

/// `Identifiable` wrapper so `.sheet(item:)` can present a batch of share URLs at once (the CSV
/// export hands the share sheet six files simultaneously). Distinct type from `LabExportScreen`'s
/// own private `ShareURLs` wrapper (that one is file-private there) rather than reused across files.
private struct CycleExportShareURLs: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.path).joined(separator: "|") }
}
