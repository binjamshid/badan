package net.albayyan.badan.export

import java.nio.charset.StandardCharsets
import java.security.GeneralSecurityException
import java.security.SecureRandom
import java.text.BreakIterator
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/*
 * =====================================================================================
 * BDNX container format — version 1 (byte-exact; transcribed from the iOS reference
 * implementation `apps/ios/Sources/Export/ExportEncryption.swift` and ADR-0008 §"Container
 * format", both of which this file must agree with to the byte).
 *
 * This comment exists because EPIC-06's acceptance criterion is byte-level interop in BOTH
 * directions. If the format cannot be stated precisely here, it cannot be matched below.
 *
 * OUTER CONTAINER
 *   offset  size  field
 *   ------  ----  ------------------------------------------------------------------
 *        0     4  magic            ASCII "BDNX" = 0x42 0x44 0x4E 0x58
 *        4     1  format version   0x01
 *        5     1  KDF id           0x01 = PBKDF2-HMAC-SHA256
 *        6     4  iterations       UInt32, BIG-endian
 *       10    16  salt             random per export
 *       26     -  AES-GCM combined CryptoKit `SealedBox.combined` layout:
 *                                    nonce (12 bytes)
 *                                 || ciphertext (== inner plaintext length)
 *                                 || auth tag (16 bytes)
 *   Fixed header length = 4 + 1 + 1 + 4 + 16 = 26 bytes.
 *
 * INNER PLAINTEXT (the bytes AES-GCM seals; NOT JSON — see ADR-0008 on avoiding base64 bloat)
 *   UInt16 BE  file count
 *   repeated `file count` times:
 *     UInt16 BE  name length
 *     bytes      name, UTF-8, `name length` bytes   (a bare filename, never a path)
 *     UInt32 BE  data length
 *     bytes      data, `data length` bytes           (the file's exact original bytes)
 *   No per-file checksum: the outer GCM tag already authenticates every byte as one unit, so a
 *   second integrity mechanism at this layer would be redundant.
 *
 * CRYPTO PARAMETERS
 *   KDF          PBKDF2-HMAC-SHA256, iterations from the header, 16-byte salt, 32-byte key
 *   KDF password the passphrase's raw UTF-8 bytes (see `deriveKey` — this is the single most
 *                interop-critical detail on the Android side and is NOT the JCE default in
 *                every provider's history)
 *   Cipher       AES-256-GCM, 12-byte nonce, 128-bit tag, no additional authenticated data
 *
 * WHAT BREAKS IF SOMEONE "SIMPLIFIES" THIS
 *   - Little-endian iterations/lengths: containers still round-trip on Android alone and fail
 *     only against iOS — i.e. the bug ships silently unless the cross-platform fixtures run.
 *   - Emitting nonce/ciphertext/tag in any other order (e.g. Conscrypt-style tag-first, or a
 *     separate nonce field in the header): same silent one-platform-only failure.
 *   - Deriving the key from `passphrase.toCharArray()` through a provider that folds each char
 *     to 8 bits: ASCII passphrases still interop, non-ASCII ones silently do not.
 * =====================================================================================
 */

/**
 * One file bundled into (or extracted out of) an encrypted export container. [name] is a plain
 * relative filename (`"raw.csv"`, `"bundle.json"`, …) — never a path — matching whatever
 * [ExportRunner] had already written to the export's output folder before wrapping it.
 *
 * Mirror of iOS `ExportContainerFile`.
 */
data class ExportContainerFile(val name: String, val data: ByteArray) {
    // `data class` over a ByteArray gives identity-based equals/hashCode, which would make the
    // round-trip assertions in ExportEncryptorTest pass for the wrong reason (or fail for the
    // right content). Content equality is what every call site and test actually means here.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ExportContainerFile) return false
        return name == other.name && data.contentEquals(other.data)
    }

    override fun hashCode(): Int = 31 * name.hashCode() + data.contentHashCode()
}

