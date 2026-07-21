import Foundation

/// The hydration slice of an export: the live ledger, the day summaries, the goals, and the beverage
/// catalog the entries reference. Assembled by a caller (the export orchestrator, or a test) and
/// handed to `JSONBundleWriter` (as `logs.hydration`) and `HydrationCSVWriter` (as its own CSV set).
///
/// `entries` are expected to be the LIVE set (`HydrationLedger.liveEntries`) unless a caller
/// deliberately exports history; the writers do not re-derive liveness, they serialize what they are
/// given. `beverages` are the custom definitions referenced, so the artifact can name a drink without
/// the reader needing `beverages.json`.
struct HydrationExportPayload {
    var entries: [HydrationEntry]
    var summaries: [HydrationDailySummary]
    var goals: [HydrationGoal]
    var beverages: [BeverageDefinition]

    var isEmpty: Bool { entries.isEmpty && summaries.isEmpty && goals.isEmpty && beverages.isEmpty }

    init(entries: [HydrationEntry] = [], summaries: [HydrationDailySummary] = [],
         goals: [HydrationGoal] = [], beverages: [BeverageDefinition] = []) {
        self.entries = entries; self.summaries = summaries; self.goals = goals; self.beverages = beverages
    }
}

/// What the hydration export withholds by default. §7A.1 makes the default export a **privacy default,
/// structural**: notes, and any fasting / cycle / pregnancy context, location, and reminder history,
/// are excluded unless the user explicitly opts each back in. Everything except `includeNotes` is a
/// fixed exclusion this phase because the module does not yet store those contexts at all — they are
/// listed so the redaction manifest tells the reader exactly what a default file leaves out, rather
/// than the omission being invisible.
struct HydrationRedactionPolicy {
    /// The one field the ledger actually stores today that is redacted by default. Off = the `note`
    /// column/key is absent from the artifact entirely (structural, not blanked).
    var includeNotes: Bool = false

    static let `default` = HydrationRedactionPolicy()

    /// The fields a default export excludes, for the redaction manifest. `note` is dropped only while
    /// `includeNotes` is false; the rest are always excluded this phase (not yet modelled).
    var excludedFields: [String] {
        var fields: [String] = []
        if !includeNotes { fields.append("note") }
        fields += ["fasting_context", "cycle_context", "pregnancy_context", "location", "reminder_history"]
        return fields
    }
}

/// Renders the hydration export's CSV set — one small, self-describing table per aspect (entries,
/// summaries, goals, sources), separate from the 26-column main contract (a drink ledger is a
/// different shape). RFC-4180 escaping and number/timestamp formatting are borrowed from `CSVWriter`
/// so hydration cells format identically to every other exported cell.
///
/// The default set **excludes notes structurally**: the `note` column only exists when the policy
/// opts it in, so a note cannot leak into a default CSV even as an empty cell. `redactionManifest`
/// is the machine-readable statement of what was left out.
struct HydrationCSVWriter {
    let policy: HydrationRedactionPolicy

    init(policy: HydrationRedactionPolicy = .default) { self.policy = policy }

    /// The named CSV files for one export (plus the redaction manifest). Basenames are `hydration_*`
    /// so they never collide with the main export's `raw.csv`/`derived.csv`/`events.csv`.
    func files(_ payload: HydrationExportPayload) -> [String: String] {
        [
            "hydration_entries.csv": entriesCSV(payload.entries),
            "hydration_summaries.csv": summariesCSV(payload.summaries),
            "hydration_goals.csv": goalsCSV(payload.goals),
            "hydration_sources.csv": sourcesCSV(payload.entries),
            "hydration_redaction.json": redactionManifest(),
        ]
    }

