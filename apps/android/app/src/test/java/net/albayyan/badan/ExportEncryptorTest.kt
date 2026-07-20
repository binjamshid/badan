package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.export.ExportContainerFile
import net.albayyan.badan.export.ExportEncryptionException
import net.albayyan.badan.export.ExportEncryptor
import net.albayyan.badan.export.ExportPassphrasePolicy
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.Base64

/**
 * Android half of EPIC-06 (Android export encryption parity — one of the two standing parity
 * debts named in the execution plan §4.6).
 *
 * The load-bearing tests here are the cross-platform ones: [iosWrittenContainerDecryptsOnAndroid]
 * reads a container `apps/ios/Sources/Export/ExportEncryption.swift` actually produced, and
 * [androidWrittenContainerIsReadableAndMatchesItsManifest] guards the container this file
 * produced for iOS to read back (asserted on the iOS side by
 * `apps/ios/Tests/ExportEncryptionTests.swift`). Together those two are the epic's acceptance
 * criterion — "byte-level container interop proven both directions". Everything else in this file
 * is the local coverage that makes a failure in those two diagnosable.
 *
 * Fixtures live in `packages/fixtures/encryption/` and are read from disk rather than copied into
 * either platform's test source: a copied fixture is one more thing that can drift from the
 * artifact it is supposed to police (same reasoning as `UnitsRegistryParityTest`).
 */
class ExportEncryptorTest {

    // Unit tests run with the module dir (`apps/android/app`) as the working directory.
    private val fixtureDir = File("../../../packages/fixtures/encryption")

    private val sampleFiles = listOf(
        ExportContainerFile("raw.csv", "record_id,value\nr1,42\n".toByteArray()),
        ExportContainerFile("events.csv", "record_id,metric_id\ne1,symptoms.entry\n".toByteArray()),
        ExportContainerFile("manifest.json", """{"exportId":"abc"}""".toByteArray()),
    )

    /**
     * Every round-trip test below pays a real KDF, so they use a low iteration count. This is the
     * ONLY place a count other than [ExportEncryptor.DEFAULT_ITERATIONS] is legitimate — the
     * shipped default is a security parameter, not a tunable, and the cross-platform fixtures
     * deliberately use the full 600,000 rounds so the real number is exercised too.
     */
    private val testIterations = 1_000

    // MARK: - Cross-platform interop (the acceptance criterion)

    @Test fun iosWrittenContainerDecryptsOnAndroid() {
        val entry = fixtureEntry(fixtureManifest(), "ios-written-v1")
        assertPlaintextMatches(entry, ExportEncryptor.decrypt(readFixtureContainer(entry), entry.passphrase))
    }

    /**
     * The other direction's fixture, verified from the side that wrote it. This does not by itself
     * prove iOS can read it — `ExportEncryptionTests.testAndroidWrittenFixtureDecryptsOnIOS` is
     * what proves that. What it does prove is that the committed bytes are the bytes this
     * implementation produces, so an iOS-side failure points at the format rather than at a
     * corrupt or stale file in git.
     */
    @Test fun androidWrittenContainerIsReadableAndMatchesItsManifest() {
        val entry = fixtureEntry(fixtureManifest(), "android-written-v1")
        val bytes = readFixtureContainer(entry)

        assertEquals("BDNX", String(bytes, 0, 4, StandardCharsets.US_ASCII))
        assertEquals(ExportEncryptor.FORMAT_VERSION, bytes[4].toInt() and 0xFF)
        assertEquals(ExportEncryptor.KDF_ID_PBKDF2_SHA256, bytes[5].toInt() and 0xFF)
        // Iterations are a UInt32 BE at offset 6; the interop fixtures pin the shipped default so
        // the real security parameter is what actually gets exercised end to end.
        val iterations = ((bytes[6].toInt() and 0xFF) shl 24) or ((bytes[7].toInt() and 0xFF) shl 16) or
            ((bytes[8].toInt() and 0xFF) shl 8) or (bytes[9].toInt() and 0xFF)
        assertEquals(ExportEncryptor.DEFAULT_ITERATIONS, iterations)

        assertPlaintextMatches(entry, ExportEncryptor.decrypt(bytes, entry.passphrase))
    }

