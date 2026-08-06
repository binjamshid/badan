package net.albayyan.badan.wear

import net.albayyan.badan.contracts.ContractsModule

/**
 * Skeleton marker for the `:wear` module (B1-1). The watch surfaces — the tile, the complications
 * and the Compose screens — are later batches; this file exists so `:wear:compileDebugKotlin` is a
 * real compilation from the moment the module is declared, and so the one dependency edge that is
 * allowed to exist ([ContractsModule]) is actually exercised by the compiler rather than only
 * asserted by a Gradle task.
 *
 * The rule this module lives under, from ADR-0012: the watch is a **renderer of phone-computed
 * truth**, not a second place any score is computed. `:wear` may see `:contracts` — the ambient
 * snapshot DTO and the DataClient path constants — and nothing else of BADAN's.
 * `:wear:checkWearDependencyBoundary` fails the build if that stops being true.
 */
internal object WearModule {
    /** The one BADAN module this one is permitted to depend on. */
    const val CONTRACTS_PATH: String = ContractsModule.GRADLE_PATH
}
