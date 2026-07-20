import XCTest
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