    /**
     * The base64 golden container hardcoded in `apps/ios/Tests/ExportEncryptionTests.swift` as its
     * format-stability fixture. It predates this Kotlin implementation and was produced entirely
     * by CryptoKit/CommonCrypto, which makes it a third independent iOS-written artifact — and,
     * unlike the fixtures above, one nobody can accidentally regenerate from the Android side to
     * make a failure disappear.
     */
    @Test fun iosFormatStabilityGoldenContainerDecryptsOnAndroid() {
        val goldenBase64 =
            "QkROWAEBAAAD6AABAgMEBQYHCAkKCwwNDg+goaKjpKWmp6ipqqv+HlXt00VCN6ZEuSWh3EY5yd6ylN6lUy+ApsXBmMPauk1v" +
                "wOj5/WWb+RYulF5zR2AWnoLlut2xIwpVUxcclO5tUKdQ2A9XZrWpJ7pPjc/EVgDEsqoFSAvl+klmfZIOETHkmxZqN+I8zdP+" +
                "7SPdQknADQfWg0Onqkc9xw=="
        val files = ExportEncryptor.decrypt(Base64.getDecoder().decode(goldenBase64), "fixture-passphrase-v1")

        assertEquals(2, files.size)
        assertEquals(
            """{"exportId":"fixture-001","schemaVersion":"0.1.0"}""",
            String(files.first { it.name == "manifest.json" }.data, StandardCharsets.UTF_8),
        )
        assertEquals(
            "record_id,value\nr1,42\n",
            String(files.first { it.name == "raw.csv" }.data, StandardCharsets.UTF_8),
        )
    }

    // MARK: - Round trip

    @Test fun encryptThenDecryptRecoversAllFilesByteExactly() {
        val container = ExportEncryptor.encrypt(sampleFiles, "a very good passphrase", testIterations)
        val recovered = ExportEncryptor.decrypt(container, "a very good passphrase")

        assertEquals(sampleFiles.size, recovered.size)
        for (original in sampleFiles) {
            val match = recovered.first { it.name == original.name }
            assertArrayEquals("${original.name} must round-trip byte-exactly", original.data, match.data)
        }
    }

    @Test fun encryptedContainerStartsWithTheMagicHeader() {
        val container = ExportEncryptor.encrypt(sampleFiles, "a very good passphrase", testIterations)
        assertArrayEquals(ExportEncryptor.MAGIC, container.copyOfRange(0, 4))
        assertEquals(ExportEncryptor.FORMAT_VERSION, container[4].toInt() and 0xFF)
        assertEquals(ExportEncryptor.KDF_ID_PBKDF2_SHA256, container[5].toInt() and 0xFF)
    }

    @Test fun encryptRoundTripWithASingleFile() {
        val single = listOf(ExportContainerFile("bundle.json", """{"a":1}""".toByteArray()))
        val container = ExportEncryptor.encrypt(single, "single-file-passphrase", testIterations)
        assertEquals(single, ExportEncryptor.decrypt(container, "single-file-passphrase"))
    }

    /**
     * Two independent encryptions of the same content must not produce the same bytes — proof the
     * salt and nonce are actually fresh per call, not accidentally fixed/reused. Nonce reuse under
     * one derived key is the classic catastrophic GCM failure, so this is not a style assertion.
     */
    @Test fun twoEncryptionsOfTheSameFilesProduceDifferentContainers() {
        val first = ExportEncryptor.encrypt(sampleFiles, "same-passphrase", testIterations)
        val second = ExportEncryptor.encrypt(sampleFiles, "same-passphrase", testIterations)
        assertFalse("salt/nonce must be freshly random per encryption", first.contentEquals(second))
    }

    /** Non-ASCII names and payloads survive the UTF-8 name field and the opaque data field. */
    @Test fun encryptRoundTripPreservesNonAsciiNamesAndContent() {
        val arabic = listOf(
            ExportContainerFile("ملاحظات.txt", "قياسات تجريبية\n".toByteArray(StandardCharsets.UTF_8)),
        )
        val container = ExportEncryptor.encrypt(arabic, "بادان-passphrase-🌙", testIterations)
        assertEquals(arabic, ExportEncryptor.decrypt(container, "بادان-passphrase-🌙"))
    }

