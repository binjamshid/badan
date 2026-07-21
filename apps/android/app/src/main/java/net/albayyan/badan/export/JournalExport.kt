package net.albayyan.badan.export

import net.albayyan.badan.domain.journal.ContextStatus
import net.albayyan.badan.domain.journal.JournalEntry

/**
 * The journal slice of an export: the behavior tags and the declared context intervals (EPIC-29,
 * plan §9.9/§9.10). Assembled by [ExportRunner] (or a test) and handed to [JsonBundleWriter] as
 * `logs.journal[]` / `logs.context_statuses[]`. Mirror of iOS `JournalExportPayload`.
 *
 * **Sensitive-plus, both families (I7).** A payload is only ever built for a scope whose
 * `includeSensitive` is set; the runner's gather is what enforces that. Nothing in the writers
 * re-checks consent — a writer that quietly re-derived the gate would be a second, drifting copy
 * of it.
 *
 * The two arrays are kept separate rather than merged into one "journal" block because they answer
 * different questions and are keyed independently in the bundle: a user who declared a travel
 * status but tapped no chips exports `context_statuses` and no `journal`.
 */
data class JournalExportPayload(
    val entries: List<JournalEntry> = emptyList(),
    val statuses: List<ContextStatus> = emptyList(),
) {
    val isEmpty: Boolean get() = entries.isEmpty() && statuses.isEmpty()
}
