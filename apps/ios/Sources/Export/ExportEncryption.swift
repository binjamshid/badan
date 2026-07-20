import Foundation
import CryptoKit
import CommonCrypto

/// One file bundled into (or extracted out of) an encrypted export container. `name` is a
/// plain relative filename (`"raw.csv"`, `"bundle.json"`, …) — never a path — matching whatever
/// `ExportRunner` had already written to the export's temp folder before wrapping it.
struct ExportContainerFile: Equatable {
    let name: String
    let data: Data
}

/// Typed failures from `ExportEncryptor.decrypt`, so a caller (UI or test) can tell "this
/// passphrase is wrong" apart from "this isn't a BADAN export container" apart from "the bytes
/// were altered" — a single generic `Error` would force the UI to guess from a string.
enum ExportEncryptionError: Error, Equatable {
    /// Fewer than the fixed header's 26 bytes — not even enough to read the magic/version/KDF
    /// fields, let alone a ciphertext.
    case truncatedHeader
    /// The first 4 bytes aren't `ExportEncryptor.magic` — this isn't a BADAN export container
    /// at all (e.g. a plain CSV/JSON file, or an unrelated file).
    case notAContainer
    /// The magic matched but the format-version byte is one this build doesn't know how to
    /// read. Bumped only on an actual byte-layout change (see the ADR); a future build must
    /// keep reading version 1 rather than erroring on it, so this case exists for a version
    /// this build genuinely doesn't understand.
    case unsupportedVersion(UInt8)
    /// The KDF-id byte names a key-derivation function this build doesn't implement.
    case unsupportedKDF(UInt8)
    /// AES-GCM's authentication tag didn't verify. This is the single failure mode for both
    /// "wrong passphrase" (the derived key doesn't match) and "tampered ciphertext" (the bytes
    /// changed after sealing) — GCM makes those cryptographically indistinguishable by design,
    /// so the container format cannot honestly report which one happened, only that the
    /// contents cannot be trusted.
    case incorrectPassphraseOrTamperedData
    /// The (already-authenticated, already-decrypted) plaintext didn't parse as the inner
    /// multi-file layout — would indicate a bug in `encrypt`, not anything a user did, since
    /// GCM already ruled out tampering by this point.
    case malformedContainerPlaintext
    /// A lower-level system call failed in a way that isn't reachable through normal use:
    /// `SecRandomCopyBytes` returning non-success, or `CCKeyDerivationPBKDF` rejecting its
    /// parameters (its only documented failure, `kCCParamError`, requires an empty passphrase
    /// or a zero iteration count — both already excluded by `ExportPassphrasePolicy` and this
    /// file's own constants before either function is ever called).
    case internalFailure
}

/// Encrypts/decrypts a BADAN export bundle for the `includeSensitive` case (review ledger #19,
/// deferred fix 3 / FEAT-185). See `docs/adr/ADR-0008-*.md` for the full threat model and the
/// byte-exact container format this implements; this file is the reference implementation the
/// ADR's format section is written against.
///
/// Standard primitives only, no new dependencies: AES-256-GCM via CryptoKit for authenticated
/// encryption, PBKDF2-HMAC-SHA256 via CommonCrypto for the passphrase KDF (CryptoKit has no
/// PBKDF2). A single container can hold more than one inner file (CSV export produces
/// raw.csv/derived.csv/events.csv/manifest.json) so one passphrase, one KDF run, and one
/// GCM seal cover an entire export rather than one per file.
enum ExportEncryptor {

    // MARK: - Format constants (byte-exact — see the ADR)

    /// 4-byte ASCII magic identifying a BADAN encrypted-export container.
    static let magic: [UInt8] = Array("BDNX".utf8)
    static let formatVersion: UInt8 = 1
    static let kdfIdPBKDF2SHA256: UInt8 = 1
    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16
    /// magic(4) + version(1) + kdfId(1) + iterations(4) + salt(16).
    static let headerLength = 4 + 1 + 1 + 4 + 16

