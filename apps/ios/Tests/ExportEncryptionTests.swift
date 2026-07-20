import XCTest
import CryptoKit
@testable import BADAN

/// Coverage for `ExportEncryptor`/`ExportPassphrasePolicy`, added for review ledger #19's
/// deferred fix 3 (FEAT-185 — see `docs/adr/ADR-0008-export-encryption.md`): encrypt-decrypt
/// round trip, a wrong passphrase failing with a typed error rather than garbage output, a
/// tampered container failing via the GCM tag, and a format-stability fixture proving this build
/// can still open a container produced by an earlier one.
final class ExportEncryptionTests: XCTestCase {

    private let sampleFiles = [
        ExportContainerFile(name: "raw.csv", data: Data("record_id,value\nr1,42\n".utf8)),
        ExportContainerFile(name: "events.csv", data: Data("record_id,metric_id\ne1,symptoms.entry\n".utf8)),
        ExportContainerFile(name: "manifest.json", data: Data(#"{"exportId":"abc"}"#.utf8)),
    ]

    // MARK: - Round trip

    func testEncryptThenDecryptRecoversAllFilesByteExactly() throws {
        let container = try ExportEncryptor.encrypt(files: sampleFiles, passphrase: "a very good passphrase",
                                                     iterations: 1_000)
        let recovered = try ExportEncryptor.decrypt(container, passphrase: "a very good passphrase")

        XCTAssertEqual(recovered.count, sampleFiles.count)
        for original in sampleFiles {
            let match = try XCTUnwrap(recovered.first { $0.name == original.name })
            XCTAssertEqual(match.data, original.data, "\(original.name) must round-trip byte-exactly")
        }
    }

    func testEncryptedContainerStartsWithTheMagicHeader() throws {
        let container = try ExportEncryptor.encrypt(files: sampleFiles, passphrase: "a very good passphrase",
                                                     iterations: 1_000)
        XCTAssertEqual(Array(container.prefix(4)), ExportEncryptor.magic)
        XCTAssertEqual(container[container.startIndex.advanced(by: 4)], ExportEncryptor.formatVersion)
        XCTAssertEqual(container[container.startIndex.advanced(by: 5)], ExportEncryptor.kdfIdPBKDF2SHA256)
    }

    func testEncryptRoundTripWithASingleFile() throws {
        let single = [ExportContainerFile(name: "bundle.json", data: Data(#"{"a":1}"#.utf8))]
        let container = try ExportEncryptor.encrypt(files: single, passphrase: "single-file-passphrase",
                                                     iterations: 1_000)
        let recovered = try ExportEncryptor.decrypt(container, passphrase: "single-file-passphrase")
        XCTAssertEqual(recovered, single)
    }

    /// Two independent encryptions of the same content must not produce the same bytes — proof
    /// the salt and nonce are actually fresh per call, not accidentally fixed/reused.
    func testTwoEncryptionsOfTheSameFilesProduceDifferentContainers() throws {
        let first = try ExportEncryptor.encrypt(files: sampleFiles, passphrase: "same-passphrase", iterations: 1_000)
        let second = try ExportEncryptor.encrypt(files: sampleFiles, passphrase: "same-passphrase", iterations: 1_000)
        XCTAssertNotEqual(first, second, "salt/nonce must be freshly random per encryption")
    }

    // MARK: - Wrong passphrase fails cleanly (typed error)

    func testDecryptWithWrongPassphraseThrowsATypedError() throws {
        let container = try ExportEncryptor.encrypt(files: sampleFiles, passphrase: "the-real-passphrase",
                                                     iterations: 1_000)
        XCTAssertThrowsError(try ExportEncryptor.decrypt(container, passphrase: "totally-wrong-passphrase")) { error in
            XCTAssertEqual(error as? ExportEncryptionError, .incorrectPassphraseOrTamperedData)
        }
    }

    // MARK: - Tampered ciphertext fails (GCM tag)

    func testDecryptOfTamperedCiphertextFails() throws {
        var container = try ExportEncryptor.encrypt(files: sampleFiles, passphrase: "the-real-passphrase",
                                                     iterations: 1_000)
        // Flip one byte well inside the ciphertext (past the fixed header), simulating bit-rot
        // or an attacker's edit rather than truncation.
        let flipIndex = container.index(container.startIndex, offsetBy: ExportEncryptor.headerLength + 5)
        container[flipIndex] ^= 0xFF

        XCTAssertThrowsError(try ExportEncryptor.decrypt(container, passphrase: "the-real-passphrase")) { error in
            XCTAssertEqual(error as? ExportEncryptionError, .incorrectPassphraseOrTamperedData)
        }
    }

    func testDecryptOfTruncatedContainerThrowsTruncatedHeader() {
        let tooShort = Data([0x42, 0x44, 0x4E, 0x58, 0x01])
        XCTAssertThrowsError(try ExportEncryptor.decrypt(tooShort, passphrase: "anything")) { error in
            XCTAssertEqual(error as? ExportEncryptionError, .truncatedHeader)
        }
    }

    func testDecryptOfNonContainerDataThrowsNotAContainer() throws {
        let container = try ExportEncryptor.encrypt(files: sampleFiles, passphrase: "x", iterations: 1_000)
        var notAContainer = container
        notAContainer[notAContainer.startIndex] = 0x00 // corrupt the magic's first byte
        XCTAssertThrowsError(try ExportEncryptor.decrypt(notAContainer, passphrase: "x")) { error in
            XCTAssertEqual(error as? ExportEncryptionError, .notAContainer)
        }
    }

    func testDecryptOfUnknownFormatVersionThrowsUnsupportedVersion() throws {
        var container = try ExportEncryptor.encrypt(files: sampleFiles, passphrase: "x", iterations: 1_000)
        let versionIndex = container.index(container.startIndex, offsetBy: 4)
        container[versionIndex] = 99
        XCTAssertThrowsError(try ExportEncryptor.decrypt(container, passphrase: "x")) { error in
            XCTAssertEqual(error as? ExportEncryptionError, .unsupportedVersion(99))
        }
    }

    // MARK: - Format-stability fixture (golden bytes decrypt on this build)

    /// A container produced once by this exact algorithm (fixed salt/nonce/iteration count so
    /// the bytes are reproducible), hardcoded here as base64. If this test ever fails, the byte
    /// layout changed in a way that breaks reading an export a user made with an older build —
    /// exactly the scenario `docs/adr/ADR-0008-export-encryption.md`'s format section exists to
    /// prevent. A layout change must bump `ExportEncryptor.formatVersion` and add a NEW fixture
    /// alongside this one, not replace it.
    private static let goldenContainerBase64 =
        "QkROWAEBAAAD6AABAgMEBQYHCAkKCwwNDg+goaKjpKWmp6ipqqv+HlXt00VCN6ZEuSWh3EY5yd6ylN6lUy+ApsXBmMPauk1v" +
        "wOj5/WWb+RYulF5zR2AWnoLlut2xIwpVUxcclO5tUKdQ2A9XZrWpJ7pPjc/EVgDEsqoFSAvl+klmfZIOETHkmxZqN+I8zdP+" +
        "7SPdQknADQfWg0Onqkc9xw=="
    private static let goldenPassphrase = "fixture-passphrase-v1"

    func testFormatStabilityFixtureDecryptsOnThisBuild() throws {
        let container = try XCTUnwrap(Data(base64Encoded: Self.goldenContainerBase64))
        let files = try ExportEncryptor.decrypt(container, passphrase: Self.goldenPassphrase)

        XCTAssertEqual(files.count, 2)
        let manifest = try XCTUnwrap(files.first { $0.name == "manifest.json" })
        XCTAssertEqual(String(data: manifest.data, encoding: .utf8), #"{"exportId":"fixture-001","schemaVersion":"0.1.0"}"#)
        let raw = try XCTUnwrap(files.first { $0.name == "raw.csv" })
        XCTAssertEqual(String(data: raw.data, encoding: .utf8), "record_id,value\nr1,42\n")
    }

    func testFormatStabilityFixtureRejectsAWrongPassphrase() throws {
        let container = try XCTUnwrap(Data(base64Encoded: Self.goldenContainerBase64))
        XCTAssertThrowsError(try ExportEncryptor.decrypt(container, passphrase: "not-the-fixture-passphrase")) { error in
            XCTAssertEqual(error as? ExportEncryptionError, .incorrectPassphraseOrTamperedData)
        }
    }

    // MARK: - Cross-platform container interop (EPIC-06)

    /// The iOS half of EPIC-06's acceptance criterion, "byte-level container interop proven both
    /// directions". `packages/fixtures/encryption/android-written-v1.badanenc` was produced by
    /// Kotlin `ExportEncryptor` (`apps/android/.../export/ExportEncryptor.kt`) via
    /// `javax.crypto` — different language, different crypto stack, no shared code. If this build
    /// can open it, the two implementations agree on magic, version byte, KDF id, big-endian
    /// iteration count, salt placement, the CryptoKit-combined nonce/ciphertext/tag ordering, the
    /// inner multi-file layout, AND the UTF-8 encoding of the passphrase feeding PBKDF2. If any
    /// one of those diverges, this fails — which is the entire reason the fixture exists rather
    /// than each platform testing only its own round trip.
    ///
    /// The mirror test lives in `ExportEncryptorTest.iosWrittenContainerDecryptsOnAndroid`, which
    /// opens the container THIS platform wrote. Neither test is sufficient alone: a shared
    /// misunderstanding of the format would still round-trip within one platform.
    func testAndroidWrittenFixtureDecryptsOnIOS() throws {
        let fixture = try Self.loadFixture(id: "android-written-v1")
        let files = try ExportEncryptor.decrypt(fixture.container, passphrase: fixture.passphrase)

        XCTAssertEqual(files.map(\.name).sorted(), fixture.plaintext.keys.sorted(),
                       "the Android-written container must hold exactly the manifest's file set")
        for (name, expected) in fixture.plaintext {
            let file = try XCTUnwrap(files.first { $0.name == name }, "missing \(name)")
            XCTAssertEqual(String(data: file.data, encoding: .utf8), expected,
                           "\(name) must survive the Android→iOS trip byte-exactly")
        }
    }

    /// The container this platform wrote, verified from this side. Does not prove Android can read
    /// it (`ExportEncryptorTest.iosWrittenContainerDecryptsOnAndroid` does); it proves the
    /// committed bytes are the bytes this implementation produces, so an Android-side failure
    /// points at the format rather than at a stale or corrupted file in git.
    func testIOSWrittenFixtureIsStillReadableByThisBuild() throws {
        let fixture = try Self.loadFixture(id: "ios-written-v1")
        let files = try ExportEncryptor.decrypt(fixture.container, passphrase: fixture.passphrase)
        XCTAssertEqual(files.map(\.name).sorted(), fixture.plaintext.keys.sorted())
        for (name, expected) in fixture.plaintext {
            let file = try XCTUnwrap(files.first { $0.name == name })
            XCTAssertEqual(String(data: file.data, encoding: .utf8), expected)
        }
    }

    /// A wrong passphrase against the Android-written container must produce the SAME typed error
    /// a wrong passphrase against an iOS-written one does. Error *identity* parity is half of
    /// EPIC-06's acceptance criterion and is not implied by the bytes decrypting.
    func testAndroidWrittenFixtureRejectsAWrongPassphrase() throws {
        let fixture = try Self.loadFixture(id: "android-written-v1")
        XCTAssertThrowsError(try ExportEncryptor.decrypt(fixture.container, passphrase: "not-the-passphrase")) { error in
            XCTAssertEqual(error as? ExportEncryptionError, .incorrectPassphraseOrTamperedData)
        }
    }

    /// A tampered Android-written container fails identically to a tampered iOS-written one —
    /// GCM's tag is verified the same way on both sides, and neither platform pretends to be able
    /// to tell tampering apart from a wrong passphrase.
    func testTamperedAndroidWrittenFixtureFailsWithTheSameError() throws {
        var container = try Self.loadFixture(id: "android-written-v1").container
        let flipIndex = container.index(container.startIndex, offsetBy: ExportEncryptor.headerLength + 5)
        container[flipIndex] ^= 0xFF
        XCTAssertThrowsError(try ExportEncryptor.decrypt(container, passphrase: "بادان-fixture-🌙-2026")) { error in
            XCTAssertEqual(error as? ExportEncryptionError, .incorrectPassphraseOrTamperedData)
        }
    }

    // MARK: - Shared fixture loading

    private struct CrossPlatformFixture {
        let container: Data
        let passphrase: String
        let plaintext: [String: String]
    }

    /// Reads a fixture out of `packages/fixtures/encryption/` — the repo file both platforms
    /// share, not a copy. A copied fixture is one more artifact that can drift from the thing it
    /// is supposed to police, and drift is the exact failure mode this epic exists to close.
    ///
    /// Located relative to `#filePath` (this file's own compile-time path) rather than through
    /// `Bundle`: the fixtures are deliberately outside both app bundles, and adding a resources
    /// rule to `project.yml` to copy binary containers into the test bundle would put a build-
    /// system step between the fixture and the assertion. Simulator test processes run on the host
    /// and can read the checkout directly. If this ever fails on a machine or CI runner where that
    /// is not true — sandboxed runner, TCC-restricted checkout location — the fix is to bundle the
    /// fixtures as test resources, NOT to re-embed the bytes as a base64 literal here.
    private static func loadFixture(id: String) throws -> CrossPlatformFixture {
        let directory = URL(fileURLWithPath: #filePath) // apps/ios/Tests/ExportEncryptionTests.swift
            .deletingLastPathComponent()                // apps/ios/Tests
            .deletingLastPathComponent()                // apps/ios
            .deletingLastPathComponent()                // apps
            .deletingLastPathComponent()                // <repo root>
            .appendingPathComponent("packages/fixtures/encryption", isDirectory: true)

        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                                 "fixture manifest is not a JSON object: \(manifestURL.path)")
        let containers = try XCTUnwrap(root["containers"] as? [[String: Any]],
                                       "fixture manifest has no `containers` array")
        let entry = try XCTUnwrap(containers.first { $0["id"] as? String == id },
                                  "fixture manifest has no entry '\(id)'")

        let fileName = try XCTUnwrap(entry["file"] as? String)
        let container = try Data(contentsOf: directory.appendingPathComponent(fileName))

        // Checked before decrypting: a fixture mangled in transit (text-mode checkout, bad merge)
        // would otherwise surface as `incorrectPassphraseOrTamperedData` — technically true, and
        // precisely the wrong thing to hand someone debugging a format mismatch.
        let digest = SHA256.hash(data: container).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, entry["sha256"] as? String,
                       "fixture '\(id)' does not match the SHA-256 recorded in manifest.json")

        return CrossPlatformFixture(
            container: container,
            passphrase: try XCTUnwrap(entry["passphrase"] as? String),
            plaintext: try XCTUnwrap(entry["plaintext"] as? [String: String]))
    }

    // MARK: - Inner container plaintext layout, directly (byte-exact — see the ADR)

    func testEncodeThenDecodeContainerPlaintextRoundTrips() throws {
        let plaintext = ExportEncryptor.encodeContainerPlaintext(sampleFiles)
        let decoded = try ExportEncryptor.decodeContainerPlaintext(plaintext)
        XCTAssertEqual(decoded, sampleFiles)
    }

    func testEncodeContainerPlaintextLayoutIsByteExact() {
        let files = [ExportContainerFile(name: "a", data: Data([0x01, 0x02]))]
        let plaintext = ExportEncryptor.encodeContainerPlaintext(files)
        // fileCount(UInt16 BE)=1 -> 00 01; nameLength(UInt16 BE)=1 -> 00 01; name "a" -> 61;
        // dataLength(UInt32 BE)=2 -> 00 00 00 02; data -> 01 02.
        let expected: [UInt8] = [0x00, 0x01, 0x00, 0x01, 0x61, 0x00, 0x00, 0x00, 0x02, 0x01, 0x02]
        XCTAssertEqual([UInt8](plaintext), expected)
    }

    // MARK: - ExportPassphrasePolicy

    func testPassphrasePolicyRejectsBelowMinimumLength() {
        let tooShort = String(repeating: "a", count: ExportPassphrasePolicy.minimumLength - 1)
        XCTAssertFalse(ExportPassphrasePolicy.isValid(tooShort))
    }

    func testPassphrasePolicyAcceptsAtMinimumLength() {
        let exactlyMinimum = String(repeating: "a", count: ExportPassphrasePolicy.minimumLength)
        XCTAssertTrue(ExportPassphrasePolicy.isValid(exactlyMinimum))
    }

    func testPassphrasePolicyMatchesRequiresExactEquality() {
        XCTAssertTrue(ExportPassphrasePolicy.matches("same-value-123", confirmation: "same-value-123"))
        XCTAssertFalse(ExportPassphrasePolicy.matches("same-value-123", confirmation: "Same-value-123"))
        XCTAssertFalse(ExportPassphrasePolicy.matches("same-value-123", confirmation: "same-value-1234"))
    }
}