/**
 * Typed failures from [ExportEncryptor.decrypt], so a caller (UI or test) can tell "this
 * passphrase is wrong" apart from "this isn't a BADAN export container" apart from "the bytes
 * were altered" — a single generic exception would force the UI to guess from a string.
 *
 * One case per iOS `ExportEncryptionError` case, same names, same meanings, same triggering
 * conditions. EPIC-06's acceptance criterion is that a wrong passphrase and a tampered container
 * produce the SAME error identity on both platforms and stay distinguishable from a
 * wrong-file/wrong-version failure; `ExportEncryptorTest` asserts each mapping directly.
 *
 * Messages are deliberately structural (never echo the passphrase, a filename's contents, or any
 * decrypted bytes) — this exception's `toString()` is what `ExportScreen` currently renders into
 * its error text, and no health value may reach a log or a screen by accident.
 */
sealed class ExportEncryptionException(message: String) : Exception(message) {
    /** Fewer than the fixed header's 26 bytes — not even enough to read magic/version/KDF. */
    object TruncatedHeader :
        ExportEncryptionException("container is shorter than the 26-byte BDNX header")

    /** The first 4 bytes aren't [ExportEncryptor.MAGIC] — not a BADAN export container at all. */
    object NotAContainer :
        ExportEncryptionException("not a BADAN export container (magic mismatch)")

    /**
     * Magic matched but the format-version byte is one this build can't read. Bumped only on an
     * actual byte-layout change (see ADR-0008); a future build must keep reading version 1 rather
     * than erroring on it, so this case is for a version this build genuinely doesn't understand.
     */
    data class UnsupportedVersion(val version: Int) :
        ExportEncryptionException("unsupported BDNX container version $version")

    /** The KDF-id byte names a key-derivation function this build doesn't implement. */
    data class UnsupportedKdf(val kdfId: Int) :
        ExportEncryptionException("unsupported BDNX KDF id $kdfId")

    /**
     * AES-GCM's authentication tag didn't verify. The single failure mode for both "wrong
     * passphrase" (the derived key doesn't match) and "tampered ciphertext" (the bytes changed
     * after sealing) — GCM makes those cryptographically indistinguishable by design, so the
     * format cannot honestly report which one happened, only that the contents can't be trusted.
     */
    object IncorrectPassphraseOrTamperedData :
        ExportEncryptionException("passphrase is incorrect or the container was altered")

    /**
     * The (already-authenticated, already-decrypted) plaintext didn't parse as the inner
     * multi-file layout — indicates a bug in [ExportEncryptor.encrypt], not anything a user did,
     * since GCM already ruled out tampering by this point.
     */
    object MalformedContainerPlaintext :
        ExportEncryptionException("decrypted container plaintext does not match the BDNX layout")

    /**
     * A lower-level platform failure that isn't reachable through normal use: no AES-GCM or
     * HmacSHA256 provider, or a key derivation rejected for a parameter (an empty passphrase or a
     * zero iteration count — both already excluded by [ExportPassphrasePolicy] and this file's
     * own constants before the KDF is ever called). Matches iOS's `internalFailure`, which covers
     * exactly the same two situations (`SecRandomCopyBytes` failing, `CCKeyDerivationPBKDF`
     * returning `kCCParamError`).
     */
    object InternalFailure :
        ExportEncryptionException("export encryption failed for an internal reason")
}

/**
 * Encrypts/decrypts a BADAN export bundle for the `includeSensitive` case — the Android half of
 * the standing cross-platform parity debt named in the execution plan §4.6 and closed by EPIC-06.
 *
 * Byte-for-byte mirror of iOS `ExportEncryptor` (`apps/ios/Sources/Export/ExportEncryption.swift`).
 * The format is specified in ADR-0008 and restated in full at the top of this file; the two
 * implementations are held together by the shared fixtures under `packages/fixtures/encryption/`,
 * which each platform's test suite decrypts — Android reads the iOS-written container and iOS
 * reads the Android-written one, so a one-sided format change fails a test rather than shipping.
 *
 * Standard platform primitives only, no new dependencies (same constraint as iOS): AES-256-GCM
 * and PBKDF2-HMAC-SHA256 out of `javax.crypto`. A single container can hold more than one inner
 * file (CSV export produces raw.csv/derived.csv/manifest.json), so one passphrase, one KDF run,
 * and one GCM seal cover an entire export rather than one per file.
 */
object ExportEncryptor {

    // MARK: - Format constants (byte-exact — see the header comment and ADR-0008)

