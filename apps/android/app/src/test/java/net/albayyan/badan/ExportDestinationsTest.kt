package net.albayyan.badan

import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportDestinationConfig
import net.albayyan.badan.domain.ExportDestinationKind
import net.albayyan.badan.domain.ExportDestinationStatus
import net.albayyan.badan.domain.ExportErrorCode
import net.albayyan.badan.domain.ExportOutcome
import net.albayyan.badan.domain.ExportStage
import net.albayyan.badan.export.destinations.ExportArtifact
import net.albayyan.badan.export.destinations.ExportArtifactNaming
import net.albayyan.badan.export.destinations.ExportDeliveryRequest
import net.albayyan.badan.export.destinations.FileFolderDestination
import net.albayyan.badan.export.destinations.FolderDestinationEnrollment
import net.albayyan.badan.export.destinations.InMemoryTreeUriStore
import net.albayyan.badan.export.destinations.TreeDocumentGateway
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.TimeZone

/**
 * EPIC-14 — the SAF folder destination.
 *
 * Scope, stated honestly (the same caveat `ExportTemplateSystemTest` carries): this module has no
 * androidTest source set and no Robolectric, so nothing here touches a real ContentResolver. The
 * SAF calls live behind [TreeDocumentGateway], and everything with a decision in it — the naming
 * convention, enrollment's rules, the write+delete probe, the failure classification — runs against
 * [FakeTreeDocumentGateway] here. `ContentResolverTreeDocumentGateway` (the thin part below the
 * seam) is exercised only on device.
 *
 * The naming assertions are the cross-platform contract: the exact strings pinned here are pinned
 * character-for-character by iOS `ExportDestinationsTests.swift`, so a drift on either platform
 * fails a fixture rather than a user's export folder.
 */
class ExportDestinationsTest {

    @get:Rule val temp = TemporaryFolder()

    private val deviceId = "test-device"

    // 2026-07-03 12:00:00 UTC.
    private val runDate = 1_783_080_000_000L
    private val utc: TimeZone = TimeZone.getTimeZone("UTC")

    // -- Folder scheme --

    @Test fun folderSchemeIsYearThenMonthUnderBADANExports() {
        assertEquals(
            listOf("BADAN", "Exports", "2026", "07"),
            ExportArtifactNaming.folderComponents(runDate, utc),
        )
        assertEquals("BADAN/Exports/2026/07", ExportArtifactNaming.folderPath(runDate, utc))
    }

    @Test fun folderIsBucketedByRunInstantInTheGivenZone() {
        // 2026-01-01 00:30 UTC is still 2025-12-31 in a -05:00 zone.
        val newYearUtc = 1_767_227_400_000L
        val eastern = TimeZone.getTimeZone("America/New_York")
        assertEquals(
            listOf("BADAN", "Exports", "2025", "12"),
            ExportArtifactNaming.folderComponents(newYearUtc, eastern),
        )
    }

    // -- File naming --

    @Test fun fileNameMatchesTheHouseConvention() {
        val start = 1_782_000_000_000L // 2026-06-21 00:00 UTC
        val end = 1_783_080_000_000L   // 2026-07-03 12:00 UTC
        assertEquals(
            "BADAN_Weekly-vitals_20260621-20260703.csv",
            ExportArtifactNaming.fileName("Weekly vitals", start, end, "csv", utc),
        )
    }

    @Test fun fileNameCarriesPartSuffixOnlyWhenSplit() {
        assertEquals(
            "BADAN_logs_20260703-20260703_part2.json",
            ExportArtifactNaming.fileName("logs", runDate, runDate, "json", utc, part = 2),
        )
        // part 0 is nonsense (a reader seeing _part0 reads a bug); it is dropped, not written.
        assertEquals(
            "BADAN_logs_20260703-20260703.json",
            ExportArtifactNaming.fileName("logs", runDate, runDate, "json", utc, part = 0),
        )
    }

    @Test fun nilLabelFilesUnderBundle() {
        assertEquals("bundle", ExportArtifactNaming.slug(null))
    }

    // -- Slug (VS-5) --

