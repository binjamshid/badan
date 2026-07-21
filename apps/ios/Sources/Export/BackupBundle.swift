import Foundation
import CryptoKit

/// EPIC-18 — full backup & restore (plan §12 EPIC-18).
///
/// A *backup* is one artifact that contains everything BADAN holds for the user: the full-scope
/// JSON v1.0 data bundle (every namespace the caller gathered, with consent), the configuration
/// that shapes it (`export_templates`, `automation_schedules`, `customization`, and — encrypted
/// only — `export_destinations` sans-secrets), a human-readable `DATA_DICTIONARY.md`, and a
/// top-level manifest binding those files together with per-file SHA-256. It is the same data an
/// ordinary export produces; a backup's added value is that it is *restorable* — a single file the
/// user can move to a new device and read back in.
///
/// **Byte-parity across platforms is the load-bearing property of this file** (plan §4.6). A
/// backup written on iOS must restore on Android and vice-versa, so both the plaintext wrapper and
/// the encrypted container are assembled from the same deterministic primitives the export writers
/// already share: `CanonicalJSON` for every JSON byte and `ExportEncryptor` for the encrypted
/// container (whose byte-exact format reached iOS/Android parity in Phase 0). `BackupBundle` adds
/// no encoder of its own — it composes the two that are already pinned by golden fixtures.
///
/// This type is a pure transform: build() takes materialized records + config and returns bytes;
/// parse()/preview()/plan() take bytes and return staged, inspectable models. It reads no
/// repository and touches no database, which is what keeps the byte-parity fixtures able to drive
/// it directly and keeps restore's *commit* — the only destructive step — out of the pure core and
/// behind the host's staged-import machinery (see `RestorePlan`).
enum BackupBundle {

    // MARK: - Format constants

    /// The backup wrapper/manifest schema version. Independent of `ExportSchema.version` (the
    /// data-bundle contract): the two evolve for different reasons — a new namespace bumps the
    /// data schema, a new *config* section or wrapper field bumps this one — and conflating them
    /// would force a data-schema bump every time a template field changed.
    static let version = "1.0"

    /// The three logical files every backup carries, plaintext or encrypted. Restore recovers this
    /// exact set regardless of how the bytes arrived (JSON wrapper vs. `ExportEncryptor` container),
    /// which is what makes "written on one platform, restored on the other" a single code path.
    static let manifestFileName = "backup_manifest.json"
    static let dictionaryFileName = "DATA_DICTIONARY.md"
    static let bundleFileName = "bundle.json"

    /// File-name scheme per the export house rules: `BADAN_<bundle>_<range>.<ext>`. A backup's
    /// range is a single day (its creation date) because it is a point-in-time snapshot, not a
    /// windowed export.
    static let namePrefix = "BADAN_backup_"
    static let plaintextExtension = "json"
    static let encryptedExtension = "badanenc"

    // MARK: - Errors

    /// Typed restore failures, so the UI can tell an honest, specific story rather than guess from
    /// a string. Every case here means "do not import anything" — there is no partial-restore case
    /// (plan §12 EPIC-18 requirement 6).
    enum RestoreError: Error, Equatable {
        /// The backup was written by a newer BADAN than this build understands. This is the §12
        /// EPIC-18 requirement 6 path: a bundle from a newer *backup* schema major version must
        /// fail honestly and completely, never import half of a shape this build cannot fully read.
        case schemaTooNew(found: String, supported: String)
        /// Not a BADAN backup at all — neither an `ExportEncryptor` container nor a backup wrapper.
        case notABackup
        /// The bytes are a backup but structurally broken (missing a required file, an unreadable
        /// wrapper). Carries a short, value-free reason for diagnostics.
        case malformed(String)
        /// A file's bytes do not match the SHA-256 the manifest recorded for it — truncation or
        /// tampering. Named per file so the UI can say which one.
        case checksumMismatch(file: String)
        /// The container is encrypted and either no passphrase was supplied or it was wrong (or the
        /// bytes were altered — AES-GCM cannot tell those two apart, by design; see
        /// `ExportEncryptionError`).
        case encrypted(ExportEncryptionError)
        /// The encrypted container declares a PBKDF2 iteration count above `maxKdfIterations`.
        ///
        /// `ExportEncryptor`'s own doc comment (and Android's) is explicit: there is no import path
        /// today, and *whoever builds one* must add a KDF-cost cap at that boundary, on both
        /// platforms together, before a hostile file can make the 600k-round KDF run for hours.
        /// Restore is that import path, so this is that cap — checked from the header before the
        /// key is ever derived.
        case kdfCostTooHigh(iterations: UInt32, cap: UInt32)
    }