    /** 4-byte ASCII magic identifying a BADAN encrypted-export container. */
    val MAGIC: ByteArray = "BDNX".toByteArray(StandardCharsets.US_ASCII)
    const val FORMAT_VERSION: Int = 1
    const val KDF_ID_PBKDF2_SHA256: Int = 1
    const val SALT_LENGTH: Int = 16
    const val NONCE_LENGTH: Int = 12
    const val TAG_LENGTH: Int = 16
    const val TAG_BITS: Int = TAG_LENGTH * 8
    /** magic(4) + version(1) + kdfId(1) + iterations(4) + salt(16). */
    const val HEADER_LENGTH: Int = 4 + 1 + 1 + 4 + 16

    /** AES-256. Stated as a constant because it is also the PBKDF2 output length. */
    private const val KEY_LENGTH: Int = 32

    /**
     * PBKDF2-HMAC-SHA256 rounds used for new exports. 600,000 matches OWASP's Password Storage
     * Cheat Sheet (Dec 2023 revision) minimum for PBKDF2-HMAC-SHA256, and is the same number iOS
     * writes — a container's iteration count travels in its header, so the two platforms would
     * still interoperate if they disagreed, but a lower Android default would quietly make
     * Android-written exports the weakest link. See ADR-0008's re-evaluation gate before moving it.
     *
     * MEASURED (2026-07-20): 600,000 rounds, 32-byte key, warm JIT, JVM 21 on an Apple-silicon
     * host — 109 ms via `SecretKeyFactory`, 118 ms via the [macPbkdf2] fallback (first, cold call:
     * 136 ms / 324 ms respectively). NOT a device number: no Android hardware was attached when
     * this was written, so the Pixel-a-class figure EPIC-06 asks for is still outstanding. The
     * desktop numbers are why [fastKdfAvailable] exists at all — on ART the `SecretKeyFactory`
     * path is a single native call while [macPbkdf2] pays 600k JNI round-trips, so the gap that
     * is ~10% here is expected to be several-fold on a phone. Treat >1s as the trigger for the
     * progress indicator ADR-0008's re-evaluation gate describes; the runner currently has no
     * progress surface, which is recorded as a known gap rather than assumed fine.
     */
    const val DEFAULT_ITERATIONS: Int = 600_000

    /**
     * The file name every encrypted export is written under inside its output folder — matches
     * iOS `ExportEncryptor.containerFileName` so a container is recognizable by name on either
     * platform (and so [ExportRunner] and the export UI can key off one constant).
     */
    const val CONTAINER_FILE_NAME: String = "export.badanenc"

    private const val CIPHER_TRANSFORMATION = "AES/GCM/NoPadding"
    private const val HMAC_ALGORITHM = "HmacSHA256"
    private const val PBKDF2_ALGORITHM = "PBKDF2WithHmacSHA256"

    private val secureRandom by lazy { SecureRandom() }

    // MARK: - Encrypt

    /**
     * Wraps [files] into one encrypted container under [passphrase]. [files] must be non-empty and
     * every name must be unique — both are programmer errors on this codebase's own call sites,
     * not user-triggerable, hence `require` (iOS uses `precondition` for the same two checks).
     *
     * [iterations] is a parameter, not a hardcoded constant, for exactly two reasons: the fixture
     * generator pins it so container bytes are reproducible, and the test suite lowers it so a
     * dozen round-trip assertions don't each pay 600k rounds. It defaults to [DEFAULT_ITERATIONS]
     * and no production call site passes anything else — lowering the shipped default is a
     * cryptographic weakening, not a performance tweak.
     */
    fun encrypt(
        files: List<ExportContainerFile>,
        passphrase: String,
        iterations: Int = DEFAULT_ITERATIONS,
    ): ByteArray {
        require(files.isNotEmpty()) { "an encrypted export container must hold at least one file" }
        require(files.map { it.name }.toSet().size == files.size) { "container file names must be unique" }
        require(iterations > 0) { "PBKDF2 iteration count must be positive" }

        val plaintext = encodeContainerPlaintext(files)
        val salt = randomBytes(SALT_LENGTH)
        val key = deriveKey(passphrase, salt, iterations.toLong())
        val nonce = randomBytes(NONCE_LENGTH)

        // `doFinal` returns ciphertext||tag; prefixing the nonce reproduces CryptoKit's
        // `SealedBox.combined` layout exactly. Do not switch to a Cipher-generated IV: the
        // provider picks the length, and a 16-byte IV would still round-trip on Android while
        // failing every iOS read.
        val sealed = try {
            val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
            cipher.doFinal(plaintext)
        } catch (e: GeneralSecurityException) {
            throw ExportEncryptionException.InternalFailure
        }

        val out = ByteArray(HEADER_LENGTH + NONCE_LENGTH + sealed.size)
        MAGIC.copyInto(out, 0)
        out[4] = FORMAT_VERSION.toByte()
        out[5] = KDF_ID_PBKDF2_SHA256.toByte()
        writeBigEndianUInt32(out, 6, iterations.toLong())
        salt.copyInto(out, 10)
        nonce.copyInto(out, HEADER_LENGTH)
        sealed.copyInto(out, HEADER_LENGTH + NONCE_LENGTH)
        return out
    }