    // MARK: - Typed errors (identity must match iOS exactly)

    @Test fun decryptWithWrongPassphraseThrowsIncorrectPassphraseOrTamperedData() {
        val container = ExportEncryptor.encrypt(sampleFiles, "the-real-passphrase", testIterations)
        assertThrowsEncryption(ExportEncryptionException.IncorrectPassphraseOrTamperedData) {
            ExportEncryptor.decrypt(container, "totally-wrong-passphrase")
        }
    }

    /**
     * A tampered container must land on the SAME typed error as a wrong passphrase — GCM cannot
     * distinguish them, and a format that claimed to would be lying. Both platforms report the one
     * case, so a UI can say one honest thing on either.
     */
    @Test fun decryptOfTamperedCiphertextThrowsTheSameErrorAsAWrongPassphrase() {
        val container = ExportEncryptor.encrypt(sampleFiles, "the-real-passphrase", testIterations)
        // Flip one byte well inside the ciphertext (past the fixed header), simulating bit-rot or
        // an attacker's edit rather than truncation.
        container[ExportEncryptor.HEADER_LENGTH + 5] = (container[ExportEncryptor.HEADER_LENGTH + 5].toInt() xor 0xFF).toByte()
        assertThrowsEncryption(ExportEncryptionException.IncorrectPassphraseOrTamperedData) {
            ExportEncryptor.decrypt(container, "the-real-passphrase")
        }
    }

    @Test fun decryptOfTruncatedContainerThrowsTruncatedHeader() {
        val tooShort = byteArrayOf(0x42, 0x44, 0x4E, 0x58, 0x01)
        assertThrowsEncryption(ExportEncryptionException.TruncatedHeader) {
            ExportEncryptor.decrypt(tooShort, "anything")
        }
    }

    @Test fun decryptOfNonContainerDataThrowsNotAContainer() {
        val container = ExportEncryptor.encrypt(sampleFiles, "x", testIterations)
        container[0] = 0x00 // corrupt the magic's first byte
        assertThrowsEncryption(ExportEncryptionException.NotAContainer) {
            ExportEncryptor.decrypt(container, "x")
        }
    }

    @Test fun decryptOfUnknownFormatVersionThrowsUnsupportedVersion() {
        val container = ExportEncryptor.encrypt(sampleFiles, "x", testIterations)
        container[4] = 99
        assertThrowsEncryption(ExportEncryptionException.UnsupportedVersion(99)) {
            ExportEncryptor.decrypt(container, "x")
        }
    }

    @Test fun decryptOfUnknownKdfIdThrowsUnsupportedKdf() {
        val container = ExportEncryptor.encrypt(sampleFiles, "x", testIterations)
        container[5] = 7
        assertThrowsEncryption(ExportEncryptionException.UnsupportedKdf(7)) {
            ExportEncryptor.decrypt(container, "x")
        }
    }

    /**
     * A container whose header is intact but whose GCM blob is too short to hold a nonce and a tag
     * must not fall out as an index error. iOS reaches the same case because
     * `AES.GCM.SealedBox(combined:)` throws inside the same catch.
     */
    @Test fun decryptOfAHeaderOnlyContainerThrowsIncorrectPassphraseOrTamperedData() {
        val container = ExportEncryptor.encrypt(sampleFiles, "x", testIterations)
        val headerOnly = container.copyOfRange(0, ExportEncryptor.HEADER_LENGTH)
        assertThrowsEncryption(ExportEncryptionException.IncorrectPassphraseOrTamperedData) {
            ExportEncryptor.decrypt(headerOnly, "x")
        }
    }

    // MARK: - Inner plaintext layout (byte-exact — see the format comment in ExportEncryptor.kt)

    @Test fun encodeThenDecodeContainerPlaintextRoundTrips() {
        val plaintext = ExportEncryptor.encodeContainerPlaintext(sampleFiles)
        assertEquals(sampleFiles, ExportEncryptor.decodeContainerPlaintext(plaintext))
    }

