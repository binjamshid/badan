import XCTest
@testable import BADAN

/// EPIC-14 — the Files/iCloud folder destination: naming convention, security-scoped bookmark
/// resolution, the write+delete verification ping, and the failure model.
///
/// Two of these are load-bearing rather than incidental:
///  - `testSlugKeepsArabicButStripsBidiControls` is what keeps VS-5 ("Arabic is not a second-class
///    locale") true in storage identity — an Arabic template name must produce a distinguishable
///    filename, and an embedded bidi override must never reach one.
///  - `testStaleBookmarkReportsUnreachableAndNeedsRepick` pins §12 EPIC-14's failure model: an
///    unresolvable bookmark is `unreachable` + re-pick, never a crash and never a silent skip.
///
/// The naming tests are the cross-platform contract: the exact strings asserted here are asserted
/// character-for-character by `ExportDestinationsTest.kt`, so a drift on either platform fails a
/// fixture rather than a user's export folder.
final class ExportDestinationsTests: XCTestCase {

    private let deviceId = "test-device"
    // 2026-07-03 12:00:00 UTC — a date whose UTC and a west-of-UTC local day differ, so the
    // timezone argument is actually exercised rather than incidentally correct.
    private let runDate = Date(timeIntervalSince1970: 1_783_080_000)
    private let utc = TimeZone(identifier: "UTC")!

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Folder scheme

    func testFolderSchemeIsYearThenMonthUnderBADANExports() {
        XCTAssertEqual(ExportArtifactNaming.folderComponents(runDate: runDate, timeZone: utc),
                       ["BADAN", "Exports", "2026", "07"])
        XCTAssertEqual(ExportArtifactNaming.folderPath(runDate: runDate, timeZone: utc),
                       "BADAN/Exports/2026/07")
    }

    func testFolderIsBucketedByRunInstantInTheGivenZone() {
        // 2026-01-01 00:30 UTC is still 2025-12-31 in a -05:00 zone: the month folder must follow
        // the user's local wall clock, not UTC, or a late-night export files under next month.
        let newYearUTC = Date(timeIntervalSince1970: 1_767_227_400)
        let eastern = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(ExportArtifactNaming.folderComponents(runDate: newYearUTC, timeZone: eastern),
                       ["BADAN", "Exports", "2025", "12"])
    }

    // MARK: - File naming

    func testFileNameMatchesTheHouseConvention() {
        let start = Date(timeIntervalSince1970: 1_782_000_000) // 2026-06-21 00:00 UTC
        let end = Date(timeIntervalSince1970: 1_783_080_000)   // 2026-07-03 12:00 UTC
        XCTAssertEqual(
            ExportArtifactNaming.fileName(label: "Weekly vitals", start: start, end: end,
                                          fileExtension: "csv", timeZone: utc),
            "BADAN_Weekly-vitals_20260621-20260703.csv")
    }

    func testFileNameCarriesPartSuffixOnlyWhenSplit() {
        let d = runDate
        XCTAssertEqual(
            ExportArtifactNaming.fileName(label: "logs", start: d, end: d, part: 2,
                                          fileExtension: "json", timeZone: utc),
            "BADAN_logs_20260703-20260703_part2.json")
        // part 0 is nonsense (a reader seeing _part0 reads a bug); it is dropped, not written.
        XCTAssertEqual(
            ExportArtifactNaming.fileName(label: "logs", start: d, end: d, part: 0,
                                          fileExtension: "json", timeZone: utc),
            "BADAN_logs_20260703-20260703.json")
    }

    func testNilLabelFilesUnderBundle() {
        XCTAssertEqual(ExportArtifactNaming.slug(nil), "bundle")
    }

    // MARK: - Slug (VS-5)

    func testSlugKeepsArabicButStripsBidiControls() {
        // A mixed Arabic name keeps its letters (never transliterated), so two Arabic-named
        // templates produce two distinguishable files.
        XCTAssertEqual(ExportArtifactNaming.slug("تقرير أسبوعي"), "تقرير-أسبوعي")
        // An embedded RLO (U+202E) — the "filename looks like one type, opens as another" attack —
        // is removed; the surrounding letters survive.
        XCTAssertEqual(ExportArtifactNaming.slug("a\u{202E}b"), "ab")
        // FSI/PDI isolates (U+2066/U+2069) are stripped from storage identity even though they are
        // correct in display copy (see DestinationMessages.isolated for the other side of this).
        XCTAssertEqual(ExportArtifactNaming.slug("\u{2066}x\u{2069}"), "x")
    }

