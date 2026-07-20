import Foundation
import CryptoKit

/// Why a template refused to run from an intent. Distinct from `ExportTemplateRunRefusal` (which
/// is about the *template's* consent gate) because these are refusals specific to running
/// **unattended**: the surface has no way to collect what the run would need.
enum IntentExportRefusal: Error, Equatable {
    /// The named template does not exist (deleted since the Shortcut was built, or a spoken name
    /// that matched nothing).
    case templateNotFound(name: String)
    /// §9.3: saving a template with `includeSensitive` is not standing permission to keep
    /// exporting meds/symptoms, and `ExportRunner` additionally requires a passphrase for one
    /// (ADR-0008). An intent can collect neither honestly — a Shortcuts automation may fire with
    /// nobody looking at the phone — so the run is refused rather than silently narrowed.
    case sensitiveTemplateNeedsTheApp(templateId: String)
}

/// EPIC-19 — the one place an App Intent turns a saved `ExportTemplate` into files on disk and a
/// row in the trust ledger.
///
/// Kept out of the intent types themselves so the three of them stay thin, and out of
/// `ExportRunner` because the runner's contract is "given a scope and a format, produce
/// artifacts" — resolving a *rule* into a window, and recording that the attempt happened, are
/// the template system's job (§9.3/§9.5), not the writer's.
///
/// **Every path through `run` writes an `ExportRun`.** A refusal before generation writes one
/// too, with the matching `ExportErrorCode`: the entire anti-HAE thesis is that an export that
/// did not happen leaves evidence, and "the automation silently declined" is precisely the case
/// the ledger exists to make visible.
@MainActor
struct IntentExportService {
    let env: AppEnvironment

    /// Built here rather than read off `AppEnvironment`, which does not yet expose them. They wrap
    /// `database.main` — the same `SQLiteConnection` every other repository in the environment
    /// holds — so this adds a struct, not a second connection or a second write lock. When the
    /// automation surfaces (EPIC-15) hoist these into the composition root, this becomes two
    /// property reads and nothing else changes.
    private var templates: ExportTemplateRepository { ExportTemplateRepository(env.database.main) }
    private var runs: ExportRunRepository { ExportRunRepository(env.database.main) }

    // MARK: - Template lookup

    func allTemplates() -> [ExportTemplate] {
        (try? templates.all()) ?? []
    }

    func template(id: String) -> ExportTemplate? {
        try? templates.template(id: id)
    }

    /// Name lookup for a spoken or typed parameter.
    ///
    /// Exact match first (that is what `idx_export_templates_name` guarantees is unique), then a
    /// case- and diacritic-insensitive contains pass, because Siri transcription does not preserve
    /// the capitalisation or the em dash in "Quick Export — Last 7 days (CSV)". Deliberately
    /// returns *candidates* rather than picking a winner: App Intents' own disambiguation prompt
    /// is the honest way to resolve "which one did you mean", and guessing would run the wrong
    /// export against the user's data.
    func templates(matching query: String) -> [ExportTemplate] {
        let all = allTemplates()
        if let exact = all.first(where: { $0.name == query }) { return [exact] }
        let needle = Self.foldedForSearch(query)
        guard !needle.isEmpty else { return all }
        return all.filter { Self.foldedForSearch($0.name).contains(needle) }
    }

