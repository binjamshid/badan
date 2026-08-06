package net.albayyan.badan.contracts

/**
 * Skeleton marker for the `:contracts` module (B1-1). Batch 2 replaces the body of this module
 * with the real ambient-snapshot DTO tree, its `schemaVersion`, and the Wear DataClient path /
 * message-key constants; this file exists so the module has a package, a source root and a
 * non-empty `compileKotlin` task from the moment it is declared, rather than being a directory
 * that only starts being verified once someone puts code in it.
 *
 * The invariant this module carries — and the reason it is a pure `kotlin("jvm")` module with no
 * Android Gradle plugin — is stated in ADR-0012: `:contracts` cannot reach `Context`, SQLite or
 * Health Connect, and `:wear` may depend on `:contracts` and on nothing else of BADAN's. The watch
 * renders truth the phone computed; it is not a second place a score is computed.
 */
public object ContractsModule {
    /** Gradle path of this module, used by `:wear`'s dependency-boundary check. */
    public const val GRADLE_PATH: String = ":contracts"
}
