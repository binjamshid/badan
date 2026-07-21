import Foundation

public enum ExportFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case csv, json
    public var fileExtension: String { rawValue }
}

public enum ExportJobStatus: String, Codable, Hashable, Sendable {
    case pending, running, completed, failed
}

/// The four-part scope picker as data. `nil` list = "all". Raw / derived / suppressed /
/// sensitive are explicitly separable so the export never leaks what the user didn't ask for.
public struct ExportScope: Codable, Hashable, Sendable {
    public var metricIds: [String]?
    public var families: [String]?
    public var startDate: Date?
    public var endDate: Date?
    public var sourceIds: [String]?
    public var includeRaw: Bool
    public var includeDerived: Bool
    public var includeSuppressed: Bool
    public var includeSensitive: Bool
    public var unitProfile: UnitProfileMode
    public var language: AppLanguage

    public init(metricIds: [String]? = nil, families: [String]? = nil, startDate: Date? = nil,
                endDate: Date? = nil, sourceIds: [String]? = nil, includeRaw: Bool = true,
                includeDerived: Bool = true, includeSuppressed: Bool = false, includeSensitive: Bool = false,
                unitProfile: UnitProfileMode = .canonical, language: AppLanguage = .en) {
        self.metricIds = metricIds; self.families = families; self.startDate = startDate
        self.endDate = endDate; self.sourceIds = sourceIds; self.includeRaw = includeRaw
        self.includeDerived = includeDerived; self.includeSuppressed = includeSuppressed
        self.includeSensitive = includeSensitive; self.unitProfile = unitProfile; self.language = language
    }

    public static let everything = ExportScope(includeRaw: true, includeDerived: true,
                                               includeSuppressed: false, includeSensitive: false)
}

/// Published, versioned manifest. Makes truncation and tampering detectable and the export
/// reproducible from its own description (D-8).
public struct ExportManifest: Codable, Hashable, Sendable {
    public var exportId: String
    public var schemaVersion: String
    public var appVersion: String
    public var platform: String
    public var generatedAt: Date
    public var scope: ExportScope
    public var dateRange: String
    public var displayLanguage: String
    public var unitProfile: String
    public var timezonePolicy: String
    public var dedupPolicy: String
    public var perMetricRowCounts: [String: Int]
    public var checksums: [String: String]
    public var dataQualityNote: String
    /// How many rows in THIS export were fabricated by sample mode (`QualityFlag.sampleData`).
    ///
    /// Counted from the exported rows rather than read off a "demo mode" flag, so it stays true
    /// for the mixed case — a user who explored with sample data and then connected Apple Health
    /// has both kinds in one file, and "the app is in demo mode" would answer the wrong question.
    /// Zero on a purely real export. Defaulted in the initializer so older manifests decode.
    public var sampleDataRowCount: Int
    /// True when the files this manifest describes were wrapped into one `ExportEncryptor`
    /// container (always true for an `includeSensitive` export — see ADR-0008) rather than
    /// written as plain CSV/JSON. `checksums` above still describe the real plaintext content
    /// either way; only how it reached disk changes. Defaulted `false` so pre-encryption
    /// manifests decode unchanged.
    public var encrypted: Bool
    /// The container's filename inside the job's `outputPath` folder (always
    /// `ExportEncryptor.containerFileName` today; kept as a manifest field rather than a
    /// hardcoded constant lookup so `ExportCenterViewModel.availableFileURLs` doesn't need to
    /// import `ExportEncryptor` just to know what to look for). `nil` when `encrypted` is false.
    public var encryptedContainerName: String?

    public init(exportId: String, schemaVersion: String, appVersion: String, platform: String,
                generatedAt: Date, scope: ExportScope, dateRange: String, displayLanguage: String,
                unitProfile: String, timezonePolicy: String, dedupPolicy: String,
                perMetricRowCounts: [String: Int], checksums: [String: String], dataQualityNote: String,
                sampleDataRowCount: Int = 0, encrypted: Bool = false, encryptedContainerName: String? = nil) {
        self.exportId = exportId; self.schemaVersion = schemaVersion; self.appVersion = appVersion
        self.platform = platform; self.generatedAt = generatedAt; self.scope = scope
        self.dateRange = dateRange; self.displayLanguage = displayLanguage; self.unitProfile = unitProfile
        self.timezonePolicy = timezonePolicy; self.dedupPolicy = dedupPolicy
        self.perMetricRowCounts = perMetricRowCounts; self.checksums = checksums
        self.dataQualityNote = dataQualityNote; self.sampleDataRowCount = sampleDataRowCount
        self.encrypted = encrypted; self.encryptedContainerName = encryptedContainerName
    }
}

public struct ExportJob: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var scope: ExportScope
    public var format: ExportFormat
    public var status: ExportJobStatus
    public var manifest: ExportManifest?
    public var outputPath: String?
    public var rowCount: Int?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var createdAt: Date

    public init(id: String, scope: ExportScope, format: ExportFormat, status: ExportJobStatus = .pending,
                manifest: ExportManifest? = nil, outputPath: String? = nil, rowCount: Int? = nil,
                startedAt: Date? = nil, finishedAt: Date? = nil, createdAt: Date) {
        self.id = id; self.scope = scope; self.format = format; self.status = status
        self.manifest = manifest; self.outputPath = outputPath; self.rowCount = rowCount
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.createdAt = createdAt
    }
}