    /// The ceiling on an encrypted backup's declared PBKDF2 rounds, enforced at restore before the
    /// KDF runs (see `RestoreError.kdfCostTooHigh`). ~6.6× the 600k default `ExportEncryptor`
    /// writes today, so a legitimate future increase to the write-side cost still opens, while a
    /// container claiming tens of millions of rounds — the only reason to inflate this field is to
    /// make a victim's device grind — is refused. If the write-side default is ever raised past
    /// this, raise this in the same change, on both platforms.
    static let maxKdfIterations: UInt32 = 4_000_000

    // MARK: - Build

    /// The bytes to write to disk, plus the recovered-on-restore logical files for tests/callers
    /// that want to assert structure without re-reading the artifact off disk.
    struct Artifact {
        let fileName: String
        let data: Data
        let encrypted: Bool
        /// `[backup_manifest.json, DATA_DICTIONARY.md, bundle.json]` — the same set restore
        /// recovers. Exposed so a parity test can compare logical content independent of transport.
        let logicalFiles: [ExportContainerFile]
    }

    /// Assemble one backup artifact.
    ///
    /// The data arrays mirror `JSONBundleWriter.data` one-for-one and are serialized through it, so
    /// the backup's `bundle.json` is byte-identical to what the ordinary JSON export would produce
    /// for the same records — a backup is an export, not a second serialization to keep in sync.
    ///
    /// `passphrase` decides the variant: non-nil wraps the whole artifact (every namespace *and*
    /// the config, not only the sensitive part — §12 EPIC-18 requirement 2) in an `ExportEncryptor`
    /// container; nil produces the plaintext JSON wrapper. It is validated against
    /// `ExportPassphrasePolicy` when present so a backup can never be sealed under a passphrase too
    /// weak for the KDF to matter.
    ///
    /// Destinations are handled structurally, not by convention (§12 EPIC-18 requirement 3): they
    /// are echoed *only* into an encrypted bundle and *only* through `Self.destinationSansSecrets`,
    /// which has no field a secret or a secret-reference fits into. A plaintext bundle has no
    /// `export_destinations` key at all.
    ///
    /// `hydration` is the drink slice (EPIC-38): the full ledger the caller gathered for a backup —
    /// entries with their revision chains, day summaries, goals, and the referenced beverages. It is
    /// carried **whole, with notes**, unlike the redacted default export: a backup is the user's
    /// complete data for their own device migration, and the bundle already carries symptom, workout
    /// and nutrition notes unconditionally (`JSONBundleWriter` writes their `note` field with no
    /// redaction), so dropping only *water* notes would be arbitrary. The encrypted variant protects
    /// the whole bundle; a plaintext backup carries notes by the same design that carries every other
    /// log's notes. A `nil`/empty payload writes no `logs.hydration` at all (the absent-not-empty rule
    /// `JSONBundleWriter` documents), so the pre-hydration goldens stay byte-identical.
    static func build(
        manifest: ExportManifest,
        rawSamples: [RawSample], intervalRecords: [IntervalRecord], sessions: [Session],
        derivedValues: [DerivedValue], baselines: [Baseline],
        symptoms: [SymptomEntry], adherence: [AdherenceEvent],
        workouts: [WorkoutEntry], nutrition: [NutritionEntry],
        hydration: HydrationExportPayload? = nil,
        journal: JournalExportPayload? = nil,
        includeRoutes: Bool = false,
        templates: [ExportTemplate], destinations: [ExportDestination],
        customization: CanonicalJSON, schedules: [CanonicalJSON],
        createdAt: Date, appVersion: String, platform: String,
        passphrase: String? = nil
    ) throws -> Artifact {
        let encrypting = passphrase != nil
        if let passphrase, !ExportPassphrasePolicy.isValid(passphrase) {
            // Defense in depth mirroring ExportRunner: a caller that skipped the UI still cannot
            // seal a backup under a passphrase too weak for the 600k-round KDF to matter.
            throw RestoreError.encrypted(.incorrectPassphraseOrTamperedData)
        }

        let config = configObject(templates: templates, destinations: destinations,
                                  customization: customization, schedules: schedules,
                                  encrypting: encrypting)

        let bundleData = try JSONBundleWriter().data(
            manifest: manifest, rawSamples: rawSamples, intervalRecords: intervalRecords,
            sessions: sessions, derivedValues: derivedValues, baselines: baselines,
            symptoms: symptoms, adherence: adherence, workouts: workouts, nutrition: nutrition,
            includeRoutes: includeRoutes, config: config,
            // A backup carries the drink ledger WHOLE — notes included — because it is the user's
            // complete data, and the bundle already carries every other log's notes unredacted.
            hydration: hydration, hydrationRedaction: HydrationRedactionPolicy(includeNotes: true),
            // EPIC-29: the journal + context statuses ride the backup for the same reason every
            // other log family does — a backup is the user's complete data for their own device
            // migration, and a migration that silently dropped the behavior journal would lose
            // history no re-sync can rebuild. The CONSENT for writing it back is re-asked on the
            // receiving device (`RestoreConsent`), which is where an I7 namespace is gated; leaving
            // it out of the file here would not be privacy, it would be data loss. Nil/empty writes
            // nothing at all, so the byte-pinned backup goldens are untouched.
            journal: journal)

        let dictionaryData = Data(dataDictionaryMarkdown().utf8)

        // The manifest checksums the OTHER two files, never itself — a file cannot carry its own
        // digest without a fixed-point problem, and the wrapper/container that transports the
        // manifest is what proves the manifest itself arrived intact (GCM tag when encrypted, the
        // wrapper's own bytes when plaintext).
        let manifestData = Data(backupManifest(
            bundleData: bundleData, dictionaryData: dictionaryData, createdAt: createdAt,
            appVersion: appVersion, platform: platform, encrypted: encrypting,
            templates: templates, destinations: destinations, schedules: schedules,
            hasCustomization: !isEmptyObject(customization),
            symptomCount: symptoms.count, adherenceCount: adherence.count).render().utf8)

        // Sorted by name so the logical set is order-stable across platforms and rebuilds — the
        // encrypted container and the plaintext wrapper both serialize in this order.
        let files = [
            ExportContainerFile(name: dictionaryFileName, data: dictionaryData),
            ExportContainerFile(name: manifestFileName, data: manifestData),
            ExportContainerFile(name: bundleFileName, data: bundleData)
        ].sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }

        let range = dayStamp(createdAt)
        if let passphrase {
            let container = try ExportEncryptor.encrypt(files: files, passphrase: passphrase)
            return Artifact(fileName: "\(namePrefix)\(range).\(encryptedExtension)",
                            data: container, encrypted: true, logicalFiles: files)
        }
        let wrapper = Data(plaintextWrapper(files).render().utf8)
        return Artifact(fileName: "\(namePrefix)\(range).\(plaintextExtension)",
                        data: wrapper, encrypted: false, logicalFiles: files)
    }

    // MARK: - Config echo

    /// The `config` object embedded in `bundle.json`.
    ///
    /// `export_templates`, `automation_schedules` and `customization` are always present (they hold
    /// no secrets). `export_destinations` appears **only** when encrypting, and each row goes
    /// through `destinationSansSecrets` — the credential reference, folder-bookmark reference and
    /// provider-account reference are dropped, because even a *reference* to a Keychain/Keystore
    /// item is meaningless on another device and its presence in a file is exactly the kind of
    /// leak §12 EPIC-18 requirement 3 forbids.
    static func configObject(templates: [ExportTemplate], destinations: [ExportDestination],
                             customization: CanonicalJSON, schedules: [CanonicalJSON],
                             encrypting: Bool) -> [String: CanonicalJSON] {
        var config: [String: CanonicalJSON] = [
            "export_templates": .array(templates
                .sorted { $0.id < $1.id }
                .map(templateObject)),
            "automation_schedules": .array(schedules),
            "customization": customization
        ]
        if encrypting {
            config["export_destinations"] = .array(destinations
                .sorted { $0.id < $1.id }
                .map(destinationSansSecrets))
        }
        return config
    }

    private static func templateObject(_ t: ExportTemplate) -> CanonicalJSON {
        // A template carries no secret: it is a saved *shape* (scope, range rule, format,
        // aggregation, layout). `destination_id` is a reference to a destination row, not a
        // credential, and is preserved so a restored template still points at the right place once
        // the user re-authorizes that destination.
        .object([
            "id": .string(t.id),
            "name": .string(t.name),
            "scope": scopeObject(t.scope),
            "range_rule": .string(t.rangeRule.storageValue),
            "format": .string(t.format.rawValue),
            "aggregation": .string(t.aggregation.storageMethod
                .map { "\(t.aggregation.storageGranularity):\($0)" } ?? t.aggregation.storageGranularity),
            "layout": .string(t.layout.rawValue),
            "include_schema_docs": .bool(t.includeSchemaDocs),
            "destination_id": .string(nullable: t.destinationId),
            "is_preset": .bool(t.isPreset),
            "created_at": .string(TimestampFormatting.string(t.createdAt, tzId: "UTC")),
            "updated_at": .string(TimestampFormatting.string(t.updatedAt, tzId: "UTC")),
            "origin_device_id": .string(t.originDeviceId),
            "deleted_at": t.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: "UTC")) } ?? .null
        ])
    }

    private static func scopeObject(_ scope: ExportScope) -> CanonicalJSON {
        func list(_ values: [String]?) -> CanonicalJSON {
            values.map { CanonicalJSON.array($0.map { CanonicalJSON.string($0) }) } ?? .null
        }
        return .object([
            "metric_ids": list(scope.metricIds),
            "families": list(scope.families),
            "start_date": scope.startDate.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: "UTC")) } ?? .null,
            "end_date": scope.endDate.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: "UTC")) } ?? .null,
            "source_ids": list(scope.sourceIds),
            "include_raw": .bool(scope.includeRaw),
            "include_derived": .bool(scope.includeDerived),
            "include_suppressed": .bool(scope.includeSuppressed),
            "include_sensitive": .bool(scope.includeSensitive),
            "unit_profile": .string(scope.unitProfile.rawValue),
            "language": .string(scope.language.rawValue)
        ])
    }

    /// The **only** projection of a destination allowed into a bundle, and it is structural: there
    /// is no branch here that could emit `credentialRef`, `folderBookmarkRef` or
    /// `providerAccountRef`. Adding one means editing this function — the review §12 EPIC-18
    /// requirement 3 is meant to force. `BackupBundleTests.testDestinationSansSecretsProjectionHasNoSecretFields`
    /// reflects over this projection and fails on any credential-namespace string, and
    /// `testPlaintextBackupExcludesDestinationsEntirely` / `testEncryptedBackupCarriesDestinationsButNoSecrets`
    /// prove the two bundle paths.
    static func destinationSansSecrets(_ d: ExportDestination) -> CanonicalJSON {
        .object([
            "id": .string(d.id),
            "kind": .string(d.kind.rawValue),
            "display_name": .string(d.displayName),
            "tls_policy": .string(d.tlsPolicy.rawValue),
            "status": .string(d.status.rawValue),
            // Non-secret routing only. `endpoint_url` is a location, not a credential (a token in a
            // query string is barred at the `ExportDestinationConfig` layer, not here); header
            // *template ids* name templates held elsewhere, never header values.
            "endpoint_url": .string(nullable: d.config.endpointURL),
            "http_method": .string(nullable: d.config.httpMethod),
            "provider_id": .string(nullable: d.config.providerId),
            "header_template_ids": .array(d.config.headerTemplateIds.sorted().map { CanonicalJSON.string($0) }),
            "created_at": .string(TimestampFormatting.string(d.createdAt, tzId: "UTC")),
            "updated_at": .string(TimestampFormatting.string(d.updatedAt, tzId: "UTC")),
            "origin_device_id": .string(d.originDeviceId),
            "deleted_at": d.deletedAt.map { CanonicalJSON.string(TimestampFormatting.string($0, tzId: "UTC")) } ?? .null
        ])
    }

    // MARK: - Backup manifest

    private static func backupManifest(
        bundleData: Data, dictionaryData: Data, createdAt: Date, appVersion: String,
        platform: String, encrypted: Bool, templates: [ExportTemplate],
        destinations: [ExportDestination], schedules: [CanonicalJSON], hasCustomization: Bool,
        symptomCount: Int, adherenceCount: Int
    ) -> CanonicalJSON {
        .object([
            "backup_schema_version": .string(version),
            "export_schema_version": .string(ExportSchema.version),
            "created_at": .string(TimestampFormatting.string(createdAt, tzId: "UTC")),
            "app": .object([
                "name": .string("BADAN"),
                "version": .string(appVersion),
                "platform": .string(platform)
            ]),
            "encryption": .string(encrypted ? "badanenc-v1" : "none"),
            // Per-file SHA-256 of every file EXCEPT this manifest (see build()). Sorted keys via
            // CanonicalJSON keep the object deterministic.
            "files": .object([
                bundleFileName: .object(["sha256": .string(sha256Hex(bundleData)),
                                         "bytes": .integer(bundleData.count)]),
                dictionaryFileName: .object(["sha256": .string(sha256Hex(dictionaryData)),
                                             "bytes": .integer(dictionaryData.count)])
            ]),
            // A summary the restore preview can show before any file is verified or parsed — a
            // fast, honest "here is what this claims to contain". The authoritative counts still
            // come from parsing bundle.json on restore; this is the label on the tin.
            "config": .object([
                "export_templates": .integer(templates.count),
                // Present as a count only when encrypted — a plaintext manifest must not even
                // disclose how many destinations exist, matching the config echo's own exclusion.
                "export_destinations": encrypted ? .integer(destinations.count) : .null,
                "automation_schedules": .integer(schedules.count),
                "customization": .bool(hasCustomization)
            ]),
            "sensitive_present": .bool(symptomCount > 0 || adherenceCount > 0)
        ])
    }

    // MARK: - Plaintext wrapper

    /// The on-disk shape of a plaintext backup: one JSON object listing the logical files as
    /// escaped strings.
    ///
    /// Files travel as *strings* rather than nested objects deliberately. Re-parsing an embedded
    /// JSON object and re-rendering it would reintroduce exactly the number-precision and key-order
    /// divergence `CanonicalJSON` exists to kill; keeping each file as its already-rendered text
    /// means the transported bytes are the bytes the manifest checksummed, and cross-platform
    /// equality is a property of the (shared) `CanonicalJSON` string escaper alone.
    static func plaintextWrapper(_ files: [ExportContainerFile]) -> CanonicalJSON {
        .object([
            "backup_schema_version": .string(version),
            "encryption": .string("none"),
            "files": .array(files
                .sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
                .map { file in
                    CanonicalJSON.object([
                        "name": .string(file.name),
                        "content": .string(String(decoding: file.data, as: UTF8.self))
                    ])
                })
        ])
    }

    // MARK: - Parse

    /// A parsed, checksum-verified, schema-checked backup. Holds the recovered logical files plus
    /// the parsed manifest and data bundle, so `preview` and `plan` do not re-parse.
    struct RestoreBundle {
        let schemaVersion: String
        let createdAt: String
        let originPlatform: String
        let originAppVersion: String
        let encrypted: Bool
        let logicalFiles: [ExportContainerFile]
        /// The parsed `bundle.json` root object (via `JSONSerialization` — parsing needs no
        /// byte-determinism, only rendering does).
        let bundle: [String: Any]
    }

    /// Recover a backup from bytes. `passphrase` is required iff the bytes are an encrypted
    /// container; it is ignored for a plaintext wrapper.
    ///
    /// Order matters and is a safety property: the schema-version gate runs **before** any file is
    /// verified or the data bundle is parsed, so a too-new backup fails without this build ever
    /// interpreting a shape it does not fully understand (§12 EPIC-18 requirement 6).
    static func parse(_ data: Data, passphrase: String? = nil) throws -> RestoreBundle {
        let files = try recoverFiles(data, passphrase: passphrase)

        guard let manifestFile = files.first(where: { $0.name == manifestFileName }),
              let manifest = try? JSONSerialization.jsonObject(with: manifestFile.data) as? [String: Any] else {
            throw RestoreError.malformed("missing or unreadable \(manifestFileName)")
        }

        let foundVersion = (manifest["backup_schema_version"] as? String) ?? ""
        guard isReadable(foundVersion) else {
            throw RestoreError.schemaTooNew(found: foundVersion, supported: version)
        }

        // Verify every checksummed file before trusting any of its content.
        if let checksumSpec = manifest["files"] as? [String: Any] {
            for (name, spec) in checksumSpec {
                guard let file = files.first(where: { $0.name == name }) else {
                    throw RestoreError.malformed("manifest names a missing file: \(name)")
                }
                let expected = ((spec as? [String: Any])?["sha256"] as? String) ?? ""
                guard sha256Hex(file.data) == expected else {
                    throw RestoreError.checksumMismatch(file: name)
                }
            }
        }

        guard let bundleFile = files.first(where: { $0.name == bundleFileName }),
              let bundle = try? JSONSerialization.jsonObject(with: bundleFile.data) as? [String: Any] else {
            throw RestoreError.malformed("missing or unreadable \(bundleFileName)")
        }

        let app = manifest["app"] as? [String: Any]
        return RestoreBundle(
            schemaVersion: foundVersion,
            createdAt: (manifest["created_at"] as? String) ?? "",
            originPlatform: (app?["platform"] as? String) ?? "",
            originAppVersion: (app?["version"] as? String) ?? "",
            encrypted: (manifest["encryption"] as? String).map { $0 != "none" } ?? false,
            logicalFiles: files,
            bundle: bundle)
    }

    /// Split the on-disk bytes into the logical file set, decrypting if the bytes are an
    /// `ExportEncryptor` container. This is the one place the two transports converge.
    private static func recoverFiles(_ data: Data, passphrase: String?) throws -> [ExportContainerFile] {
        if isEncryptedContainer(data) {
            guard let passphrase else { throw RestoreError.encrypted(.incorrectPassphraseOrTamperedData) }
            // Cap the KDF cost from the header BEFORE `decrypt` derives a key — the DoS boundary
            // the `ExportEncryptor` doc comment says an import path must add.
            if let iterations = declaredIterations(data), iterations > maxKdfIterations {
                throw RestoreError.kdfCostTooHigh(iterations: iterations, cap: maxKdfIterations)
            }
            do {
                return try ExportEncryptor.decrypt(data, passphrase: passphrase)
            } catch let error as ExportEncryptionError {
                throw RestoreError.encrypted(error)
            }
        }
        guard let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              wrapper["backup_schema_version"] != nil,
              let entries = wrapper["files"] as? [[String: Any]] else {
            throw RestoreError.notABackup
        }
        return entries.compactMap { entry in
            guard let name = entry["name"] as? String,
                  let content = entry["content"] as? String else { return nil }
            return ExportContainerFile(name: name, data: Data(content.utf8))
        }
    }

    /// Whether the bytes begin with the `ExportEncryptor` magic. Cheap and exact — the plaintext
    /// wrapper is a JSON object beginning with `{`, which can never collide with the 4-byte magic.
    static func isEncryptedContainer(_ data: Data) -> Bool {
        guard data.count >= ExportEncryptor.magic.count else { return false }
        return Array(data.prefix(ExportEncryptor.magic.count)) == ExportEncryptor.magic
    }

    /// The PBKDF2 iteration count an encrypted container declares, read from the fixed header
    /// (`magic(4) version(1) kdfId(1) iterations(4 BE) …`). `nil` if the bytes are too short to
    /// carry the field — those fall through to `ExportEncryptor.decrypt`'s own `truncatedHeader`.
    static func declaredIterations(_ data: Data) -> UInt32? {
        guard data.count >= 10 else { return nil }
        let b = [UInt8](data.prefix(10))
        return (UInt32(b[6]) << 24) | (UInt32(b[7]) << 16) | (UInt32(b[8]) << 8) | UInt32(b[9])
    }

    /// A backup is readable iff its major version is ≤ ours. A higher minor (e.g. `1.9` to our
    /// `1.0`) is tolerated — the restore reads the fields it knows and ignores the rest — but a
    /// higher major means an incompatible shape, and the honest answer is to refuse (§12 EPIC-18
    /// requirement 6), never to import a subset that looks complete.
    static func isReadable(_ found: String) -> Bool {
        let foundMajor = Int(found.split(separator: ".").first ?? "") ?? Int.max
        let ourMajor = Int(version.split(separator: ".").first ?? "") ?? 0
        return foundMajor <= ourMajor
    }

    // MARK: - Preview

    /// What a backup claims to contain, for the confirm-before-commit screen (§12 EPIC-18: preview
    /// before commit). Counts come from parsing `bundle.json`, so they describe the file, not the
    /// manifest's summary label.
    struct RestorePreview: Equatable {
        var schemaVersion: String
        var createdAt: String
        var originPlatform: String
        var originAppVersion: String
        var encrypted: Bool
        /// Per-namespace record counts (`raw_samples`, `interval_records`, `sessions`, `workouts`,
        /// `derived_values`, `baselines`, `logs.symptoms`, `logs.adherence`, `logs.workouts`,
        /// `logs.nutrition`, `logs.hydration`, `logs.journal`, `logs.context_statuses`).
        /// `logs.hydration` counts the drink *entries* (the full ledger, including revisions), the
        /// same normal-class family workouts/nutrition are. `logs.journal`/`logs.context_statuses`
        /// are sensitive-plus (I7) and are zeroed by `plan` without consent, like meds/symptoms.
        var namespaceCounts: [String: Int]
        /// True when the bundle carries any I7 namespace — medications/symptoms, or EPIC-29's
        /// behavior journal / context statuses. Drives whether the restore screen must show the
        /// sensitive-consent toggle, so a bundle whose only sensitive content is a journal still
        /// re-asks on the receiving device.
        var sensitivePresent: Bool
        var configCounts: [String: Int]
        var hasCustomization: Bool
    }

    static func preview(_ bundle: RestoreBundle) -> RestorePreview {
        func count(_ key: String) -> Int { (bundle.bundle[key] as? [Any])?.count ?? 0 }
        let logs = bundle.bundle["logs"] as? [String: Any]
        func logCount(_ key: String) -> Int { (logs?[key] as? [Any])?.count ?? 0 }

        let symptoms = logCount("symptoms")
        let adherence = logCount("adherence")
        // `logs.hydration` is an object (redaction/entries/summaries/…), so its record count is the
        // length of its `entries` array, not the object itself. A backup with no drinks has no
        // `hydration` key and reads as 0 — same absent-not-empty rule the writer follows.
        let hydrationEntries = ((logs?["hydration"] as? [String: Any])?["entries"] as? [Any])?.count ?? 0
        // EPIC-29's two sensitive-plus families. Counted (and gated) here for the same reason
        // symptoms/adherence are: a backup that carries them must re-ask on the RECEIVING device,
        // and a preview that didn't count them would leave `sensitivePresent` false for a bundle
        // whose only sensitive content is a behavior journal — the restore screen would then never
        // show the consent toggle and the rows would land un-authorized.
        let journalEntries = logCount("journal")
        let contextStatuses = logCount("context_statuses")

        let config = bundle.bundle["config"] as? [String: Any]
        func configArray(_ key: String) -> Int { (config?[key] as? [Any])?.count ?? 0 }

        return RestorePreview(
            schemaVersion: bundle.schemaVersion,
            createdAt: bundle.createdAt,
            originPlatform: bundle.originPlatform,
            originAppVersion: bundle.originAppVersion,
            encrypted: bundle.encrypted,
            namespaceCounts: [
                "raw_samples": count("raw_samples"),
                "interval_records": count("interval_records"),
                "sessions": count("sessions"),
                "workouts": count("workouts"),
                "derived_values": count("derived_values"),
                "baselines": count("baselines"),
                "logs.symptoms": symptoms,
                "logs.adherence": adherence,
                "logs.workouts": logCount("workouts"),
                "logs.nutrition": logCount("nutrition"),
                "logs.hydration": hydrationEntries,
                "logs.journal": journalEntries,
                "logs.context_statuses": contextStatuses
            ],
            sensitivePresent: symptoms > 0 || adherence > 0 || journalEntries > 0 || contextStatuses > 0,
            configCounts: [
                "export_templates": configArray("export_templates"),
                "export_destinations": configArray("export_destinations"),
                "automation_schedules": configArray("automation_schedules")
            ],
            hasCustomization: config?["customization"] != nil
                && !((config?["customization"] as? [String: Any])?.isEmpty ?? true))
    }

    // MARK: - Restore plan (staged import)

    /// The user's decision, given at restore time, for each independently-gated sensitive class.
    ///
    /// §12 EPIC-18 requirement 5: a sensitive namespace requires its consent toggle at *restore*
    /// time, not only at backup time. Backing up a bundle that contains meds/symptoms does not
    /// grant permission to write them back — the receiving device re-asks. Default deny.
    struct RestoreConsent: Equatable {
        var includeSensitive: Bool
        public init(includeSensitive: Bool = false) { self.includeSensitive = includeSensitive }
    }

    /// A staged, inspectable, reversible-by-design import.
    ///
    /// This is the descriptor the host's `import_batches` machinery stages before any row is
    /// written: a batch id every restored row will carry in its provenance (I1), the source and
    /// file it came from, the per-namespace counts that WILL be imported (sensitive excluded unless
    /// consented), and the state. It deliberately does **not** perform the write — the commit is a
    /// destructive step and belongs behind the batch machinery, so that "preview before commit" and
    /// "batch undo" (§12 EPIC-18 requirement 4) are structural, not a promise a pure function could
    /// keep.
    struct RestorePlan: Equatable {
        let batchId: String
        let sourceKind: String
        let fileName: String
        let state: String
        /// Per-namespace counts that this plan WILL import — sensitive namespaces are zero here
        /// unless `consent.includeSensitive` was true, so a plan can never carry sensitive rows
        /// the user did not re-authorize.
        let counts: [String: Int]
        let includesSensitive: Bool
        let createdAt: Date

        /// The `import_batches` row this plan stages (id, source_kind, file_name, state, counts,
        /// created_at) — the exact column set migration v1 reserved. `chunk_cursor` starts nil: a
        /// preview has consumed no chunks.
        var importBatchRow: (id: String, sourceKind: String, fileName: String, state: String,
                             chunkCursor: String?, countsJSON: String, createdAt: Date) {
            (batchId, sourceKind, fileName, state, nil, countsJSON, createdAt)
        }

        var countsJSON: String {
            CanonicalJSON.object(counts.mapValues { CanonicalJSON.integer($0) }).render()
        }
    }

    /// The state a freshly-staged, not-yet-committed restore sits in. Named rather than a bare
    /// string so the host and tests agree on the vocabulary.
    static let previewedState = "previewed"
    static let restoreSourceKind = "backup"

    /// Build the staged plan from a preview + the user's consent.
    ///
    /// The sensitive gate is applied here, once, by zeroing the sensitive namespace counts when
    /// consent is withheld — so every downstream consumer of the plan sees a set that already
    /// respects the toggle, and no later code has to remember to re-check it.
    static func plan(_ preview: RestorePreview, consent: RestoreConsent,
                     batchId: String, fileName: String, now: Date) -> RestorePlan {
        var counts = preview.namespaceCounts
        if !consent.includeSensitive {
            counts["logs.symptoms"] = 0
            counts["logs.adherence"] = 0
            counts["logs.journal"] = 0
            counts["logs.context_statuses"] = 0
        }
        return RestorePlan(
            batchId: batchId, sourceKind: restoreSourceKind, fileName: fileName,
            state: previewedState, counts: counts,
            includesSensitive: consent.includeSensitive && preview.sensitivePresent,
            createdAt: now)
    }

    // MARK: - DATA_DICTIONARY.md

    /// The human-readable schema companion carried inside every backup, so the file stays legible
    /// to an analyst (or the user) years later on a machine that has neither BADAN nor the contract
    /// files. Deliberately factual and wellness-safe: it describes fields, not health conclusions.
    ///
    /// Static content (no per-export values) so it contributes a stable checksum and does not leak
    /// anything about the specific person whose data the bundle holds.
    static func dataDictionaryMarkdown() -> String {
        """
        # BADAN backup — data dictionary

        This file travels inside every BADAN backup. It documents the layout of `bundle.json`
        (export schema \(ExportSchema.version)) and the backup wrapper (backup schema \(version)) so the
        data stays readable without the app.

        ## The backup

        A backup contains three files:

        - `backup_manifest.json` — backup schema version, creation time, originating app/platform,
          per-file SHA-256, and a summary of contents.
        - `DATA_DICTIONARY.md` — this file.
        - `bundle.json` — the full-scope data bundle plus a `config` section.

        A plaintext backup is a single JSON object whose `files` array carries the three files as
        text. An encrypted backup is a `badanenc-v1` container (AES-256-GCM, PBKDF2-HMAC-SHA256)
        holding the same three files; the passphrase covers the whole backup, not only sensitive
        records.

        ## bundle.json — data

        Raw and derived values are physically separate and never share a row shape:

        - `raw_samples` — point-in-time measurements, each with full provenance.
        - `interval_records` — aggregates over a window, with a 0–1 `coverage` fraction.
        - `sessions` — sleep and other non-workout episodes.
        - `workouts` — workout episodes; `hr_series_ref` is a query descriptor into `raw_samples`,
          not a copy of the series.
        - `derived_values` — engine-computed values; each carries `algorithm_id` and
          `algorithm_version`.
        - `baselines` — personal baselines with center/spread/band and `n_points`.
        - `logs.symptoms`, `logs.adherence` — the sensitive namespace (present only with consent).
        - `logs.workouts`, `logs.nutrition` — manual logs.
        - `logs.hydration` — the drink ledger: entries (with their revision chains), day summaries,
          goals, and referenced beverages. Carried whole in a backup, notes included.
        - `deletions` — tombstones (id + `deleted_at`) so a consumer can reconcile removals.

        Every timestamp is ISO-8601 with a numeric offset (never `Z`). Every value is in its
        canonical unit; `original_value`/`original_unit` record what the source reported.

        ## bundle.json — config

        - `export_templates` — saved export configurations.
        - `automation_schedules` — saved automation entries.
        - `customization` — presentation preferences (language, depth, units).
        - `export_destinations` — present in encrypted backups only, and always without any
          credential or credential reference. Destinations must be re-authorized after a restore.

        ## Restore

        Restoring stages the bundle as an import batch with a preview before anything is written,
        matches records you already have rather than duplicating them, and keeps the sensitive
        namespace behind its own consent toggle. A backup written by a newer version of BADAN than
        the one restoring it is refused rather than partially imported.
        """
    }

    // MARK: - Helpers

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `CanonicalJSON` is deliberately not `Equatable` (it is a render-only tree), so "did the
    /// caller pass an empty customization object" is answered by a shape match rather than `==`.
    private static func isEmptyObject(_ json: CanonicalJSON) -> Bool {
        if case .object(let members) = json { return members.isEmpty }
        return false
    }

    /// `YYYYMMDD` in UTC, for the single-day range in a snapshot's file name.
    private static func dayStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