    private static func foldedForSearch(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                  locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Running

    /// What one intent-triggered run produced. `notice` is non-nil when the run happened but the
    /// user should be told something about *how* — today only the `sinceLastRun` fallback below.
    struct RunOutcome {
        let template: ExportTemplate
        let files: [IntentExportFile]
        let rowCount: Int
        let notice: LocalizedString?
    }

    /// One artifact, with the name the *Shortcut* should see. The on-disk name is untouched:
    /// renaming files inside the job folder would break `ExportCenterViewModel`'s manifest-driven
    /// file resolution, which looks them up by the checksum keys `ExportRunner` wrote.
    struct IntentExportFile {
        let url: URL
        let filename: String
    }

    /// Run `template` now, on behalf of a Shortcut/Siri invocation.
    ///
    /// Throws before generating anything for a sensitive template; every other outcome
    /// (success, nothing-in-range, a generation failure) produces both a return value or a thrown
    /// error *and* an `ExportRun` row.
    func run(template: ExportTemplate) throws -> RunOutcome {
        let startedAt = env.now()

        guard !template.requiresSensitiveConfirmation else {
            record(templateId: template.id, startedAt: startedAt, outcome: .failedGeneration,
                   errorCode: .sensitiveConfirmationMissing, stage: .gathering,
                   destinationId: template.destinationId)
            throw IntentExportRefusal.sensitiveTemplateNeedsTheApp(templateId: template.id)
        }

        let resolved = resolvedWindow(for: template, now: startedAt)
        var scope = template.scope
        scope.startDate = resolved.start
        scope.endDate = resolved.end

        do {
            let result = try env.exporter.run(scope: scope, format: template.format)
            let files = Self.namedFiles(result.fileURLs, template: template,
                                        start: resolved.start, end: resolved.end, now: startedAt)
            record(templateId: template.id, startedAt: startedAt,
                   // Zero rows is a successful answer to "is there anything to export", not a
                   // failure — and it is recorded rather than skipped so an automation that
                   // legitimately had nothing to do stays distinguishable from one that never ran.
                   outcome: result.rowCount == 0 ? .skippedNoData : .success,
                   jobId: result.job.id,
                   bytesWritten: Self.totalBytes(result.fileURLs),
                   manifestSha: Self.manifestDigest(result.fileURLs),
                   destinationId: template.destinationId)
            return RunOutcome(template: template, files: files, rowCount: result.rowCount,
                              notice: resolved.notice)
        } catch {
            record(templateId: template.id, startedAt: startedAt, outcome: .failedGeneration,
                   errorCode: Self.errorCode(for: error), stage: .writing,
                   destinationId: template.destinationId)
            throw error
        }
    }

    // MARK: - Range rules

    private struct ResolvedWindow {
        let start: Date?
        let end: Date?
        let notice: LocalizedString?
    }

    /// Turn an `ExportRangeRule` into the concrete window this run uses.
    ///
    /// `sinceLastRun` is the interesting case and it is deliberately not implemented as a delta:
    /// a true incremental export reads `export_cursors.high_watermark`, which is a max
    /// `ingested_at`, and nothing in the app writes that table yet (EPIC-17 owns the delta chain).
    /// So the rule takes §12 EPIC-09's sanctioned no-cursor path — fall back to a bounded window
    /// **with a notice** — rather than either exporting all of history silently or refusing a
    /// template the user saved.
    private func resolvedWindow(for template: ExportTemplate, now: Date) -> ResolvedWindow {
        let tz = TimeZone.current.identifier
        switch template.rangeRule {
        case .fixed:
            return ResolvedWindow(start: template.scope.startDate, end: template.scope.endDate,
                                  notice: nil)
        case .lastNDays(let days):
            return ResolvedWindow(start: DayAttribution.addingDays(-max(1, days), to: now, tz: tz),
                                  end: now, notice: nil)
        case .allTime:
            return ResolvedWindow(start: nil, end: nil, notice: nil)
        case .sinceLastRun:
            return ResolvedWindow(
                start: DayAttribution.addingDays(-Self.sinceLastRunFallbackDays, to: now, tz: tz),
                end: now,
                notice: IntentStrings.sinceLastRunFallbackNotice)
        }
    }

    /// The window `sinceLastRun` falls back to. 30 days matches the Quick Export preset a user is
    /// most likely to have in mind, and is short enough that the fallback cannot quietly become an
    /// all-history export.
    private static let sinceLastRunFallbackDays = 30

    // MARK: - Ledger

    /// Append one `ExportRun`. `rowCounts` is deliberately left `nil`: `ExportRunner` reports a
    /// single total, and `ExportRowCounts` is a per-kind breakdown — putting the total into any
    /// one of its buckets would be a fabricated breakdown in the one table that exists to be
    /// trusted. The total is recoverable from the linked `export_jobs` row.
    private func record(templateId: String, startedAt: Date, outcome: ExportOutcome,
                        errorCode: ExportErrorCode? = nil, stage: ExportStage? = nil,
                        jobId: String? = nil, bytesWritten: Int? = nil,
                        manifestSha: ManifestDigest? = nil, destinationId: String?) {
        let run = ExportRun(
            id: ULID.newID(), templateId: templateId, jobId: jobId,
            // §9.5's `shortcut` trigger exists for exactly this caller: "an App Intent / Shortcut
            // ran it (device unlocked)". Never `scheduledOpportunistic` — that would claim BADAN's
            // own background substrate fired when in fact Shortcuts did.
            trigger: .shortcut, startedAt: startedAt, finishedAt: env.now(), outcome: outcome,
            errorCode: errorCode,
            errorDetail: stage.map { ExportErrorDetail(stage: $0) },
            bytesWritten: bytesWritten, rowCounts: nil, destinationId: destinationId,
            manifestSha256: manifestSha)
        // A ledger write that throws must not turn a successful export into a failed intent: the
        // user's file exists either way, and the alternative is telling them the export failed
        // when it did not. The gap this leaves is the one `jobIdsWithoutRun` already surfaces.
        try? runs.insert(run)
    }

    private static func errorCode(for error: Error) -> ExportErrorCode {
        switch error {
        case ExportRunError.sensitiveExportRequiresPassphrase: return .passphraseMissing
        default: return .writeFailed
        }
    }

    // MARK: - Artifact naming

    /// `BADAN_<template>_<YYYYMMDD>-<YYYYMMDD>_<role>.<ext>`.
    ///
    /// The house scheme is `BADAN_<template-or-bundle>_<range>[_partN].<ext>`; `_partN` names
    /// splits of one logical file, which is not what a CSV export produces — it produces four
    /// distinct files (raw, derived, events, manifest). Their on-disk stem is appended as the role
    /// instead, so a Shortcut saving all four to Files gets four self-describing names rather than
    /// four collisions on `raw.csv`. When EPIC-13/14's destination layer introduces a real zipped
    /// bundle, that bundle takes the unsuffixed name and this suffix disappears with it.
    ///
    /// An open range renders as the literal it is (`start`/`end` omitted) rather than as invented
    /// dates: `allTime` has no first day, and stamping today's date on both ends of an all-history
    /// export would misdescribe the file.
    private static func namedFiles(_ urls: [URL], template: ExportTemplate,
                                   start: Date?, end: Date?, now: Date) -> [IntentExportFile] {
        let slug = slugify(template.name)
        let range = rangeToken(start: start, end: end, now: now)
        return urls.map { url in
            let role = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let name = "BADAN_\(slug)_\(range)_\(role)" + (ext.isEmpty ? "" : ".\(ext)")
            return IntentExportFile(url: url, filename: name)
        }
    }

    /// ASCII, filesystem-safe, and never empty. Arabic template names fold away to nothing under
    /// an ASCII filter, so the fallback is the word "export" rather than an empty segment that
    /// would produce `BADAN__20260101-...`.
    private static func slugify(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        var lastWasSeparator = false
        for scalar in folded.unicodeScalars {
            if allowed.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator, !out.isEmpty {
                out.append("-")
                lastWasSeparator = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "export" : String(out.prefix(48))
    }

    private static func rangeToken(start: Date?, end: Date?, now: Date) -> String {
        let tz = TimeZone.current.identifier
        func stamp(_ date: Date) -> String {
            DayAttribution.localDayKey(date, tz: tz).replacingOccurrences(of: "-", with: "")
        }
        switch (start, end) {
        case let (s?, e?): return "\(stamp(s))-\(stamp(e))"
        case let (s?, nil): return "\(stamp(s))-\(stamp(now))"
        case let (nil, e?): return "alltime-\(stamp(e))"
        case (nil, nil): return "alltime"
        }
    }

    // MARK: - File facts

    private static func totalBytes(_ urls: [URL]) -> Int? {
        var total = 0
        var sawAny = false
        for url in urls {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            total += size
            sawAny = true
        }
        return sawAny ? total : nil
    }

    /// SHA-256 of `manifest.json` when the format wrote one as a separate file (CSV does; the JSON
    /// bundle embeds its manifest instead, and hashing the whole bundle would put a different
    /// thing in a field named `manifestSha256`). `nil` is the honest answer in that case.
    private static func manifestDigest(_ urls: [URL]) -> ManifestDigest? {
        guard let manifestURL = urls.first(where: { $0.lastPathComponent == "manifest.json" }),
              let data = try? Data(contentsOf: manifestURL) else { return nil }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ManifestDigest(hex: hex)
    }
}