// MARK: - EPIC-09: the export template system (plan §9.3–§9.6)
//
// Four entities over migration v4's existing tables. They are modeled together because they only
// make sense together: a `ExportTemplate` says *what* to export, an `ExportDestination` says
// *where* it goes, an `ExportRun` records *that it happened*, and an `ExportCursor` remembers
// *how far* the last run got. Migration v4 already created every table; nothing here adds or
// edits DDL.
//
// Two rules shape most of the design decisions below, and both are load-bearing rather than
// stylistic:
//   1. `ExportRun` must never be able to hold a health value — enforced by types, not by review
//      (see `ExportRowCounts` / `ExportErrorDetail`, which copy `BackgroundWorkCounts`).
//   2. A secret must never reach the database — `ExportDestination` holds a `CredentialRef`,
//      which is a Keychain *key* and is validated to look like one.

/// §9.3 `rangeRule` — how a template turns "now" into a date window at run time.
///
/// Separate from `ExportScope.startDate`/`endDate` because those two are *values* and this is a
/// *rule*: "last 30 days" saved on 1 March has to mean February when it runs in April, which a
/// pair of stored dates cannot express. `.fixed` is the one case that defers to the scope's
/// stored dates — that is what "fixed" means.
///
/// Stored in one TEXT column, so `.lastNDays` carries its N inline (`lastNDays:30`).
public enum ExportRangeRule: Hashable, Sendable {
    /// Use `scope.startDate`/`scope.endDate` verbatim. A window the user pinned deliberately.
    case fixed
    /// A rolling window ending at run time. `days` is clamped to at least 1 on decode — a
    /// zero-day window would produce an empty export that looks like a data-loss bug.
    case lastNDays(Int)
    /// Everything ingested since this (template, destination) pair's `ExportCursor` watermark.
    /// Per §12 EPIC-09's input rules, a runner that finds no cursor falls back to `lastNDays`
    /// *with a notice* rather than silently exporting all of history.
    case sinceLastRun
    case allTime

    public var storageValue: String {
        switch self {
        case .fixed: return "fixed"
        case .lastNDays(let n): return "lastNDays:\(max(1, n))"
        case .sinceLastRun: return "sinceLastRun"
        case .allTime: return "allTime"
        }
    }

    /// Tolerant by design: a row this build cannot parse (a downgrade, a hand-edited database)
    /// reads back as `.allTime` rather than dropping the template, because losing the template
    /// loses the user's saved configuration while an over-wide range only costs them a bigger
    /// file they can see and re-narrow.
    public init(storageValue: String) {
        switch storageValue {
        case "fixed": self = .fixed
        case "sinceLastRun": self = .sinceLastRun
        case "allTime": self = .allTime
        default:
            if storageValue.hasPrefix("lastNDays:"),
               let n = Int(storageValue.dropFirst("lastNDays:".count)) {
                self = .lastNDays(max(1, n))
            } else {
                self = .allTime
            }
        }
    }
}

extension ExportRangeRule: Codable {
    public init(from decoder: Decoder) throws {
        self.init(storageValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(storageValue)
    }
}

/// §9.3's bucketing vocabulary for a template (`hour|day|week|month`).
///
/// Deliberately narrower than EPIC-08's `granularity` CSV column (`raw|second|minute|hour|day|
/// week|month|year`). They answer different questions: the CSV column reports what a *row*
/// actually is — including `second`/`minute` values that come from the source device — while this
/// enum is a *choice the user made* about how to bucket their export, and nobody asks for
/// per-second re-bucketing of data that is already per-second.
public enum ExportBucket: String, Codable, Hashable, Sendable, CaseIterable {
    case hour, day, week, month
}

/// §9.3 aggregation `method`, matching EPIC-08's `aggregation_method` vocabulary minus `none`
/// (which is what `ExportAggregation.raw` means here — see that type).
public enum ExportAggregationMethod: String, Codable, Hashable, Sendable, CaseIterable {
    case sum, mean, min, max, minAvgMax, duration, latest
}

/// §9.3 `aggregation` — an enum rather than a `(granularity, method?)` pair on purpose.
///
/// Migration v4 makes `aggregation_method` nullable "because it is only meaningful when
/// `aggregation` is not `raw`". A struct with an optional method can represent the two states the
/// schema comment calls impossible — raw-with-a-method, and bucketed-without-one — and something
/// downstream then has to decide what those mean. Here the `.raw` case simply has nowhere to put
/// a method and `.bucketed` cannot be built without one, so the schema's nullability rule is a
/// consequence of the type instead of a convention someone has to remember.
public enum ExportAggregation: Hashable, Sendable {
    case raw
    case bucketed(ExportBucket, method: ExportAggregationMethod)

    /// The `aggregation` column.
    public var storageGranularity: String {
        switch self {
        case .raw: return "raw"
        case .bucketed(let bucket, _): return bucket.rawValue
        }
    }

    /// The `aggregation_method` column — `nil` exactly when `.raw`.
    public var storageMethod: String? {
        switch self {
        case .raw: return nil
        case .bucketed(_, let method): return method.rawValue
        }
    }