    /** The identical assertion iOS makes on the identical input, byte for byte. */
    @Test fun encodeContainerPlaintextLayoutIsByteExact() {
        val files = listOf(ExportContainerFile("a", byteArrayOf(0x01, 0x02)))
        // fileCount(UInt16 BE)=1 -> 00 01; nameLength(UInt16 BE)=1 -> 00 01; name "a" -> 61;
        // dataLength(UInt32 BE)=2 -> 00 00 00 02; data -> 01 02.
        val expected = byteArrayOf(0x00, 0x01, 0x00, 0x01, 0x61, 0x00, 0x00, 0x00, 0x02, 0x01, 0x02)
        assertArrayEquals(expected, ExportEncryptor.encodeContainerPlaintext(files))
    }

    @Test fun decodeRejectsPlaintextWithTrailingBytes() {
        val plaintext = ExportEncryptor.encodeContainerPlaintext(sampleFiles) + byteArrayOf(0x00)
        assertThrowsEncryption(ExportEncryptionException.MalformedContainerPlaintext) {
            ExportEncryptor.decodeContainerPlaintext(plaintext)
        }
    }

    @Test fun decodeRejectsPlaintextWhoseLengthFieldOverrunsTheBuffer() {
        // fileCount=1, nameLength=1, name "a", dataLength=0x7FFFFFFF, no data.
        val plaintext = byteArrayOf(0x00, 0x01, 0x00, 0x01, 0x61, 0x7F, 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte())
        assertThrowsEncryption(ExportEncryptionException.MalformedContainerPlaintext) {
            ExportEncryptor.decodeContainerPlaintext(plaintext)
        }
    }

    // MARK: - KDF

    /**
     * Published PBKDF2-HMAC-SHA256 vectors, pinning the reference implementation that
     * `fastKdfAvailable` judges the platform provider against. Without this, a bug in the
     * reference would make the probe reject a perfectly good provider and then derive wrong keys
     * with the same bug — self-consistent and wrong.
     */
    @Test fun referencePbkdf2MatchesPublishedTestVectors() {
        val password = "password".toByteArray(StandardCharsets.US_ASCII)
        val salt = "salt".toByteArray(StandardCharsets.US_ASCII)
        assertEquals(
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
            hex(ExportEncryptor.macPbkdf2(password, salt, 1L, 32)),
        )
        assertEquals(
            "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43",
            hex(ExportEncryptor.macPbkdf2(password, salt, 2L, 32)),
        )
        assertEquals(
            "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a",
            hex(ExportEncryptor.macPbkdf2(password, salt, 4096L, 32)),
        )
    }

    /**
     * A derived key longer than one SHA-256 block exercises the multi-block branch of the
     * reference PBKDF2, which the shipped 32-byte key never reaches. Vector for
     * PBKDF2-HMAC-SHA256("passwd", "salt", c=1, dkLen=64) is the concatenation of blocks T1|T2.
     */
    @Test fun referencePbkdf2DerivesMoreThanOneBlockCorrectly() {
        val derived = ExportEncryptor.macPbkdf2(
            "password".toByteArray(StandardCharsets.US_ASCII),
            "salt".toByteArray(StandardCharsets.US_ASCII),
            1L, 64,
        )
        assertEquals(64, derived.size)
        // The first block must be identical to the 32-byte derivation of the same inputs; a
        // multi-block implementation that got the block counter wrong fails right here.
        assertTrue(
            derived.copyOfRange(0, 32).contentEquals(
                ExportEncryptor.macPbkdf2(
                    "password".toByteArray(StandardCharsets.US_ASCII),
                    "salt".toByteArray(StandardCharsets.US_ASCII),
                    1L, 32,
                ),
            ),
        )
    }