    @Test fun slugKeepsArabicButStripsBidiControls() {
        assertEquals("تقرير-أسبوعي", ExportArtifactNaming.slug("تقرير أسبوعي"))
        // An embedded RLO (U+202E) is removed; the surrounding letters survive.
        assertEquals("ab", ExportArtifactNaming.slug("a\u202Eb"))
        // FSI/PDI isolates (U+2066/U+2069) are stripped from storage identity.
        assertEquals("x", ExportArtifactNaming.slug("\u2066x\u2069"))
    }

    @Test fun slugStripsPathSeparatorsAndReservedCharacters() {
        assertEquals("a-b-c", ExportArtifactNaming.slug("a/b\\c"))
        assertEquals("weekly-vitals", ExportArtifactNaming.slug("weekly_vitals"))
        assertEquals("bundle", ExportArtifactNaming.slug(":*?\"<>|"))
        assertEquals("hidden", ExportArtifactNaming.slug(".hidden"))
    }

    @Test fun slugIsLengthBounded() {
        val long = "x".repeat(200)
        assertTrue(ExportArtifactNaming.slug(long).length <= ExportArtifactNaming.MAX_SLUG_LENGTH)
    }

    @Test fun dateStampIsAlwaysAsciiDigits() {
        val stamp = ExportArtifactNaming.dateStamp(runDate, utc)
        assertEquals("20260703", stamp)
        assertTrue(stamp.all { it in '0'..'9' })
    }

    // -- Enrollment --

    @Test fun enrollmentMintsAResolvableDestinationAndTakesTheGrant() {
        val gateway = FakeTreeDocumentGateway()
        val store = InMemoryTreeUriStore()
        val result = FolderDestinationEnrollment.enroll(
            pickedTreeUri = "content://tree/A", destinationId = "DEST01", displayName = "My folder",
            now = runDate, originDeviceId = deviceId, gateway = gateway, store = store,
        )
        val enrolled = result.getOrThrow()
        assertEquals(ExportDestinationKind.FILE_FOLDER, enrolled.destination.kind)
        assertEquals(enrolled.bookmarkRef, enrolled.destination.config.folderBookmarkRef)
        assertNull(enrolled.destination.credentialRef)
        // Not "verified" merely because it was picked — the ping has to earn that.
        assertNull(enrolled.destination.lastVerifiedAt)
        // The persistable grant was taken (survives a reboot) and the URI remembered.
        assertTrue(gateway.hasPersistedWriteGrant("content://tree/A"))
        assertEquals("content://tree/A", store.treeUri(enrolled.bookmarkRef))
    }

    @Test fun repickReusesTheSameRefSoCursorsSurvive() {
        val gateway = FakeTreeDocumentGateway()
        val store = InMemoryTreeUriStore()
        val first = FolderDestinationEnrollment.enroll(
            "content://tree/A", "DEST01", "A", runDate, deviceId, gateway, store,
        ).getOrThrow()
        val second = FolderDestinationEnrollment.enroll(
            "content://tree/B", "DEST01", "B", runDate, deviceId, gateway, store,
        ).getOrThrow()
        // Same destination id → same ref → the ExportCursor keyed on this destination keeps working.
        assertEquals(first.bookmarkRef, second.bookmarkRef)
        assertEquals("content://tree/B", store.treeUri(second.bookmarkRef))
    }

    @Test fun enrollmentFailsWhenGrantIsNotPersistable() {
        val gateway = FakeTreeDocumentGateway().apply { grantThrows = true }
        val store = InMemoryTreeUriStore()
        val result = FolderDestinationEnrollment.enroll(
            "content://tree/A", "DEST01", "X", runDate, deviceId, gateway, store,
        )
        assertTrue(result.isFailure)
        // Nothing was stored — a mapping to a URI we cannot use is the silent failure §12 EPIC-14
        // is written against.
        assertNull(store.treeUri(FolderDestinationEnrollment.bookmarkRef("DEST01")))
    }