    /// Reads the two columns back. Anything that does not parse as a complete bucketed
    /// aggregation degrades to `.raw`: raw is the honest fallback because it is the only value
    /// that adds no interpretation of its own to the data.
    public static func from(granularity: String, method: String?) -> ExportAggregation {
        guard let bucket = ExportBucket(rawValue: granularity),
              let method, let parsed = ExportAggregationMethod(rawValue: method) else { return .raw }
        return .bucketed(bucket, method: parsed)
    }
}

extension ExportAggregation: Codable {
    /// One string (`raw`, `day:mean`) so a template survives a round trip through the config
    /// backup (§9.3 "included in full-backup bundle") without needing a nested object.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let parts = raw.split(separator: ":", maxSplits: 1)
        self = Self.from(granularity: String(parts.first ?? ""),
                         method: parts.count > 1 ? String(parts[1]) : nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(storageMethod.map { "\(storageGranularity):\($0)" } ?? storageGranularity)
    }
}

/// §9.3 `layout`. `tidy` is one row per observation (long format, what a script or notebook
/// wants); `wide` pivots metrics into columns (what a spreadsheet user expects).
public enum ExportLayout: String, Codable, Hashable, Sendable, CaseIterable {
    case tidy, wide
}

/// §9.3 — a saved, named, inspectable export configuration.
///
/// The whole point relative to HAE-style presets is that this is *data the user can read back*:
/// every field that shaped an export is stored, so "what exactly did this template send" is
/// answerable from the row rather than from the code that ran.
public struct ExportTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Storage identity, unique among live rows (`idx_export_templates_name`, partial on
    /// `deleted_at IS NULL`). This is not display copy: the seeded presets store stable English
    /// names here, and Quick Export renders its labels from `rangeRule` + `format` through the
    /// existing localized/`ValueFormatter` path so Arabic gets Arabic-Indic digits.
    public var name: String
    /// The existing `ExportScope`, stored as JSON verbatim (v4 comment: so a template keeps
    /// working unchanged when `ExportScope` gains a field).
    public var scope: ExportScope
    public var rangeRule: ExportRangeRule
    /// The existing `ExportFormat` (csv/json). §9.3 also lists `gpx-bundle`; it is deliberately
    /// absent because no writer produces one yet — routes have no export representation until
    /// EPIC-12. Adding the case here before the writer exists would let a user save a template
    /// that silently produces nothing.
    public var format: ExportFormat
    public var aggregation: ExportAggregation
    public var layout: ExportLayout
    public var includeSchemaDocs: Bool
    /// Optional: a template need not pin a destination (the user picks at run time). Note this
    /// is the one place destination is optional — a *run* always resolves to one, which is why
    /// `export_cursors.destination_id` is NOT NULL (see the v4 comment).
    public var destinationId: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, name: String, scope: ExportScope, rangeRule: ExportRangeRule,
                format: ExportFormat, aggregation: ExportAggregation = .raw,
                layout: ExportLayout = .tidy, includeSchemaDocs: Bool = false,
                destinationId: String? = nil, createdAt: Date, updatedAt: Date,
                originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.name = name; self.scope = scope; self.rangeRule = rangeRule
        self.format = format; self.aggregation = aggregation; self.layout = layout
        self.includeSchemaDocs = includeSchemaDocs; self.destinationId = destinationId
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }

    /// True for the seeded Quick Export presets, which are read-only (§12 EPIC-10: "Presets are
    /// seeded read-only templates"). Derived from the id rather than stored in a column because
    /// v4 has no `is_preset` column and this file must not add one — and because a derived answer
    /// cannot be flipped by a hand-edited row into "this preset is editable now".
    public var isPreset: Bool { QuickExportPreset.presetIds.contains(id) }
}

// MARK: - Run-time sensitive re-confirmation (§9.3 privacy note)

/// The user's confirmation, given **at run time**, that this run may include the sensitive
/// namespace (meds/symptoms — I7).
///
/// §9.3 requires this as defense in depth: saving a template that names a sensitive scope is not
/// standing permission to keep exporting it, and a template that will one day run from a schedule
/// or a Shortcut must not be able to carry that permission with it. It mirrors `ExportRunner`'s
/// existing passphrase requirement, which stays in force independently — a sensitive export needs
/// both this and a passphrase.
///
/// Deliberately **not** `Codable` and with no repository: there is nowhere to persist it, so
/// "remember my answer" cannot be implemented by accident. It also carries the template id it was
/// given for, so a confirmation the user gave for their weekly-vitals template cannot be reused to
/// authorize a different one.
public struct SensitiveRunConsent: Hashable, Sendable {
    public let templateId: String
    public let confirmedAt: Date

    public init(templateId: String, confirmedAt: Date) {
        self.templateId = templateId
        self.confirmedAt = confirmedAt
    }

    /// How long a confirmation stays usable. Five minutes is long enough to cover a passphrase
    /// entry and a share-sheet round trip, and short enough that a confirmation left on screen
    /// overnight does not authorize a morning's export.
    public static let validityWindow: TimeInterval = 300
}

/// Why a template refused to produce a runnable scope. `Error` so the refusal cannot be ignored
/// by a caller that just wanted a scope.
public enum ExportTemplateRunRefusal: Error, Equatable, Sendable {
    case sensitiveConfirmationRequired(templateId: String)
    case sensitiveConfirmationForDifferentTemplate(expected: String, received: String)
    case sensitiveConfirmationExpired(templateId: String)
}

extension ExportTemplate {
    /// Whether running this template needs a fresh `SensitiveRunConsent`.
    public var requiresSensitiveConfirmation: Bool { scope.includeSensitive }

    /// The scope to hand `ExportRunner`, resolved for one run.
    ///
    /// This is the only way to get a sensitive scope out of a template, which is what makes the
    /// §9.3 rule enforceable rather than advisory: a runner that reads `template.scope` directly
    /// is visibly bypassing a documented gate, and one that calls this cannot forget the check.
    ///
    /// Note what it deliberately does *not* do: a missing confirmation is a thrown refusal, never
    /// a silent downgrade to `includeSensitive = false`. A quietly narrowed export would hand the
    /// user a file missing the records they asked for, with nothing in it saying so.
    public func scopeForRun(consent: SensitiveRunConsent?, now: Date) throws -> ExportScope {
        guard requiresSensitiveConfirmation else { return scope }
        guard let consent else { throw ExportTemplateRunRefusal.sensitiveConfirmationRequired(templateId: id) }
        guard consent.templateId == id else {
            throw ExportTemplateRunRefusal.sensitiveConfirmationForDifferentTemplate(
                expected: id, received: consent.templateId)
        }
        // Also refuses a confirmation timestamped in the future: a clock change is not a reason
        // to widen a privacy gate.
        let age = now.timeIntervalSince(consent.confirmedAt)
        guard age >= 0, age <= SensitiveRunConsent.validityWindow else {
            throw ExportTemplateRunRefusal.sensitiveConfirmationExpired(templateId: id)
        }
        return scope
    }
}