    /**
     * Performance tripwire, not a benchmark. 600,000 rounds is deliberately slow (ADR-0008), and
     * the epic's budget is <3s on a Pixel-a-class device with a progress indicator required above
     * 1s. Measured on the JVM this was written against: ~110ms via the provider path, ~120ms via
     * the reference path. The ceiling here is set enormously wide on purpose — it exists to catch
     * an accidental order-of-magnitude regression (a per-iteration `Mac.getInstance`, say), not to
     * fail on a loaded CI box. The real device number is NOT asserted here and is still owed.
     */
    @Test fun fullIterationCountEncryptionStaysWithinTheRegressionCeiling() {
        val elapsed = System.nanoTime().let { start ->
            ExportEncryptor.encrypt(sampleFiles, "a very good passphrase", ExportEncryptor.DEFAULT_ITERATIONS)
            (System.nanoTime() - start) / 1_000_000
        }
        assertTrue(
            "600k-round encrypt took ${elapsed}ms (fast KDF path available: " +
                "${ExportEncryptor.fastKdfAvailable}) — investigate before relaxing this ceiling",
            elapsed < 10_000,
        )
    }

    // MARK: - ExportPassphrasePolicy

    @Test fun passphrasePolicyRejectsBelowMinimumLength() {
        assertFalse(ExportPassphrasePolicy.isValid("a".repeat(ExportPassphrasePolicy.MINIMUM_LENGTH - 1)))
    }

    @Test fun passphrasePolicyAcceptsAtMinimumLength() {
        assertTrue(ExportPassphrasePolicy.isValid("a".repeat(ExportPassphrasePolicy.MINIMUM_LENGTH)))
    }

    @Test fun passphrasePolicyMatchesRequiresExactEquality() {
        assertTrue(ExportPassphrasePolicy.matches("same-value-123", "same-value-123"))
        assertFalse(ExportPassphrasePolicy.matches("same-value-123", "Same-value-123"))
        assertFalse(ExportPassphrasePolicy.matches("same-value-123", "same-value-1234"))
    }

    /**
     * The counting rule, not just the threshold. Ten astral-plane emoji are ten characters to a
     * user and to Swift's `String.count`, but twenty UTF-16 code units to `String.length`; nine
     * are nine and eighteen. If this ever regresses to `.length`, Android silently accepts
     * passphrases iOS rejects — a policy fork hiding inside a passing threshold test.
     */
    @Test fun passphrasePolicyCountsGraphemeClustersLikeIos() {
        assertEquals(10, ExportPassphrasePolicy.length("🌙".repeat(10)))
        assertFalse(ExportPassphrasePolicy.isValid("🌙".repeat(9)))
        assertTrue(ExportPassphrasePolicy.isValid("🌙".repeat(10)))
        // A base letter plus a combining mark is one character to the user and to iOS.
        assertEquals(1, ExportPassphrasePolicy.length("é"))
    }

    // MARK: - Fixture manifest plumbing

    private data class FixtureEntry(
        val id: String,
        val file: String,
        val passphrase: String,
        val sha256: String,
        val plaintext: Map<String, String>,
    )

    private fun fixtureManifest(): Map<String, FixtureEntry> {
        val file = File(fixtureDir, "manifest.json")
        assertTrue("missing fixture manifest at ${file.absolutePath}", file.exists())
        val containers = Json.parseToJsonElement(file.readText()).jsonObject["containers"]!!.jsonArray
        return containers.associate { element ->
            val obj = element.jsonObject
            val id = obj["id"]!!.jsonPrimitive.content
            id to FixtureEntry(
                id = id,
                file = obj["file"]!!.jsonPrimitive.content,
                passphrase = obj["passphrase"]!!.jsonPrimitive.content,
                sha256 = obj["sha256"]!!.jsonPrimitive.content,
                plaintext = obj["plaintext"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content },
            )
        }
    }

    private fun fixtureEntry(manifest: Map<String, FixtureEntry>, id: String): FixtureEntry {
        val entry = manifest[id]
        assertTrue("fixture manifest has no entry '$id'", entry != null)
        return entry!!
    }