    // MARK: - Decrypt

    /**
     * Recovers the original files from a container produced by [encrypt] — or by iOS's
     * `ExportEncryptor.encrypt`, which is the whole point of the fixtures.
     *
     * Throws [ExportEncryptionException.IncorrectPassphraseOrTamperedData] for both a wrong
     * passphrase and a tampered container; see that case's doc comment for why the two can't be
     * told apart. Header validation runs in the same order as iOS (length → magic → version →
     * KDF id) so a file that is wrong in more than one way reports the same reason on both
     * platforms rather than whichever check happened to run first.
     */
    fun decrypt(container: ByteArray, passphrase: String): List<ExportContainerFile> {
        if (container.size < HEADER_LENGTH) throw ExportEncryptionException.TruncatedHeader
        for (i in MAGIC.indices) {
            if (container[i] != MAGIC[i]) throw ExportEncryptionException.NotAContainer
        }
        val version = container[4].toInt() and 0xFF
        if (version != FORMAT_VERSION) throw ExportEncryptionException.UnsupportedVersion(version)
        val kdfId = container[5].toInt() and 0xFF
        if (kdfId != KDF_ID_PBKDF2_SHA256) throw ExportEncryptionException.UnsupportedKdf(kdfId)

        // Read as an unsigned 32-bit value into a Long: the field is a UInt32 on iOS, and a
        // container declaring more than Int.MAX_VALUE rounds would otherwise arrive here as a
        // negative iteration count and be rejected as "internal failure" rather than simply being
        // an absurdly-expensive container. No upper cap is imposed, deliberately — capping here
        // and not on iOS would mean a container iOS opens and Android refuses, which is the exact
        // class of divergence this file exists to prevent. Nothing in the app reads an
        // attacker-supplied container today (there is no import path on either platform, per
        // ADR-0008); whoever builds one must add a sanity cap at THAT boundary, on both platforms
        // together, before a hostile file can make the KDF run for hours.
        val iterations = readBigEndianUInt32(container, 6)
        val salt = container.copyOfRange(10, 10 + SALT_LENGTH)
        val combined = container.copyOfRange(HEADER_LENGTH, container.size)

        val key = deriveKey(passphrase, salt, iterations)
        val plaintext = try {
            openCombined(combined, key)
        } catch (e: GeneralSecurityException) {
            // Every failure below the tag check means the same thing to a caller: these bytes (or
            // this passphrase) can't be trusted. Not surfacing the provider's own exception type
            // keeps this a stable, testable boundary independent of which JCE provider ran, and
            // matches how iOS collapses CryptoKit's error cases into one.
            throw ExportEncryptionException.IncorrectPassphraseOrTamperedData
        }
        return decodeContainerPlaintext(plaintext)
    }

    /**
     * Splits a CryptoKit-style combined blob and opens it. A blob too short to hold a nonce and a
     * tag is reported as a bad tag rather than an index error: iOS reaches the identical outcome
     * because `AES.GCM.SealedBox(combined:)` throws on a short blob inside the same `do/catch`
     * that maps everything to `incorrectPassphraseOrTamperedData`.
     */
    private fun openCombined(combined: ByteArray, key: ByteArray): ByteArray {
        if (combined.size < NONCE_LENGTH + TAG_LENGTH) {
            throw AEADBadTagException("combined blob is too short to hold a nonce and a tag")
        }
        val nonce = combined.copyOfRange(0, NONCE_LENGTH)
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        return cipher.doFinal(combined, NONCE_LENGTH, combined.size - NONCE_LENGTH)
    }