// MARK: - Quick Export presets (§12 EPIC-10)

/// The seeded, read-only Quick Export presets: Last 7 / Last 30 / All time × CSV / JSON.
///
/// **This type is the structural exclusion of sensitive data and routes from Quick Export.** §12
/// EPIC-10 requires the exclusion to be structural rather than a default value someone can flip:
/// a preset is described entirely by a range and a format, there is no initializer, parameter or
/// field through which a caller could hand one a widened scope, and `presetScope` — the only
/// place a preset's `ExportScope` is built — is private and hardcodes the narrow one. Adding a
/// sensitive or route knob to a preset therefore means editing this type, which is exactly the
/// review someone should have to face.
///
/// `ExportTemplateSystemTests.testPresetScopesGrantNoWideningPermission` reflects over the built
/// scope and fails on *any* `include*` permission that is true outside the raw/derived allowlist,
/// so a future `includeRoutes` added to `ExportScope` is covered the day it lands rather than the
/// day someone remembers to update this comment.
public enum QuickExportPreset: Hashable, Sendable, CaseIterable {
    case last7CSV, last7JSON, last30CSV, last30JSON, allTimeCSV, allTimeJSON

    /// Fixed ids so seeding is idempotent (`INSERT OR IGNORE` by primary key) across every
    /// launch, reinstall-over-restore and future re-seed.
    ///
    /// They are real 26-character Crockford-base32 ULIDs (I8) with a zeroed timestamp half —
    /// presets are not events and have no meaningful creation instant to embed. The readable
    /// half spells the preset because a diagnostics dump full of anonymous ULIDs is unreadable.
    /// `MAX` means all-time: Crockford base32 excludes I, L, O and U, so `ALL` and `ALLTIME`
    /// cannot be spelled in a valid ULID at all.
    public var id: String {
        switch self {
        case .last7CSV: return "0000000000PRESET7CSV000000"
        case .last7JSON: return "0000000000PRESET7JSN000000"
        case .last30CSV: return "0000000000PRESET30CSV00000"
        case .last30JSON: return "0000000000PRESET30JSN00000"
        case .allTimeCSV: return "0000000000PRESETMAXCSV0000"
        case .allTimeJSON: return "0000000000PRESETMAXJSN0000"
        }
    }

    public static let presetIds: Set<String> = Set(allCases.map(\.id))

    public var format: ExportFormat {
        switch self {
        case .last7CSV, .last30CSV, .allTimeCSV: return .csv
        case .last7JSON, .last30JSON, .allTimeJSON: return .json
        }
    }

    public var rangeRule: ExportRangeRule {
        switch self {
        case .last7CSV, .last7JSON: return .lastNDays(7)
        case .last30CSV, .last30JSON: return .lastNDays(30)
        case .allTimeCSV, .allTimeJSON: return .allTime
        }
    }

    /// Storage identity only — see `ExportTemplate.name`. ASCII and stable: renaming one of these
    /// would orphan the row under the unique-name index and reseed a duplicate under the new name.
    public var storageName: String {
        let range: String
        switch rangeRule {
        case .lastNDays(let n): range = "Last \(n) days"
        case .allTime: range = "All time"
        case .fixed, .sinceLastRun: range = "Quick"
        }
        return "Quick Export — \(range) (\(format.rawValue.uppercased()))"
    }

    /// The one place a preset's scope is built. Private, parameterless, and narrow:
    ///  - `includeSensitive: false` — meds/symptoms need the explicit builder path and a
    ///    passphrase (I7, ADR-0008), never a two-tap preset.
    ///  - `includeSuppressed: false` — dedup losers are inspectable in the advanced builder;
    ///    a casual "give me my data" export should not silently double-count a walk.
    ///  - raw + derived are both on, because raw data is never paywalled or withheld and the
    ///    derived values are what make the file legible.
    /// Routes: no route data has an export representation yet (EPIC-12 owns the GPX writer), and
    /// when it lands this factory still has no parameter through which a preset could opt in.
    private static func presetScope() -> ExportScope {
        ExportScope(includeRaw: true, includeDerived: true,
                    includeSuppressed: false, includeSensitive: false)
    }

    /// Build the seedable row. `createdAt`/`updatedAt`/`originDeviceId` come from the caller so
    /// seeding stays testable against a fixed clock.
    public func template(now: Date, originDeviceId: String) -> ExportTemplate {
        ExportTemplate(id: id, name: storageName, scope: Self.presetScope(), rangeRule: rangeRule,
                       format: format,
                       // Raw, tidy, no schema docs: Quick Export's promise is "your data, now",
                       // and every one of those choices is the one that adds nothing between the
                       // stored rows and the file.
                       aggregation: .raw, layout: .tidy, includeSchemaDocs: false,
                       destinationId: ExportDestination.shareSheetId,
                       createdAt: now, updatedAt: now, originDeviceId: originDeviceId)
    }
}

// MARK: - §9.4 ExportDestination