    /// Entries. `note` is present only when opted in — the structural redaction. `volume_ml` is
    /// canonical mL always (the ledger has no display-unit profile).
    func entriesCSV(_ entries: [HydrationEntry]) -> String {
        var columns = ["record_id", "original_id", "supersedes", "revision", "volume_ml", "canonical_unit",
                       "fluid_type", "beverage_id", "container_id", "occurred_at", "timezone",
                       "ingestion_path", "source_app", "updated_at", "deleted_at"]
        if policy.includeNotes { columns.append("note") }
        var out = row(columns)
        for e in entries {
            var cells = [e.id, e.originalId, e.supersedes ?? "", String(e.revision),
                         CSVWriter.decimal(e.volumeMl), "mL", e.fluidType, e.beverageId ?? "", e.containerId ?? "",
                         CSVWriter.iso8601(e.occurredAt, tzId: e.tzId), e.tzId,
                         e.provenance.ingestionPath.rawValue, e.provenance.sourceId,
                         CSVWriter.iso8601(e.updatedAt, tzId: e.tzId),
                         e.deletedAt.map { CSVWriter.iso8601($0, tzId: e.tzId) } ?? ""]
            if policy.includeNotes { cells.append(e.note ?? "") }
            out += CSVWriter.newline + row(cells)
        }
        return out + CSVWriter.newline
    }

    /// Summaries. Manual / imported / estimated stay separate columns (I5); `goal_progress_pct` is
    /// blank for a no-goal day (never 0) so a percentage of nothing is never fabricated.
    func summariesCSV(_ summaries: [HydrationDailySummary]) -> String {
        var out = row(["day_key", "timezone", "manual_ml", "imported_ml", "estimated_ml", "total_ml",
                       "entry_count", "goal_kind", "goal_target_ml", "goal_progress_pct"])
        for s in summaries {
            out += CSVWriter.newline + row([
                s.dayKey, s.tzId, CSVWriter.decimal(s.manualMl), CSVWriter.decimal(s.importedMl),
                CSVWriter.decimal(s.estimatedMl), CSVWriter.decimal(s.totalMl), String(s.entryCount),
                s.goalKind.rawValue, s.goalTargetMl.map { CSVWriter.decimal($0) } ?? "",
                s.goalProgressPct.map { CSVWriter.decimal($0) } ?? "",
            ])
        }
        return out + CSVWriter.newline
    }

    /// Goals. `target_ml` blank for a no-goal row — the equal-status default reads as "tracking, no
    /// target", not as a missing value.
    func goalsCSV(_ goals: [HydrationGoal]) -> String {
        var out = row(["goal_id", "kind", "target_ml", "day_type", "active", "created_at"])
        for g in goals {
            out += CSVWriter.newline + row([
                g.id, g.kind.rawValue, g.targetMl.map { CSVWriter.decimal($0) } ?? "", g.dayType ?? "",
                g.active ? "true" : "false", CSVWriter.iso8601(g.createdAt, tzId: "UTC"),
            ])
        }
        return out + CSVWriter.newline
    }

    /// Sources: the provenance apps/paths the entries came from, aggregated — the same "where did this
    /// come from" answer the main export's source dictionary gives, scoped to hydration.
    func sourcesCSV(_ entries: [HydrationEntry]) -> String {
        var paths: [String: Set<String>] = [:]
        var counts: [String: Int] = [:]
        for e in entries {
            paths[e.provenance.sourceId, default: []].insert(e.provenance.ingestionPath.rawValue)
            counts[e.provenance.sourceId, default: 0] += 1
        }
        var out = row(["source_app", "ingestion_paths", "entry_count"])
        for sourceId in paths.keys.sorted() {
            out += CSVWriter.newline + row([sourceId, paths[sourceId]!.sorted().joined(separator: ";"), String(counts[sourceId] ?? 0)])
        }
        return out + CSVWriter.newline
    }

    /// The machine-readable statement of what the default export left out (§7A.1). Rendered through
    /// `CanonicalJSON` so it byte-matches the JSON bundle's embedded `logs.hydration.redaction`.
    func redactionManifest() -> String {
        HydrationExportJSON.redaction(policy).render()
    }

    private func row(_ cells: [String]) -> String {
        cells.map(CSVWriter.escape).joined(separator: ",")
    }
}