    // MARK: - Inner multi-file plaintext layout (byte-exact — see the header comment)

    /**
     * `fileCount(UInt16 BE)`, then per file: `nameLength(UInt16 BE) name(UTF-8)
     * dataLength(UInt32 BE) data`.
     */
    fun encodeContainerPlaintext(files: List<ExportContainerFile>): ByteArray {
        val nameBytes = files.map { it.name.toByteArray(StandardCharsets.UTF_8) }
        require(files.size <= 0xFFFF) { "a container holds at most 65535 files (file count is a UInt16)" }
        // Accumulated in Long so a pathologically large export surfaces as this message rather
        // than an Int overflow turning into a NegativeArraySizeException three lines down. The
        // 2 GB ceiling is inherent to sealing the whole export as one in-memory plaintext, which
        // is a property of the format (one GCM seal per export, ADR-0008), not of this line.
        var total = 2L
        for (i in files.indices) total += 2L + nameBytes[i].size + 4L + files[i].data.size
        require(total <= Int.MAX_VALUE) { "export is too large to seal as one container" }

        val out = ByteArray(total.toInt())
        var offset = 0
        writeBigEndianUInt16(out, offset, files.size); offset += 2
        for (i in files.indices) {
            val name = nameBytes[i]
            writeBigEndianUInt16(out, offset, name.size); offset += 2
            name.copyInto(out, offset); offset += name.size
            writeBigEndianUInt32(out, offset, files[i].data.size.toLong()); offset += 4
            files[i].data.copyInto(out, offset); offset += files[i].data.size
        }
        return out
    }

    fun decodeContainerPlaintext(data: ByteArray): List<ExportContainerFile> {
        var offset = 0
        // Deliberately not named `require`: shadowing the stdlib function with something that
        // throws a different exception type is how a later edit calls the wrong one by accident.
        fun requireAvailable(count: Long) {
            // Length fields are unsigned on the wire and can name more bytes than exist (a
            // truncated or hand-edited plaintext). Compared in Long so a 4 GB length can't wrap
            // into a small positive Int and read the wrong window.
            if (count < 0 || offset + count > data.size) {
                throw ExportEncryptionException.MalformedContainerPlaintext
            }
        }

        requireAvailable(2)
        val fileCount = readBigEndianUInt16(data, offset); offset += 2
        val files = ArrayList<ExportContainerFile>(fileCount)
        repeat(fileCount) {
            requireAvailable(2)
            val nameLength = readBigEndianUInt16(data, offset); offset += 2
            requireAvailable(nameLength.toLong())
            val name = String(data, offset, nameLength, StandardCharsets.UTF_8); offset += nameLength
            requireAvailable(4)
            val dataLength = readBigEndianUInt32(data, offset); offset += 4
            requireAvailable(dataLength)
            val fileData = data.copyOfRange(offset, offset + dataLength.toInt()); offset += dataLength.toInt()
            files.add(ExportContainerFile(name, fileData))
        }
        // Trailing bytes mean this isn't the layout it claims to be, even though every individual
        // field parsed — same final check iOS makes.
        if (offset != data.size) throw ExportEncryptionException.MalformedContainerPlaintext
        return files
    }

    // MARK: - KDF (PBKDF2-HMAC-SHA256)