/// §9.4 `kind`. `mqtt` is **reserved vocabulary only**: nothing constructs it, no delivery path
/// exists, and it is present so that a future row written by a later build parses here instead of
/// collapsing to a wrong kind.
public enum ExportDestinationKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// The system share sheet — the destination for every Quick Export. Not "no destination":
    /// it is a real destination row, which is what lets `export_cursors.destination_id` be
    /// NOT NULL (see the v4 comment for why a nullable one corrupts `sinceLastRun`).
    case shareSheet
    /// A user-picked folder (security-scoped bookmark on iOS, tree URI on Android).
    case fileFolder
    /// Phase 3. Note the module lint: export *generation* makes no network calls, so a REST
    /// destination is a delivery step outside the Export module, not a writer that posts.
    case restApi
    case cloudDrive
    /// Reserved. See the type doc.
    case mqtt

    /// Whether delivering here leaves the device. Drives which destinations need a TLS policy,
    /// a credential, and a reachability status at all.
    public var leavesDevice: Bool {
        switch self {
        case .shareSheet, .fileFolder: return false
        case .restApi, .cloudDrive, .mqtt: return true
        }
    }
}

/// §9.4 `tlsPolicy`. `notApplicable` exists so an on-device destination does not have to claim a
/// transport policy it never exercises — a `fileFolder` row asserting `httpsOnly` is a small lie
/// that would eventually be read as evidence that folder writes go over TLS.
public enum ExportTlsPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    case httpsOnly
    case notApplicable
}

/// §9.4 `status`.
public enum ExportDestinationStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case ok
    /// The stored credential no longer authenticates. Distinct from `unreachable` because the
    /// user action differs: reauthorize versus check the network/URL.
    case authExpired
    case unreachable
    /// Turned off by the user. Never set automatically — a destination BADAN disabled on the
    /// user's behalf would silently stop their exports.
    case disabled
}

/// A **reference** to a secret in the Keychain (iOS) / Keystore-backed storage (Android) —
/// never the secret.
///
/// §9.4 says credentials live in the Keychain and the database holds references. That is easy to
/// state and easy to violate: `credentialRef: String` accepts a bearer token just as happily as a
/// key name. So this type validates that its value *looks like a key BADAN minted* — the fixed
/// `badan.export.credential.` namespace, lowercase, no whitespace, at most 64 characters.
///
/// The point is not that the check is cryptographically meaningful; it is that pasting a real
/// secret in fails. JWTs and OAuth tokens are longer than 64 characters, contain uppercase, and do
/// not start with BADAN's namespace, so `CredentialRef(key:)` returns nil for all three reasons at
/// once — and the only way to get a secret into this column is to first defeat this initializer,
/// which is a change a reviewer sees.
public struct CredentialRef: Hashable, Sendable {
    public let key: String

    public static let namespace = "badan.export.credential."
    public static let maxLength = 64

    public init?(key: String) {
        guard key.hasPrefix(Self.namespace), key.count <= Self.maxLength else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard key.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        // A bare namespace is a reference to nothing.
        guard key.count > Self.namespace.count else { return nil }
        self.key = key
    }

    /// Mint a reference for a destination. The destination id is a ULID, which is uppercase
    /// Crockford base32 — lowercased here to satisfy the character rule above, and unambiguous
    /// either way since ULIDs are case-insensitive by construction.
    public static func forDestination(id: String) -> CredentialRef? {
        CredentialRef(key: namespace + id.lowercased())
    }
}

/// §9.4 `config` — the **non-secret** half of a destination, as typed fields.
///
/// Every field here is a reference or a routing detail, and that is the design. A
/// `[String: String]` bag would have made this column the path of least resistance for an
/// `Authorization` header value; instead the only header representation available is
/// `headerTemplateIds`, which names header *templates* held elsewhere. There is no field on this
/// struct that a token, password, cookie or signed URL fits into without renaming something.
public struct ExportDestinationConfig: Codable, Hashable, Sendable {
    /// `fileFolder`: the Keychain/preferences key under which the security-scoped bookmark bytes
    /// (iOS) or persisted tree URI (Android) are held. Not the bookmark itself — bookmark data
    /// grants standing filesystem access and belongs with the other protected material.
    public var folderBookmarkRef: String?
    /// `restApi` (Phase 3): the endpoint. Carries no query string by contract — parameters that
    /// vary per run belong to the delivery call, and a stored URL with a token in its query is
    /// exactly the leak `credentialRef` exists to prevent.
    public var endpointURL: String?
    public var httpMethod: String?
    /// Ids of header templates, never header values.
    public var headerTemplateIds: [String]
    /// `cloudDrive`: which provider (`dropbox`, `gdrive` per §9.4) and the reference to the
    /// account handle held in protected storage.
    public var providerId: String?
    public var providerAccountRef: String?

    public init(folderBookmarkRef: String? = nil, endpointURL: String? = nil,
                httpMethod: String? = nil, headerTemplateIds: [String] = [],
                providerId: String? = nil, providerAccountRef: String? = nil) {
        self.folderBookmarkRef = folderBookmarkRef; self.endpointURL = endpointURL
        self.httpMethod = httpMethod; self.headerTemplateIds = headerTemplateIds
        self.providerId = providerId; self.providerAccountRef = providerAccountRef
    }
}