    @Test fun forgetReleasesTheGrantAndRemovesTheMapping() {
        val gateway = FakeTreeDocumentGateway()
        val store = InMemoryTreeUriStore()
        val enrolled = FolderDestinationEnrollment.enroll(
            "content://tree/A", "DEST01", "A", runDate, deviceId, gateway, store,
        ).getOrThrow()

        FolderDestinationEnrollment.forget("DEST01", gateway, store)
        assertNull(store.treeUri(enrolled.bookmarkRef))
        assertFalse(gateway.hasPersistedWriteGrant("content://tree/A"))
    }

    // -- Verification ping --

    @Test fun verifyProbesWritableFolderAndLeavesNothingBehind() = runBlocking {
        val (destination, gateway) = enrolled("content://tree/ok")
        val probe = FileFolderDestination(gateway.store, gateway).verify(destination, runDate)
        assertEquals(ExportDestinationStatus.OK, probe.status)
        assertTrue(probe.isWritable)
        assertNull(probe.errorCode)
        assertFalse(probe.needsRepick)
        // The probe file was cleaned up — a real write+delete, not a lingering marker.
        assertFalse(gateway.hasFile(FileFolderDestination.PROBE_FILE_NAME))
    }

    @Test fun verifyReportsWriteBackMismatchAsUnreachable() = runBlocking {
        // A provider that accepts a write, reports success, then drops the bytes — exactly the
        // failure a "did the write throw?" check would certify as healthy.
        val (destination, gateway) = enrolled("content://tree/lying")
        gateway.corruptWrites = true
        val probe = FileFolderDestination(gateway.store, gateway).verify(destination, runDate)
        assertEquals(ExportDestinationStatus.UNREACHABLE, probe.status)
        assertEquals(ExportErrorCode.WRITE_FAILED, probe.errorCode)
    }

    @Test fun verifyReportsDisabledWithoutTouchingTheFolder() = runBlocking {
        val (base, gateway) = enrolled("content://tree/disabled")
        val destination = base.copy(status = ExportDestinationStatus.DISABLED)
        val probe = FileFolderDestination(gateway.store, gateway).verify(destination, runDate)
        assertEquals(ExportDestinationStatus.DISABLED, probe.status)
        assertEquals(ExportErrorCode.DESTINATION_DISABLED, probe.errorCode)
    }

    @Test fun revokedGrantReportsUnreachableAndNeedsRepick() = runBlocking {
        // §12 EPIC-14 failure model: the user or the system revoked the persisted permission.
        val (destination, gateway) = enrolled("content://tree/revoked")
        gateway.revokeGrant("content://tree/revoked")
        val probe = FileFolderDestination(gateway.store, gateway).verify(destination, runDate)
        assertEquals(ExportDestinationStatus.UNREACHABLE, probe.status)
        assertEquals(ExportErrorCode.DESTINATION_UNREACHABLE, probe.errorCode)
        assertTrue(probe.needsRepick)
    }

    @Test fun missingStoredUriReportsNeedsRepick() = runBlocking {
        val gateway = FakeTreeDocumentGateway()
        val destination = ExportDestination(
            id = "DEST01", kind = ExportDestinationKind.FILE_FOLDER, displayName = "unset",
            config = ExportDestinationConfig(folderBookmarkRef = "badan.export.folder.dest01"),
            createdAt = runDate, updatedAt = runDate, originDeviceId = deviceId,
        )
        val probe = FileFolderDestination(gateway.store, gateway).verify(destination, runDate)
        assertEquals(ExportDestinationStatus.UNREACHABLE, probe.status)
        assertTrue(probe.needsRepick)
    }

    // -- Delivery --

    @Test fun deliverWritesEveryArtifactUnderTheFolderScheme() = runBlocking {
        val (destination, gateway) = enrolled("content://tree/deliver")
        val artifacts = listOf(
            artifact("BADAN_vitals_20260701-20260703.csv", "a,b,c\n"),
            artifact("BADAN_vitals_20260701-20260703_manifest.json", "{}"),
        )
        val request = ExportDeliveryRequest(destination, artifacts, runDate, utc)
        val receipt = FileFolderDestination(gateway.store, gateway).deliver(request, runDate)

        assertEquals(ExportOutcome.SUCCESS, receipt.outcome)
        assertEquals("BADAN/Exports/2026/07", receipt.relativePath)
        assertNotNull(receipt.deliveredAt)
        assertEquals(ExportDestinationStatus.OK, receipt.destinationStatus)
        assertEquals(artifacts.sumOf { it.byteCount }, receipt.bytesDelivered)
        for (a in artifacts) assertTrue(a.fileName, gateway.hasFile(a.fileName))
    }