    /**
     * Derives the AES-256 key from [passphrase] exactly as iOS does: PBKDF2-HMAC-SHA256 over the
     * passphrase's **raw UTF-8 bytes**.
     *
     * That last detail is the whole reason this function is more than one line. iOS passes bytes
     * (`CCKeyDerivationPBKDF` takes a `char*` and a length); JCE's `PBEKeySpec` takes a `char[]`
     * and leaves the char→byte encoding to the provider. Most providers use UTF-8, but the
     * platform's own history proves the ambiguity is real: Android ships a separate
     * `PBKDF2WithHmacSHA1And8BIT` algorithm name precisely because a Bouncy-Castle-lineage
     * provider folds each char to its low 8 bits instead. Under that convention an ASCII
     * passphrase derives the same key and a non-ASCII one silently derives a different key — an
     * export that opens on the phone that wrote it and nowhere else, with no error to explain it.
     *
     * So: [macPbkdf2] is the reference implementation (RFC 2898 over `javax.crypto.Mac`,
     * unambiguous by construction, pinned to published test vectors in `ExportEncryptorTest`), and
     * the provider's `SecretKeyFactory` is used only after [fastKdfAvailable] has proven on this
     * device that it agrees with the reference on a deliberately non-ASCII probe. Correct
     * everywhere, fast where the platform lets it be. Do not delete the probe to "simplify" — it
     * is what makes using the fast path safe at all.
     */
    private fun deriveKey(passphrase: String, salt: ByteArray, iterations: Long): ByteArray {
        // iOS reaches `internalFailure` here for an empty passphrase (CCKeyDerivationPBKDF returns
        // kCCParamError for a zero-length password); JCE would throw from PBEKeySpec/SecretKeySpec
        // for the same input. Same outcome, stated once, rather than depending on which provider
        // happens to complain. Unreachable through the app: ExportPassphrasePolicy gates first.
        if (passphrase.isEmpty()) throw ExportEncryptionException.InternalFailure
        if (iterations <= 0L) throw ExportEncryptionException.InternalFailure

        if (fastKdfAvailable && iterations <= Int.MAX_VALUE.toLong()) {
            val spec = PBEKeySpec(passphrase.toCharArray(), salt, iterations.toInt(), KEY_LENGTH * 8)
            try {
                return SecretKeyFactory.getInstance(PBKDF2_ALGORITHM).generateSecret(spec).encoded
            } catch (e: GeneralSecurityException) {
                throw ExportEncryptionException.InternalFailure
            } finally {
                spec.clearPassword()
            }
        }
        return try {
            macPbkdf2(passphrase.toByteArray(StandardCharsets.UTF_8), salt, iterations, KEY_LENGTH)
        } catch (e: GeneralSecurityException) {
            throw ExportEncryptionException.InternalFailure
        }
    }

    /**
     * True when this device's `PBKDF2WithHmacSHA256` provider derives the same key as
     * [macPbkdf2] for a passphrase chosen to expose the char-encoding ambiguity described on
     * [deriveKey] (Arabic + an astral-plane emoji: multi-byte in UTF-8, surrogate-paired in
     * UTF-16, and different again under 8-bit folding). One iteration keeps the probe free.
     *
     * `by lazy` so the probe runs at most once per process, on the first export or decrypt, and
     * never on a cold app launch that doesn't touch encryption. Any failure — algorithm absent,
     * provider throwing, keys differing — falls back to the reference implementation rather than
     * failing the export: slower is acceptable, a key nobody else can reproduce is not.
     *
     * `internal` rather than private so `ExportEncryptorTest` can report which path this JVM/device
     * actually took; a test that can't tell the two apart would happily pass while only ever
     * exercising one of them.
     */
    internal val fastKdfAvailable: Boolean by lazy {
        runCatching {
            val probePassphrase = "بادان-passphrase-🌙"
            val probeSalt = ByteArray(SALT_LENGTH) { it.toByte() }
            val spec = PBEKeySpec(probePassphrase.toCharArray(), probeSalt, 1, KEY_LENGTH * 8)
            val viaProvider = try {
                SecretKeyFactory.getInstance(PBKDF2_ALGORITHM).generateSecret(spec).encoded
            } finally {
                spec.clearPassword()
            }
            val viaReference = macPbkdf2(
                probePassphrase.toByteArray(StandardCharsets.UTF_8), probeSalt, 1L, KEY_LENGTH,
            )
            viaProvider.contentEquals(viaReference)
        }.getOrDefault(false)
    }