/// §9.4 — where artifacts go.
public struct ExportDestination: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ExportDestinationKind
    public var displayName: String
    public var config: ExportDestinationConfig
    /// Keychain/Keystore key. See `CredentialRef` for why this is not a `String`.
    public var credentialRef: CredentialRef?
    public var tlsPolicy: ExportTlsPolicy
    public var createdAt: Date
    public var lastVerifiedAt: Date?
    public var status: ExportDestinationStatus
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String, kind: ExportDestinationKind, displayName: String,
                config: ExportDestinationConfig = ExportDestinationConfig(),
                credentialRef: CredentialRef? = nil, tlsPolicy: ExportTlsPolicy? = nil,
                createdAt: Date, lastVerifiedAt: Date? = nil,
                status: ExportDestinationStatus = .ok, updatedAt: Date,
                originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.displayName = displayName; self.config = config
        self.credentialRef = credentialRef
        // Defaulted from the kind rather than to a constant: §9.4 makes `httpsOnly` the default,
        // but only network destinations have a transport at all (see `ExportTlsPolicy`).
        self.tlsPolicy = tlsPolicy ?? (kind.leavesDevice ? .httpsOnly : .notApplicable)
        self.createdAt = createdAt; self.lastVerifiedAt = lastVerifiedAt; self.status = status
        self.updatedAt = updatedAt; self.originDeviceId = originDeviceId; self.deletedAt = deletedAt
    }

    /// The share-sheet destination every Quick Export resolves to. Fixed id for the same reason
    /// the presets have fixed ids — seeding must be idempotent, and a cursor keyed on a
    /// regenerated destination id would restart from zero on every reinstall.
    public static let shareSheetId = "0000000000DESTSHARESHEET00"

    public static func shareSheet(now: Date, originDeviceId: String) -> ExportDestination {
        ExportDestination(id: shareSheetId, kind: .shareSheet,
                          // Storage identity, not display copy — the Export Center labels the
                          // share sheet with its own localized string.
                          displayName: "Share sheet",
                          createdAt: now, updatedAt: now, originDeviceId: originDeviceId)
    }
}

extension CredentialRef: Codable {
    /// Validating decode: a stored value that no longer satisfies the rules above cannot be
    /// resurrected into a `CredentialRef`, so a hand-edited row containing a pasted token is
    /// rejected on read as well as on write.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let ref = CredentialRef(key: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a BADAN credential reference")
        }
        self = ref
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

// MARK: - §9.5 ExportRun — the trust ledger

/// §9.5 `trigger` — what caused this run. Stored rather than inferred, because "did my automation
/// actually fire, or was that me tapping export?" is the first question the Export Health
/// dashboard has to answer.
public enum ExportTrigger: String, Codable, Hashable, Sendable, CaseIterable {
    case manual
    /// An App Intent / Shortcut ran it (device unlocked — §4.10's honest tier labeling).
    case shortcut
    /// A best-effort background wake took the opportunity.
    case scheduledOpportunistic
    /// Android WorkManager's periodic worker.
    case scheduledWork
    /// An automatic retry of a previously failed run.
    case retry
}

/// §9.5 `outcome`. Every case is **terminal** — there is no `running`, which is why a run row is
/// appended once, when it ends (see `ExportRunRepository`).
public enum ExportOutcome: String, Codable, Hashable, Sendable, CaseIterable {
    case success
    /// Some artifacts were produced, some were not. Recorded as its own outcome rather than as
    /// success-with-a-note because a partial export is a file the user may act on believing it is
    /// complete.
    case partial
    case failedGeneration
    /// Generated fine, never arrived. The distinction matters for retry: the artifact may already
    /// exist on disk, so the retry is a delivery, not a regeneration.
    case failedDelivery
    /// The sensitive store was unreadable (device locked). Not a failure — the same reasoning as
    /// `BackgroundRunOutcome.storeLocked`: iOS Data Protection working as designed.
    case skippedLocked
    /// Nothing new in range. A successful answer to "is there anything to export", not an error —
    /// and recorded rather than skipped silently, so an automation that legitimately has nothing
    /// to do is distinguishable from one that never ran.
    case skippedNoData
    case throttled
    case cancelled

    /// The single predicate any UI consults before styling a run as a problem. Deliberately
    /// narrow: locked, no-data, throttled and cancelled are all ordinary.
    public var isFailure: Bool {
        self == .failedGeneration || self == .failedDelivery || self == .partial
    }
}

/// §9.5 `errorCode` — a closed vocabulary, so Export Health can decide whether a run is retryable
/// without parsing text.
public enum ExportErrorCode: String, Codable, Hashable, Sendable, CaseIterable {
    case storageFull
    case storageUnavailable
    case permissionDenied
    /// The §9.3 run-time confirmation was missing or stale — see `ExportTemplateRunRefusal`.
    case sensitiveConfirmationMissing
    /// `ExportRunner`'s existing passphrase requirement for an `includeSensitive` export.
    case passphraseMissing
    case encryptionFailed
    case writeFailed
    case destinationUnreachable
    case destinationAuthExpired
    case destinationDisabled
    /// `sinceLastRun` with no cursor row (§12 EPIC-09's input rule).
    case cursorMissing
    case templateMissing
    case cancelledByUser
    case unknown
}

/// Which phase of a run the failure happened in.
public enum ExportStage: String, Codable, Hashable, Sendable, CaseIterable {
    case gathering, writing, checksumming, encrypting, delivering, finalizing
}

