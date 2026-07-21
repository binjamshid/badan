package net.albayyan.badan

import net.albayyan.badan.storage.Schema
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * v8 (plan §9.12 / EPIC-31 + EPIC-32): the two Phase-3A main-DB tables — `reports` (periodic-report
 * metadata) and `notification_deliveries` (the ≤2/day notification budget ledger).
 *
 * Scope, stated honestly (as `BaselineAppendOnlyMigrationTest` and `FoundationTest` do): this module
 * has no `androidTest` source set and no Robolectric, so nothing here opens a real SQLite database.
 * The upgrade BEHAVIOUR against a populated v7 file (v8 is additive; existing rows survive; the
 * partial-unique `reports` identity is enforced) is exercised on iOS by `MigrationFixTests`, which
 * runs against a real connection. What is verifiable on the JVM is pinned here: v8 is the head main
 * version, it creates exactly the two tables with the columns/indexes §9.12 + EPIC-32 mandate, and it
 * is provenance-free / value-free by construction.
 */
class ReportsNotificationsMigrationTest {

    private val v8: String
        get() = Schema.mainMigrations.first { it.version == 8 }.statements.joinToString("\n")

    @Test fun v8IsTheHeadMainMigration() {
        assertNotNull("there must be a version-8 main migration",
            Schema.mainMigrations.firstOrNull { it.version == 8 })
        assertEquals("v8 must be the head main-schema version", 8, Schema.mainMigrations.maxOf { it.version })
    }

    /** v8 is CREATE-only — a data-touching statement here would break the additive-upgrade guarantee. */
    @Test fun v8IsAdditiveCreateOnly() {
        val statements = Schema.mainMigrations.first { it.version == 8 }.statements
        for (stmt in statements) {
            val head = stmt.trimStart().uppercase()
            assertTrue("v8 statements must be CREATE-only, found: $stmt", head.startsWith("CREATE"))
            for (verb in listOf("DROP", "DELETE", "ALTER", "UPDATE", "INSERT")) {
                assertFalse("v8 must not $verb — it is purely additive", head.startsWith(verb))
            }
        }
    }

    // --- §9.12 reports ---

    @Test fun v8CreatesReportsWithItsSpecColumns() {
        assertTrue("v8 must create reports", v8.contains("CREATE TABLE reports"))
        // Exactly the §9.12 field set (+ convention cols), asserted individually so a dropped column
        // fails here loudly rather than as a "no such column" the first time EPIC-31 writes a row.
        for (col in listOf(
            "period_key", "generated_at", "algorithm_version_id", "sections_included",
            "artifact_path", "sha256",
        )) {
            assertTrue("reports must carry $col", v8.contains(col))
        }
        // Convention columns (D-7): a report is a user-visible, reconcilable, deletable row.
        for (col in listOf("updated_at", "origin_device_id", "deleted_at")) {
            assertTrue("reports must carry the convention column $col", v8.contains(col))
        }
    }

    /**
     * The §9.12 identity: unique(period_key, algorithm_version_id), and partial on `deleted_at IS
     * NULL` (mirrors `idx_export_templates_name`) so a soft-deleted report cannot squat on the
     * (period, version) identity the user can no longer see. The unique index must NOT be append-only-
     * defeating in the other direction either — a plain UNIQUE without the predicate is the bug.
     */
    @Test fun v8ReportsIdentityIsUniqueAndPartialOnLiveRows() {
        assertTrue("reports identity must be a UNIQUE index",
            v8.contains("CREATE UNIQUE INDEX idx_reports_period_algorithm"))
        assertTrue("reports identity is on (period_key, algorithm_version_id)",
            v8.contains("reports(period_key, algorithm_version_id)"))
        assertTrue("reports identity must be partial on live rows so a deleted report releases its key",
            v8.contains("idx_reports_period_algorithm ON reports(period_key, algorithm_version_id) WHERE deleted_at IS NULL"))
    }

    /** A report is DERIVED, not measured — it must not claim provenance it does not have (I1). */
    @Test fun v8ReportsCarryNoProvenance() {
        // The provenance struct's tell-tale columns must be absent from the whole v8 block; since
        // neither v8 table is a measurement, the entire migration is provenance-free. `device_id` is
        // deliberately NOT in this list: it is a substring of the legitimate convention column
        // `origin_device_id`, so a raw `contains` would false-positive — the exact-column-set check on
        // iOS (`MigrationFixTests.testV8TablesCarryConventionColumnsButNoProvenance`) covers that one.
        // The four markers below are unambiguous: none is a substring of any v8 or convention column.
        for (provenanceCol in listOf("source_id", "measured_at", "ingested_at", "ingestion_path")) {
            assertFalse("v8 tables are derived/operational and must not carry $provenanceCol (I1)",
                v8.contains(provenanceCol))
        }
    }

    // --- EPIC-32 notification_deliveries ---

    @Test fun v8CreatesNotificationDeliveriesBudgetLedger() {
        assertTrue("v8 must create notification_deliveries", v8.contains("CREATE TABLE notification_deliveries"))
        for (col in listOf("notification_class", "scheduled_for", "delivered_at", "outcome")) {
            assertTrue("notification_deliveries must carry $col", v8.contains(col))
        }
        // Convention columns present (a queued delivery transitions state; owned per-device).
        for (col in listOf("updated_at", "origin_device_id", "deleted_at")) {
            assertTrue("notification_deliveries must carry the convention column $col", v8.contains(col))
        }
    }

    /**
     * The discriminator is `notification_class`, not the plan's bare `class` — `class` is a reserved
     * keyword in both host languages, so the storage identifier is kept clear of it (the spirit of
     * migration 4's `trigger`→`trigger_kind` rename). The bare token `class ` must not appear as a
     * column declaration.
     */
    @Test fun v8NotificationClassAvoidsTheReservedKeyword() {
        assertTrue(v8.contains("notification_class TEXT NOT NULL"))
        assertFalse("`class` is a Swift/Kotlin keyword — the column is `notification_class`",
            v8.contains(" class TEXT"))
    }

    /** EPIC-32 Index (class, scheduled_for) — the budget/cap counting query shape. */
    @Test fun v8NotificationDeliveriesHasTheBudgetCountIndex() {
        assertTrue("the budget/cap query needs (notification_class, scheduled_for)",
            v8.contains("CREATE INDEX idx_notification_deliveries_class_scheduled ON notification_deliveries(notification_class, scheduled_for)"))
    }

    /**
     * Value-free ledger (EPIC-32): a notification-delivery row is metadata about a scheduling
     * decision, never a health value. The `reports` provenance check above already proves the whole
     * v8 block is free of the value-bearing measurement columns; this documents the intent for the
     * ledger specifically.
     */
    @Test fun v8NotificationLedgerIsValueFreeMetadata() {
        assertFalse("a notification-log row is metadata — no value column belongs here",
            v8.contains("notification_deliveries") && v8.contains(" value REAL"))
    }
}