    func testSlugStripsPathSeparatorsAndReservedCharacters() {
        // A slash must not let a name escape its directory.
        XCTAssertEqual(ExportArtifactNaming.slug("a/b\\c"), "a-b-c")
        // The convention's own separator collapses rather than producing empty fields.
        XCTAssertEqual(ExportArtifactNaming.slug("weekly_vitals"), "weekly-vitals")
        XCTAssertEqual(ExportArtifactNaming.slug(":*?\"<>|"), "bundle")
        // Leading dot (would hide the file) is trimmed.
        XCTAssertEqual(ExportArtifactNaming.slug(".hidden"), "hidden")
    }

    func testSlugIsLengthBounded() {
        let long = String(repeating: "x", count: 200)
        XCTAssertLessThanOrEqual(ExportArtifactNaming.slug(long).count,
                                 ExportArtifactNaming.maxSlugLength)
    }

    func testDateStampIsAlwaysAsciiDigits() {
        // The one place the Arabic-numeral preference must not reach: a filename is storage
        // identity, and Arabic-Indic digits would not sort or glob with English-digit siblings.
        let stamp = ExportArtifactNaming.dateStamp(runDate, timeZone: utc)
        XCTAssertEqual(stamp, "20260703")
        XCTAssertTrue(stamp.allSatisfy { $0.isASCII && $0.isNumber })
    }

    // MARK: - Enrollment

    func testEnrollmentMintsAResolvableDestination() throws {
        let store = InMemoryFolderBookmarkStore()
        let folder = try makeFolder("target")
        let result = FolderDestinationEnrollment.enroll(
            pickedURL: folder, destinationId: "DEST01", displayName: "My folder",
            now: runDate, originDeviceId: deviceId, into: store)

        let enrolled = try result.get()
        XCTAssertEqual(enrolled.destination.kind, .fileFolder)
        XCTAssertEqual(enrolled.destination.config.folderBookmarkRef, enrolled.bookmarkRef)
        XCTAssertNil(enrolled.destination.credentialRef)
        XCTAssertEqual(enrolled.destination.tlsPolicy, .notApplicable)
        // Not "verified" merely because it was picked — the ping has to earn that.
        XCTAssertNil(enrolled.destination.lastVerifiedAt)
        XCTAssertNotNil(store.bookmark(for: enrolled.bookmarkRef))
    }

    func testRepickReusesTheSameBookmarkRefSoCursorsSurvive() throws {
        let store = InMemoryFolderBookmarkStore()
        let first = try FolderDestinationEnrollment.enroll(
            pickedURL: try makeFolder("a"), destinationId: "DEST01", displayName: "A",
            now: runDate, originDeviceId: deviceId, into: store).get()
        let second = try FolderDestinationEnrollment.enroll(
            pickedURL: try makeFolder("b"), destinationId: "DEST01", displayName: "B",
            now: runDate, originDeviceId: deviceId, into: store).get()
        // Same destination id → same ref → the ExportCursor keyed on this destination keeps working.
        XCTAssertEqual(first.bookmarkRef, second.bookmarkRef)
    }

    func testEnrollmentFailsWhenBookmarkCannotBeStored() throws {
        let store = InMemoryFolderBookmarkStore()
        store.failWrites = true
        let result = FolderDestinationEnrollment.enroll(
            pickedURL: try makeFolder("x"), destinationId: "DEST01", displayName: "X",
            now: runDate, originDeviceId: deviceId, into: store)
        // A row whose bookmark did not persist would outlive its access — refused rather than
        // returned as a destination that is already broken.
        XCTAssertEqual(result.error(), .bookmarkNotStored)
    }

    // MARK: - Verification ping