    /**
     * PBKDF2 (RFC 2898 §5.2) over HMAC-SHA256, taking the password as bytes so there is no
     * encoding to get wrong. Kept general over [dkLen] rather than hardcoding the single 32-byte
     * block this codebase needs: the extra five lines are what stop a future key-size change from
     * silently producing a truncated first block.
     *
     * `internal` rather than private so `ExportEncryptorTest` can pin it directly to published
     * PBKDF2-HMAC-SHA256 test vectors. It is the arbiter [fastKdfAvailable] measures the platform
     * provider against, so "is it itself correct?" must be answered by something other than the
     * provider it is judging — and on a host where the fast path wins, nothing else would run it.
     */
    internal fun macPbkdf2(password: ByteArray, salt: ByteArray, iterations: Long, dkLen: Int): ByteArray {
        val mac = Mac.getInstance(HMAC_ALGORITHM)
        mac.init(SecretKeySpec(password, HMAC_ALGORITHM))
        val hLen = mac.macLength
        val blocks = (dkLen + hLen - 1) / hLen
        val derived = ByteArray(blocks * hLen)
        val u = ByteArray(hLen)
        val t = ByteArray(hLen)

        for (block in 1..blocks) {
            mac.update(salt)
            mac.update(byteArrayOf(
                (block ushr 24).toByte(), (block ushr 16).toByte(), (block ushr 8).toByte(), block.toByte(),
            ))
            mac.doFinal(u, 0)
            u.copyInto(t)
            var i = 1L
            while (i < iterations) {
                mac.update(u)
                mac.doFinal(u, 0)
                for (j in 0 until hLen) t[j] = (t[j].toInt() xor u[j].toInt()).toByte()
                i++
            }
            t.copyInto(derived, (block - 1) * hLen)
        }
        return derived.copyOfRange(0, dkLen)
    }

    // MARK: - Byte helpers

    private fun randomBytes(count: Int): ByteArray = ByteArray(count).also { secureRandom.nextBytes(it) }

    private fun writeBigEndianUInt16(out: ByteArray, offset: Int, value: Int) {
        out[offset] = (value ushr 8).toByte()
        out[offset + 1] = value.toByte()
    }

    private fun writeBigEndianUInt32(out: ByteArray, offset: Int, value: Long) {
        out[offset] = (value ushr 24).toByte()
        out[offset + 1] = (value ushr 16).toByte()
        out[offset + 2] = (value ushr 8).toByte()
        out[offset + 3] = value.toByte()
    }

    private fun readBigEndianUInt16(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xFF) shl 8) or (bytes[offset + 1].toInt() and 0xFF)

    private fun readBigEndianUInt32(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xFF) shl 24) or
            ((bytes[offset + 1].toLong() and 0xFF) shl 16) or
            ((bytes[offset + 2].toLong() and 0xFF) shl 8) or
            (bytes[offset + 3].toLong() and 0xFF)
}

/**
 * The passphrase rule shared by the UI (enables/disables Run, drives the inline validation
 * message) and [ExportRunner] (defense-in-depth — a caller that skipped the UI, e.g. a future
 * automation surface, still can't produce an unencrypted sensitive export). Single source of
 * truth so the two never drift.
 *
 * Mirror of iOS `ExportPassphrasePolicy`, including the counting rule (see [length]).
 */
object ExportPassphrasePolicy {
    /**
     * 10 characters: short enough not to feel punitive for a one-off export, long enough that it
     * isn't a 4-digit-PIN-shaped false sense of security. Not a full strength meter — this is a
     * local-file passphrase with a deliberately slow KDF (600k rounds) behind it, not an
     * online-guessable account password.
     */
    const val MINIMUM_LENGTH: Int = 10

    fun isValid(passphrase: String): Boolean = length(passphrase) >= MINIMUM_LENGTH

    fun matches(passphrase: String, confirmation: String): Boolean = passphrase == confirmation

    /**
     * Counts user-perceived characters (Unicode extended grapheme clusters, UAX #29) rather than
     * UTF-16 code units, because iOS counts `String.count` — which is grapheme clusters — and this
     * policy is supposed to be one rule, not two that agree on ASCII.
     *
     * The divergence is small but real and always in the wrong direction: `"🌙"` is one character
     * to a user and to iOS, two to `String.length`. A nine-emoji passphrase would be accepted on
     * Android and rejected on iOS, so the platform with no passphrase-entry UI yet would be the
     * lenient one. `BreakIterator` is `java.text`, present since API 1 — no dependency, no
     * `minSdk` concern.
     */
    fun length(passphrase: String): Int {
        if (passphrase.isEmpty()) return 0
        val iterator = BreakIterator.getCharacterInstance().apply { setText(passphrase) }
        var count = 0
        while (iterator.next() != BreakIterator.DONE) count++
        return count
    }
}