    @Test fun deliverIsIdempotentForFolderCreation() = runBlocking {
        val (destination, gateway) = enrolled("content://tree/twice")
        val subject = FileFolderDestination(gateway.store, gateway)
        val request = ExportDeliveryRequest(
            destination, listOf(artifact("BADAN_x_20260703-20260703.csv", "x\n")), runDate, utc,
        )
        subject.deliver(request, runDate)
        // A second export in the same month must not fail on the already-existing folder.
        val second = subject.deliver(request, runDate)
        assertEquals(ExportOutcome.SUCCESS, second.outcome)
    }

    @Test fun deliverEmptyArtifactsIsSkippedNoData() = runBlocking {
        val (destination, gateway) = enrolled("content://tree/empty")
        val request = ExportDeliveryRequest(destination, emptyList(), runDate, utc)
        val receipt = FileFolderDestination(gateway.store, gateway).deliver(request, runDate)
        assertEquals(ExportOutcome.SKIPPED_NO_DATA, receipt.outcome)
        assertEquals(0L, receipt.bytesDelivered)
        assertNull(receipt.deliveredAt)
    }

    @Test fun deliverToDisabledDestinationFailsWithDisabledCode() = runBlocking {
        val (base, gateway) = enrolled("content://tree/disabled2")
        val destination = base.copy(status = ExportDestinationStatus.DISABLED)
        val request = ExportDeliveryRequest(
            destination, listOf(artifact("BADAN_x_20260703-20260703.csv", "x\n")), runDate, utc,
        )
        val receipt = FileFolderDestination(gateway.store, gateway).deliver(request, runDate)
        assertEquals(ExportOutcome.FAILED_DELIVERY, receipt.outcome)
        assertEquals(ExportErrorCode.DESTINATION_DISABLED, receipt.errorCode)
    }

    @Test fun deliverWithMissingSourceIsPartialWithoutBlamingTheDestination() = runBlocking {
        val (destination, gateway) = enrolled("content://tree/partial")
        val good = artifact("BADAN_a_20260703-20260703.csv", "a\n")
        // A source file that does not exist — the read fails. That is a staging problem, not the
        // destination's fault, so it must not mark the folder unreachable or ask for a re-pick.
        val missing = ExportArtifact(File(temp.root, "does-not-exist.csv"),
            "BADAN_b_20260703-20260703.csv", 10L)
        val request = ExportDeliveryRequest(destination, listOf(good, missing), runDate, utc)
        val receipt = FileFolderDestination(gateway.store, gateway).deliver(request, runDate)

        assertEquals(ExportOutcome.PARTIAL, receipt.outcome)
        assertEquals(ExportErrorCode.WRITE_FAILED, receipt.errorCode)
        assertEquals(ExportDestinationStatus.OK, receipt.destinationStatus)
        assertFalse(receipt.needsRepick)
        assertEquals(1, receipt.errorDetail.filesWritten)
        assertEquals(2, receipt.errorDetail.filesExpected)
        assertEquals(good.byteCount, receipt.bytesDelivered)
        assertNotNull(receipt.deliveredAt)
    }

    // -- Failure classification (the closed-vocabulary mapping) --