    func testVerifyProbesWritableFolderAndLeavesNothingBehind() async throws {
        let (destination, store) = try enrolled(folderName: "verify-ok")
        let subject = FileFolderDestination(bookmarks: store)

        let probe = await subject.verify(destination, now: runDate)
        XCTAssertEqual(probe.status, .ok)
        XCTAssertTrue(probe.isWritable)
        XCTAssertNil(probe.errorCode)
        XCTAssertFalse(probe.needsRepick)
        // The probe file was cleaned up — a real write+delete, not a lingering marker.
        let probePath = try folderURL(store, destination)
            .appending(components: ["BADAN", "Exports", "2026", "07"])
            .appendingPathComponent(FileFolderDestination.probeFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probePath.path))
    }

    func testVerifyReportsDisabledWithoutTouchingTheFolder() async throws {
        let (base, store) = try enrolled(folderName: "verify-disabled")
        var destination = base
        destination.status = .disabled
        let probe = await FileFolderDestination(bookmarks: store).verify(destination, now: runDate)
        XCTAssertEqual(probe.status, .disabled)
        XCTAssertEqual(probe.errorCode, .destinationDisabled)
    }

    func testStaleBookmarkReportsUnreachableAndNeedsRepick() async throws {
        // §12 EPIC-14 failure model: garbage bookmark bytes stand in for a bookmark whose target
        // is gone (volume unmounted, folder moved, iCloud evicted) — the resolution throws.
        let store = InMemoryFolderBookmarkStore()
        let ref = FolderDestinationEnrollment.bookmarkRef(for: "DEST01")
        store.store(Data([0x00, 0x01, 0x02, 0x03]), for: ref)
        let destination = ExportDestination(
            id: "DEST01", kind: .fileFolder, displayName: "gone",
            config: ExportDestinationConfig(folderBookmarkRef: ref),
            createdAt: runDate, updatedAt: runDate, originDeviceId: deviceId)

        let probe = await FileFolderDestination(bookmarks: store).verify(destination, now: runDate)
        XCTAssertEqual(probe.status, .unreachable)
        XCTAssertEqual(probe.errorCode, .destinationUnreachable)
        XCTAssertTrue(probe.needsRepick)
    }

    func testMissingBookmarkRefReportsNeedsRepick() async throws {
        let destination = ExportDestination(
            id: "DEST01", kind: .fileFolder, displayName: "unset",
            config: ExportDestinationConfig(), // no folderBookmarkRef
            createdAt: runDate, updatedAt: runDate, originDeviceId: deviceId)
        let probe = await FileFolderDestination(bookmarks: InMemoryFolderBookmarkStore())
            .verify(destination, now: runDate)
        XCTAssertEqual(probe.status, .unreachable)
        XCTAssertTrue(probe.needsRepick)
    }

    // MARK: - Delivery

    func testDeliverWritesEveryArtifactUnderTheFolderScheme() async throws {
        let (destination, store) = try enrolled(folderName: "deliver-ok")
        let artifacts = try [makeArtifact("BADAN_vitals_20260701-20260703.csv", "a,b,c\n"),
                             makeArtifact("BADAN_vitals_20260701-20260703_manifest.json", "{}")]
        let request = ExportDeliveryRequest(destination: destination, artifacts: artifacts,
                                            runDate: runDate, timeZone: utc)

        let receipt = await FileFolderDestination(bookmarks: store).deliver(request, now: runDate)
        XCTAssertEqual(receipt.outcome, .success)
        XCTAssertEqual(receipt.relativePath, "BADAN/Exports/2026/07")
        XCTAssertNotNil(receipt.deliveredAt)
        XCTAssertEqual(receipt.destinationStatus, .ok)

        let dir = try folderURL(store, destination).appending(components: ["BADAN", "Exports", "2026", "07"])
        for artifact in artifacts {
            let landed = dir.appendingPathComponent(artifact.fileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path), artifact.fileName)
        }
        // Byte count is the sum of what actually landed.
        XCTAssertEqual(receipt.bytesDelivered, artifacts.reduce(0) { $0 + $1.byteCount })
    }

    func testDeliverIsIdempotentForDirectoryCreation() async throws {
        let (destination, store) = try enrolled(folderName: "deliver-twice")
        let subject = FileFolderDestination(bookmarks: store)
        let request = ExportDeliveryRequest(
            destination: destination,
            artifacts: [try makeArtifact("BADAN_x_20260703-20260703.csv", "x\n")],
            runDate: runDate, timeZone: utc)
        _ = await subject.deliver(request, now: runDate)
        // A second export in the same month must not fail on the already-existing directory.
        let second = await subject.deliver(request, now: runDate)
        XCTAssertEqual(second.outcome, .success)
    }

    func testDeliverEmptyArtifactsIsSkippedNoData() async throws {
        let (destination, store) = try enrolled(folderName: "deliver-empty")
        let request = ExportDeliveryRequest(destination: destination, artifacts: [],
                                            runDate: runDate, timeZone: utc)
        let receipt = await FileFolderDestination(bookmarks: store).deliver(request, now: runDate)
        // "Nothing to send" is its own answer, not a success and not a failure.
        XCTAssertEqual(receipt.outcome, .skippedNoData)
        XCTAssertEqual(receipt.bytesDelivered, 0)
        XCTAssertNil(receipt.deliveredAt)
    }

    func testDeliverToDisabledDestinationFailsWithDisabledCode() async throws {
        let (base, store) = try enrolled(folderName: "deliver-disabled")
        var destination = base
        destination.status = .disabled
        let request = ExportDeliveryRequest(
            destination: destination,
            artifacts: [try makeArtifact("BADAN_x_20260703-20260703.csv", "x\n")],
            runDate: runDate, timeZone: utc)
        let receipt = await FileFolderDestination(bookmarks: store).deliver(request, now: runDate)
        XCTAssertEqual(receipt.outcome, .failedDelivery)
        XCTAssertEqual(receipt.errorCode, .destinationDisabled)
    }

    func testDeliverWithMissingSourceFileIsPartialWithoutBlamingTheDestination() async throws {
        let (destination, store) = try enrolled(folderName: "deliver-partial")
        let good = try makeArtifact("BADAN_a_20260703-20260703.csv", "a\n")
        // A source file that does not exist — the second artifact fails on read. This is a staging
        // problem, not the destination's fault, so it must not mark the folder unreachable or ask
        // for a re-pick.
        let missing = ExportArtifact(
            sourceURL: tempDir.appendingPathComponent("does-not-exist.csv"),
            fileName: "BADAN_b_20260703-20260703.csv", byteCount: 10)
        let request = ExportDeliveryRequest(destination: destination, artifacts: [good, missing],
                                            runDate: runDate, timeZone: utc)
        let receipt = await FileFolderDestination(bookmarks: store).deliver(request, now: runDate)
        // One landed, one did not: partial, with the honest 1-of-2 count in the value-free detail.
        XCTAssertEqual(receipt.outcome, .partial)
        XCTAssertEqual(receipt.errorCode, .writeFailed)
        XCTAssertEqual(receipt.destinationStatus, .ok)
        XCTAssertFalse(receipt.needsRepick)
        XCTAssertEqual(receipt.errorDetail.filesWritten, 1)
        XCTAssertEqual(receipt.errorDetail.filesExpected, 2)
        XCTAssertEqual(receipt.bytesDelivered, good.byteCount)
        XCTAssertNotNil(receipt.deliveredAt)
    }

    // MARK: - Helpers

    private func makeFolder(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeArtifact(_ fileName: String, _ contents: String) throws -> ExportArtifact {
        let src = tempDir.appendingPathComponent("src-\(UUID().uuidString)-\(fileName)")
        let data = Data(contents.utf8)
        try data.write(to: src)
        return ExportArtifact(sourceURL: src, fileName: fileName, byteCount: data.count)
    }

    /// Enroll a real temp folder and return the destination plus the store holding its bookmark.
    private func enrolled(folderName: String) throws -> (ExportDestination, InMemoryFolderBookmarkStore) {
        let store = InMemoryFolderBookmarkStore()
        let folder = try makeFolder(folderName)
        let enrolled = try FolderDestinationEnrollment.enroll(
            pickedURL: folder, destinationId: "DEST-\(folderName)", displayName: folderName,
            now: runDate, originDeviceId: deviceId, into: store).get()
        return (enrolled.destination, store)
    }

    private func folderURL(_ store: InMemoryFolderBookmarkStore,
                           _ destination: ExportDestination) throws -> URL {
        let ref = try XCTUnwrap(destination.config.folderBookmarkRef)
        let data = try XCTUnwrap(store.bookmark(for: ref))
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                       bookmarkDataIsStale: &stale)
    }
}

private extension Result {
    func error() -> Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}

private extension URL {
    func appending(components: [String]) -> URL {
        components.reduce(self) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}