    /// PBKDF2-HMAC-SHA256 rounds used for new exports. 600,000 matches OWASP's Password
    /// Storage Cheat Sheet (Dec 2023 revision) minimum recommendation for PBKDF2-HMAC-SHA256 —
    /// see the ADR's re-evaluation gate for when this number should move. Benchmarked at
    /// roughly a few hundred milliseconds on an A-series/M-series iPhone target, which is a
    /// one-time cost paid once per export, not per screen render.
    static let defaultIterations: UInt32 = 600_000

    /// The file name every encrypted export is written under inside its temp folder —
    /// `ExportRunner` and `ExportCenterViewModel` both key off this exact name.
    static let containerFileName = "export.badanenc"

    // MARK: - Encrypt

    /// Wraps `files` into one encrypted container under `passphrase`. `files` must be
    /// non-empty; every name must be unique (both are programmer errors on this codebase's own
    /// call sites, not user-triggerable, hence the precondition rather than a thrown error).
    static func encrypt(files: [ExportContainerFile], passphrase: String,
                        iterations: UInt32 = defaultIterations) throws -> Data {
        precondition(!files.isEmpty, "an encrypted export container must hold at least one file")
        precondition(Set(files.map(\.name)).count == files.count, "container file names must be unique")

        let plaintext = Self.encodeContainerPlaintext(files)
        let salt = try Self.randomBytes(count: saltLength)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            // Only possible if CryptoKit produced a nonce of an unexpected size, which never
            // happens via `AES.GCM.seal`'s own generated-nonce path (Self.nonceLength/12 always).
            throw ExportEncryptionError.internalFailure
        }