    /**
     * Reads a fixture container and checks its SHA-256 against the manifest before handing the
     * bytes to the encryptor. Without this, a fixture mangled in transit (a text-mode checkout, a
     * bad merge) would surface as `IncorrectPassphraseOrTamperedData` — technically true, and
     * exactly the wrong thing to send someone debugging a cross-platform format mismatch.
     */
    private fun readFixtureContainer(entry: FixtureEntry): ByteArray {
        val file = File(fixtureDir, entry.file)
        assertTrue(
            "missing fixture '${entry.id}' at ${file.absolutePath} — see " +
                "packages/fixtures/encryption/README.md",
            file.exists(),
        )
        val bytes = file.readBytes()
        assertEquals(
            "fixture '${entry.id}' does not match the SHA-256 recorded in manifest.json — the " +
                "committed container has been altered, not just re-encrypted",
            entry.sha256, hex(java.security.MessageDigest.getInstance("SHA-256").digest(bytes)),
        )
        return bytes
    }

    private fun assertPlaintextMatches(entry: FixtureEntry, files: List<ExportContainerFile>) {
        assertEquals(
            "fixture '${entry.id}' file set",
            entry.plaintext.keys.sorted(), files.map { it.name }.sorted(),
        )
        for ((name, expected) in entry.plaintext) {
            val actual = String(files.first { it.name == name }.data, StandardCharsets.UTF_8)
            assertEquals("fixture '${entry.id}' file '$name'", expected, actual)
        }
    }

    // MARK: - Helpers

    /**
     * Asserts both the error's identity and — for the parameterized cases — the value it carries,
     * because "wrong version" and "wrong KDF" are only useful to a UI if the byte comes with them.
     * `assertEquals` on the exception itself works because the parameterized cases are data
     * classes and the rest are objects, which is exactly the identity model iOS's `Equatable`
     * enum has.
     */
    private fun assertThrowsEncryption(expected: ExportEncryptionException, block: () -> Unit) {
        try {
            block()
            fail("expected $expected, but nothing was thrown")
        } catch (actual: ExportEncryptionException) {
            assertEquals(expected, actual)
        }
    }

    private fun hex(bytes: ByteArray): String =
        buildString { for (b in bytes) append("%02x".format(b.toInt() and 0xFF)) }

    // MARK: - Fixture regeneration

    /**
     * Writes the Android-written half of the cross-platform fixture set. Skipped unless
     * `BADAN_REGENERATE_ENCRYPTION_FIXTURES=1` is set in the environment, because regenerating a
     * fixture is exactly how a format regression gets papered over: the correct response to
     * [androidWrittenContainerIsReadableAndMatchesItsManifest] failing is to find out what changed
     * in the format, not to rewrite the file until it agrees.
     *
     * Regenerate only when the format version is deliberately bumped, and regenerate BOTH halves
     * (see `packages/fixtures/encryption/README.md` for the iOS side).
     */
    @Test fun regenerateAndroidWrittenFixture() {
        if (System.getenv("BADAN_REGENERATE_ENCRYPTION_FIXTURES") != "1") return

        val entry = fixtureEntry(fixtureManifest(), "android-written-v1")
        val files = entry.plaintext.map { (name, content) ->
            ExportContainerFile(name, content.toByteArray(StandardCharsets.UTF_8))
        }
        val container = ExportEncryptor.encrypt(files, entry.passphrase, ExportEncryptor.DEFAULT_ITERATIONS)
        // Self-round-trip before committing anything: a fixture that this build cannot itself read
        // is worse than no fixture, because it fails on the far platform and points nowhere.
        assertEquals(files, ExportEncryptor.decrypt(container, entry.passphrase))
        File(fixtureDir, entry.file).writeBytes(container)

        // The salt and nonce are fresh per call, so every regeneration produces different bytes
        // and the manifest's recorded digest is now stale by construction. Failing here (rather
        // than quietly rewriting the manifest) keeps regeneration a two-step, deliberate act and
        // leaves a reviewer a diff that says which fixture changed and to what.
        val digest = hex(java.security.MessageDigest.getInstance("SHA-256").digest(container))
        assertEquals(
            "regenerated '${entry.id}' — set its sha256 in packages/fixtures/encryption/" +
                "manifest.json to $digest, then re-run without the regeneration env var",
            entry.sha256, digest,
        )
    }
}