/// §9.5 `errorDetail` — "sanitized, value-free", and structurally so.
///
/// Deliberately **not** a `String`. The obvious implementation of a detail field is the thrown
/// error's message, and a SQLite or HealthKit error message can quote row content — which is how
/// a health value ends up in a ledger the user is invited to share from the Export Health
/// dashboard. This struct is the same defense `BackgroundWorkCounts` uses for `background_runs`:
/// every field is an `Int` or a closed enum, so there is nowhere for a message, a metric name or
/// a reading to go, and that stays true without anyone remembering the rule at each call site.
///
/// `ExportTemplateSystemTests.testExportRunLedgerCarriesNoHealthValues` asserts the encoded form
/// contains only integers and known enum tokens.
public struct ExportErrorDetail: Codable, Hashable, Sendable {
    public var stage: ExportStage
    public var filesWritten: Int
    public var filesExpected: Int
    /// Which attempt this was (0 = first). Lets a retry storm be seen as one.
    public var attempt: Int
    /// EPIC-20 — the HTTP status a networked destination was last answered with, and the *only*
    /// half of §22.7's "status code + sanitized reason" that was not already representable here.
    /// The reason is `ExportRun.errorCode`, a closed vocabulary; this is the code, an integer.
    ///
    /// An `Int?` and not the response body, deliberately: a server's error text can echo back the
    /// bytes BADAN just posted, so a body in this column would put health values into the one
    /// record Export Health invites the user to share. Nil for every non-network destination, and
    /// nil when the endpoint never answered at all (a timeout has no status — that case is carried
    /// by `errorCode == .destinationUnreachable`).
    ///
    /// Additive and migration-free: `error_detail` is a JSON TEXT column, and an older row that
    /// predates this field decodes with it nil.
    public var httpStatus: Int?

    public init(stage: ExportStage, filesWritten: Int = 0, filesExpected: Int = 0, attempt: Int = 0,
                httpStatus: Int? = nil) {
        self.stage = stage; self.filesWritten = filesWritten
        self.filesExpected = filesExpected; self.attempt = attempt
        self.httpStatus = httpStatus
    }
}

/// §9.5 `rowCounts` — how much left, by record class.
///
/// **By class, not by metric.** `ExportManifest.perMetricRowCounts` keys on metric ids because a
/// manifest describes one file the user already has; this table is a durable log that Export
/// Health displays and a full backup carries, and a per-metric map there would be a standing
/// record of *which metrics this person tracks* — the same disclosure Android's
/// `BackgroundWorkDone` doc refuses for `unmappedMetricIds`. Six integers answer "did my export
/// get everything" without ever naming a metric.
public struct ExportRowCounts: Codable, Hashable, Sendable {
    public var measurements: Int
    public var intervals: Int
    public var sessions: Int
    public var logs: Int
    public var derived: Int
    /// Dedup losers included because the scope asked for them (I3/I5 — raw and derived stay
    /// separable, and suppressed rows are never silently dropped).
    public var suppressed: Int

    public init(measurements: Int = 0, intervals: Int = 0, sessions: Int = 0,
                logs: Int = 0, derived: Int = 0, suppressed: Int = 0) {
        self.measurements = measurements; self.intervals = intervals; self.sessions = sessions
        self.logs = logs; self.derived = derived; self.suppressed = suppressed
    }

    public var total: Int { measurements + intervals + sessions + logs + derived + suppressed }
    public var isEmpty: Bool { total == 0 }
}

/// A validated SHA-256 digest.
///
/// `manifestSha256` is the last field on `ExportRun` that could plausibly have been a free
/// `String`, so it is the last hole through which arbitrary text could reach the ledger. 64
/// lowercase hex characters or nothing.
public struct ManifestDigest: Hashable, Sendable {
    public let hex: String

    public init?(hex: String) {
        let lowered = hex.lowercased()
        guard lowered.count == 64,
              lowered.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.hex = lowered
    }
}

extension ManifestDigest: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let digest = ManifestDigest(hex: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "not a sha-256 digest")
        }
        self = digest
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

/// §9.5 — one row per **attempted** export, successful or not. The trust ledger, and the whole
/// anti-HAE thesis in one table: an export that fails leaves evidence that it failed.
///
/// **This type must never be able to hold a health value.** Every field is an id, an instant, a
/// closed enum, or an integer count — there is no free-text field at all (see `ExportErrorDetail`,
/// `ExportRowCounts`, `ManifestDigest`). That is not a convention; it is the reason those three
/// types exist, and it is what makes the Export Health dashboard safe to screenshot.
public struct ExportRun: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// `nil` for an ad-hoc export from the builder — those have no template.
    public var templateId: String?
    /// The `export_jobs` row that produced the artifacts. `nil` when the run never got as far as
    /// creating a job (a refusal at the gate: no confirmation, no cursor, destination disabled).
    public var jobId: String?
    public var trigger: ExportTrigger
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: ExportOutcome
    public var errorCode: ExportErrorCode?
    public var errorDetail: ExportErrorDetail?
    public var bytesWritten: Int?
    public var rowCounts: ExportRowCounts?
    public var destinationId: String?
    /// When delivery completed, which is not when generation completed. The gap between
    /// `finishedAt` and this is precisely the "it said it exported but nothing arrived" case.
    public var deliveredAt: Date?
    /// Cursor watermarks either side of a delta run (both `ingested_at` instants — see
    /// `ExportCursor`). Recorded so a wrong-looking delta export can be reconstructed after the
    /// fact instead of guessed at.
    public var cursorBefore: Date?
    public var cursorAfter: Date?
    public var manifestSha256: ManifestDigest?

    public init(id: String, templateId: String? = nil, jobId: String? = nil,
                trigger: ExportTrigger, startedAt: Date, finishedAt: Date? = nil,
                outcome: ExportOutcome, errorCode: ExportErrorCode? = nil,
                errorDetail: ExportErrorDetail? = nil, bytesWritten: Int? = nil,
                rowCounts: ExportRowCounts? = nil, destinationId: String? = nil,
                deliveredAt: Date? = nil, cursorBefore: Date? = nil, cursorAfter: Date? = nil,
                manifestSha256: ManifestDigest? = nil) {
        self.id = id; self.templateId = templateId; self.jobId = jobId; self.trigger = trigger
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.outcome = outcome
        self.errorCode = errorCode; self.errorDetail = errorDetail; self.bytesWritten = bytesWritten
        self.rowCounts = rowCounts; self.destinationId = destinationId; self.deliveredAt = deliveredAt
        self.cursorBefore = cursorBefore; self.cursorAfter = cursorAfter
        self.manifestSha256 = manifestSha256
    }
}