        var header = Data(magic)
        header.append(formatVersion)
        header.append(kdfIdPBKDF2SHA256)
        header.append(Self.bigEndianBytes(iterations))
        header.append(salt)
        return header + combined
    }

    // MARK: - Decrypt

    /// Recovers the original files from a container produced by `encrypt`. Throws
    /// `ExportEncryptionError.incorrectPassphraseOrTamperedData` for both a wrong passphrase and
    /// a tampered container — see that case's doc comment for why the two can't be told apart.
    static func decrypt(_ container: Data, passphrase: String) throws -> [ExportContainerFile] {
        guard container.count >= headerLength else { throw ExportEncryptionError.truncatedHeader }
        let bytes = [UInt8](container)

        guard Array(bytes[0..<4]) == magic else { throw ExportEncryptionError.notAContainer }
        let version = bytes[4]
        guard version == formatVersion else { throw ExportEncryptionError.unsupportedVersion(version) }
        let kdfId = bytes[5]
        guard kdfId == kdfIdPBKDF2SHA256 else { throw ExportEncryptionError.unsupportedKDF(kdfId) }

        let iterations = Self.bigEndianUInt32(bytes, offset: 6)
        let salt = Data(bytes[10..<26])
        let combined = container.suffix(from: container.startIndex + headerLength)

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let plaintext: Data
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: Data(combined))
            plaintext = try AES.GCM.open(sealedBox, using: key)
        } catch {
            // CryptoKit's own errors here are either "combined data too short/malformed" or
            // "authentication failed" — both mean the same thing to a caller: this passphrase
            // (or these bytes) cannot be trusted. Not surfacing CryptoKit's own error type keeps
            // this a stable, testable boundary independent of CryptoKit's internal error cases.
            throw ExportEncryptionError.incorrectPassphraseOrTamperedData
        }
        return try Self.decodeContainerPlaintext(plaintext)
    }

    // MARK: - Inner multi-file plaintext layout (byte-exact — see the ADR)

    /// `fileCount(UInt16 BE)`, then per file: `nameLength(UInt16 BE) name(UTF-8) dataLength
    /// (UInt32 BE) data`. No per-file checksum field — AES-GCM already authenticates the whole
    /// plaintext as one unit, so a single tampered byte anywhere fails the outer `decrypt` before
    /// this layout is ever parsed.
    static func encodeContainerPlaintext(_ files: [ExportContainerFile]) -> Data {
        var out = Data()
        out.append(Self.bigEndianBytes(UInt16(files.count)))
        for file in files {
            let nameData = Data(file.name.utf8)
            out.append(Self.bigEndianBytes(UInt16(nameData.count)))
            out.append(nameData)
            out.append(Self.bigEndianBytes(UInt32(file.data.count)))
            out.append(file.data)
        }
        return out
    }

    static func decodeContainerPlaintext(_ data: Data) throws -> [ExportContainerFile] {
        let bytes = [UInt8](data)
        var offset = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard offset + count <= bytes.count else { throw ExportEncryptionError.malformedContainerPlaintext }
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }

        let fileCount = Int(Self.bigEndianUInt16(Array(try take(2))))
        var files: [ExportContainerFile] = []
        files.reserveCapacity(fileCount)
        for _ in 0..<fileCount {
            let nameLength = Int(Self.bigEndianUInt16(Array(try take(2))))
            guard let name = String(bytes: try take(nameLength), encoding: .utf8) else {
                throw ExportEncryptionError.malformedContainerPlaintext
            }
            let dataLength = Int(Self.bigEndianUInt32(Array(try take(4))))
            let fileData = Data(try take(dataLength))
            files.append(ExportContainerFile(name: name, data: fileData))
        }
        guard offset == bytes.count else { throw ExportEncryptionError.malformedContainerPlaintext }
        return files
    }

    // MARK: - KDF (PBKDF2-HMAC-SHA256 via CommonCrypto — CryptoKit has no PBKDF2)

    /// `cString(using:)` rather than `Array(passphrase.utf8)` deliberately: a `cString` is always
    /// at least 1 element (the trailing NUL), so `baseAddress` is never `nil` even for an empty
    /// passphrase — this function must not crash on bad input, only throw, regardless of what
    /// policy the caller layer (`ExportPassphrasePolicy`) already enforces upstream.
    private static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        guard let passwordCString = passphrase.cString(using: .utf8) else { throw ExportEncryptionError.internalFailure }
        let passwordLength = passwordCString.count - 1 // exclude the NUL terminator cString always appends
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: 32) // AES-256 key

        let status = derived.withUnsafeMutableBufferPointer { derivedPtr -> Int32 in
            passwordCString.withUnsafeBufferPointer { pwPtr -> Int32 in
                saltBytes.withUnsafeBufferPointer { saltPtr -> Int32 in
                    Int32(CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress, passwordLength,
                        saltPtr.baseAddress, saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedPtr.baseAddress, derivedPtr.count))
                }
            }
        }
        guard status == kCCSuccess else { throw ExportEncryptionError.internalFailure }
        return SymmetricKey(data: derived)
    }

    // MARK: - Byte helpers

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw ExportEncryptionError.internalFailure }
        return Data(bytes)
    }

    private static func bigEndianBytes(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }

    private static func bigEndianBytes(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func bigEndianUInt16(_ bytes: [UInt8]) -> UInt16 {
        (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    private static func bigEndianUInt32(_ bytes: [UInt8], offset: Int = 0) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}

/// The passphrase rule shared by the UI (enables/disables Run, drives the inline validation
/// message) and `ExportRunner` (defense-in-depth — a caller that skipped the UI, e.g. a future
/// automation surface, still can't produce an unencrypted `includeSensitive` export). Single
/// source of truth so the two never drift.
enum ExportPassphrasePolicy {
    /// 10 characters: short enough not to feel punitive for a one-off export, long enough that
    /// it isn't a 4-digit-PIN-shaped false sense of security. Not a full strength meter — this
    /// is a local-file passphrase with a deliberately slow KDF (600k rounds) behind it, not an
    /// online-guessable account password.
    static let minimumLength = 10

    static func isValid(_ passphrase: String) -> Bool { passphrase.count >= minimumLength }

    static func matches(_ passphrase: String, confirmation: String) -> Bool { passphrase == confirmation }
}