    @Test fun classifyMapsFrameworkExceptionsToTheRightCode() {
        val subject = FileFolderDestination(InMemoryTreeUriStore(), FakeTreeDocumentGateway())
        // A revoked grant surfaces as SecurityException → unreachable + re-pick.
        subject.classify(SecurityException("revoked")).let {
            assertEquals(ExportErrorCode.DESTINATION_UNREACHABLE, it.errorCode)
            assertEquals(ExportDestinationStatus.UNREACHABLE, it.destinationStatus)
            assertTrue(it.needsRepick)
        }
        // A deleted folder document → unreachable + re-pick.
        subject.classify(FileNotFoundException("gone")).let {
            assertEquals(ExportErrorCode.DESTINATION_UNREACHABLE, it.errorCode)
            assertTrue(it.needsRepick)
        }
        // SAF gives no ENOSPC code — a full disk is recognizable only by message.
        subject.classify(IOException("No space left on device")).let {
            assertEquals(ExportErrorCode.STORAGE_FULL, it.errorCode)
            assertEquals(ExportDestinationStatus.OK, it.destinationStatus)
            assertFalse(it.needsRepick)
        }
        // An unclassified IOException is writeFailed with the destination left alone.
        subject.classify(IOException("provider hiccup")).let {
            assertEquals(ExportErrorCode.WRITE_FAILED, it.errorCode)
            assertEquals(ExportDestinationStatus.OK, it.destinationStatus)
            assertFalse(it.needsRepick)
        }
    }

    @Test fun deliveringDetailNeverCarriesAValue() {
        // The error detail is value-free by construction — same guard the ledger types carry.
        val (destination, gateway) = enrolled("content://tree/detail")
        val receipt = runBlocking {
            FileFolderDestination(gateway.store, gateway)
                .deliver(ExportDeliveryRequest(destination, emptyList(), runDate, utc), runDate)
        }
        assertEquals(ExportStage.DELIVERING, receipt.errorDetail.stage)
    }

    // -- Helpers --

    private fun artifact(fileName: String, contents: String): ExportArtifact {
        val src = temp.newFile("src-${fileName.replace('/', '_')}")
        src.writeText(contents)
        return ExportArtifact(src, fileName, src.length())
    }

    private fun enrolled(treeUri: String): Pair<ExportDestination, FakeTreeDocumentGateway> {
        val gateway = FakeTreeDocumentGateway()
        val enrolled = FolderDestinationEnrollment.enroll(
            treeUri, "DEST-${treeUri.substringAfterLast('/')}", "folder",
            runDate, deviceId, gateway, gateway.store,
        ).getOrThrow()
        return enrolled.destination to gateway
    }
}

/**
 * In-memory [TreeDocumentGateway]. Carries its own [InMemoryTreeUriStore] so a test can hand the
 * same wiring to both enrollment and the destination. The knobs (grantThrows, corruptWrites,
 * revokeGrant) are how the failure paths are reached without a real provider.
 */
class FakeTreeDocumentGateway : TreeDocumentGateway {
    val store = InMemoryTreeUriStore()
    private val grants = mutableSetOf<String>()
    private val files = mutableMapOf<String, ByteArray>() // "folderDocUri/name" -> bytes

    /** Enrollment's take fails as if the pick carried no persistable flags. */
    var grantThrows = false
    /** A provider that accepts a write then drops the bytes — read-back sees stale content. */
    var corruptWrites = false

    fun revokeGrant(treeUri: String) { grants.remove(treeUri) }
    fun hasFile(name: String): Boolean = files.keys.any { it.endsWith("/$name") }

    override fun hasPersistedWriteGrant(treeUri: String): Boolean = treeUri in grants

    override fun takePersistableGrant(treeUri: String) {
        if (grantThrows) throw SecurityException("no persistable flags")
        grants += treeUri
    }

    override fun releasePersistableGrant(treeUri: String) { grants.remove(treeUri) }

    override fun ensureFolder(treeUri: String, components: List<String>): String {
        if (treeUri !in grants) throw SecurityException("grant revoked")
        return treeUri + "/" + components.joinToString("/")
    }

    override fun putBytes(folderDocUri: String, name: String, bytes: ByteArray) {
        files["$folderDocUri/$name"] = if (corruptWrites) ByteArray(0) else bytes.copyOf()
    }

    override fun getBytes(folderDocUri: String, name: String): ByteArray? = files["$folderDocUri/$name"]

    override fun delete(folderDocUri: String, name: String): Boolean =
        files.remove("$folderDocUri/$name") != null
}