// MARK: - §9.6 ExportCursor

/// §9.6 — the incremental-export checkpoint for one (template, destination) pair.
///
/// **`highWatermark` is a max `ingested_at`, never a max `measured_at`.** This is the field most
/// likely to be "corrected" by a future reader, so: a watch that syncs Saturday's workout on
/// Monday writes a row whose `measured_at` (Saturday) is already behind a Sunday watermark, and a
/// `measured_at` cursor would skip it forever — the export silently loses every late-arriving and
/// backfilled row, and the loss is invisible because the file looks complete. Only `ingested_at`,
/// stamped when BADAN wrote the row, is monotonic with respect to what this device has actually
/// had available to export.
public struct ExportCursor: Codable, Hashable, Sendable {
    public var templateId: String
    /// NOT optional, matching the NOT NULL column: `shareSheet` is a destination, not the absence
    /// of one. The v4 comment explains what a nullable one does to `sinceLastRun`.
    public var destinationId: String
    public var highWatermark: Date
    /// The SHA-256 of the bundle FILE the last successful delta delivered — the chain link the next
    /// run carries forward as its `previous_manifest_sha` (§22.6). Bundle-file sha, not the sha of
    /// the `ExportManifest` struct: it is the value a consumer recomputes from the delivered file,
    /// so `scripts/verify_export_chain.py` can walk the chain from the artifacts alone.
    public var lastManifestSha: ManifestDigest?
    public var lastRunId: String?
    public var updatedAt: Date

    public init(templateId: String, destinationId: String, highWatermark: Date,
                lastManifestSha: ManifestDigest? = nil, lastRunId: String? = nil, updatedAt: Date) {
        self.templateId = templateId; self.destinationId = destinationId
        self.highWatermark = highWatermark; self.lastManifestSha = lastManifestSha
        self.lastRunId = lastRunId; self.updatedAt = updatedAt
    }
}

// MARK: - §22.6 delta-export reconciliation records

/// One tombstoned row a delta export reports in its `deletions[]` section (§22.6) so a downstream
/// store can reconcile a removal it would otherwise never learn about — a delta that only ever
/// *adds* rows can never tell a consumer a record went away.
///
/// `entity` is the bundle array the record lived in (`raw_sample` | `interval_record` | `session`),
/// matching the `deletions[]` `entity` vocabulary `JSONBundleWriter` already emits.
public struct ExportTombstone: Hashable, Sendable {
    public var recordId: String
    public var entity: String
    public var deletedAt: Date
    public var tzId: String

    public init(recordId: String, entity: String, deletedAt: Date, tzId: String) {
        self.recordId = recordId; self.entity = entity
        self.deletedAt = deletedAt; self.tzId = tzId
    }

    /// The canonical emission order for a delta's tombstone set, shared by every format so the JSON
    /// `deletions[]` array and the CSV `deletions.csv` rows list the same removals in the same
    /// sequence. `record_id` alone is a TOTAL order: ids are ULIDs unique across every table (I8),
    /// so no two tombstones can tie and neither platform's sort has a tie to break differently.
    public static func exportSorted(_ tombstones: [ExportTombstone]) -> [ExportTombstone] {
        tombstones.sorted { $0.recordId < $1.recordId }
    }
}

/// One suppression-flip correction a delta export reports in its `corrections[]` section (§22.6).
///
/// The subtle desync EPIC-17 exists to close: a delta that only adds rows silently corrupts a
/// downstream store when a dedup decision *reverses* since the last cursor — the row it already has
/// as authoritative is now suppressed (or a suppressed one now wins) and nothing in an add-only
/// delta says so. `suppressedBy` is the winning record id when this record is now suppressed, or
/// `nil` when the flip *cleared* a prior suppression (this record wins again).
public struct ExportSuppressionCorrection: Hashable, Sendable {
    public var recordId: String
    public var suppressedBy: String?
    public var changedAt: Date

    public init(recordId: String, suppressedBy: String?, changedAt: Date) {
        self.recordId = recordId; self.suppressedBy = suppressedBy; self.changedAt = changedAt
    }

    /// The canonical emission order for a delta's correction set, shared by every format so the JSON
    /// `corrections[]` array and the CSV `corrections.csv` rows apply in the same sequence.
    ///
    /// `record_id`, then `changed_at`, then `suppressed_by` — a TOTAL order, not `record_id` alone.
    /// One record CAN flip more than once inside a single delta window (suppressed by A, then by B
    /// after a source-priority change), so `record_id` alone leaves ties, and `Array.sorted(by:)` is
    /// documented as not guaranteed stable while Kotlin's `sortedWith` is: a tie would be free to
    /// resolve differently on the two platforms, quietly ending the byte-identical guarantee the
    /// export goldens assert. The `changed_at` tiebreaker also puts a record's flips in the order
    /// they happened, so a consumer applying them in order lands on that record's current state
    /// rather than on an intermediate one. A `nil` `suppressedBy` sorts as the empty string, which
    /// orders a clearing before a re-suppression at the same instant; that is a tiebreaker of last
    /// resort, never a rendered value (it renders as JSON `null` / an empty CSV cell).
    public static func exportSorted(_ corrections: [ExportSuppressionCorrection]) -> [ExportSuppressionCorrection] {
        corrections.sorted {
            ($0.recordId, $0.changedAt, $0.suppressedBy ?? "")
                < ($1.recordId, $1.changedAt, $1.suppressedBy ?? "")
        }
    }
}
