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

    public init(exportId: String, schemaVersion: String, appVersion: String, platform: String,
                generatedAt: Date, scope: ExportScope, dateRange: String, displayLanguage: String,
                unitProfile: String, timezonePolicy: String, dedupPolicy: String,
                perMetricRowCounts: [String: Int], checksums: [String: String], dataQualityNote: String,
                sampleDataRowCount: Int = 0) {
        self.exportId = exportId; self.schemaVersion = schemaVersion; self.appVersion = appVersion
        self.platform = platform; self.generatedAt = generatedAt; self.scope = scope
        self.dateRange = dateRange; self.displayLanguage = displayLanguage; self.unitProfile = unitProfile
        self.timezonePolicy = timezonePolicy; self.dedupPolicy = dedupPolicy
        self.perMetricRowCounts = perMetricRowCounts; self.checksums = checksums
        self.dataQualityNote = dataQualityNote; self.sampleDataRowCount = sampleDataRowCount
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
