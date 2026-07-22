import Foundation

// MARK: - Lab notebook document vault: entity (EPIC-41, Phase 3E MVP, LAB-02)
//
// "A notebook, not a chart": original artifacts are always preserved. This type is the metadata
// row for exactly one imported PDF or photographed lab report — the vault's own encrypted bytes
// live on disk (`DocumentVault`), never here, and never as a database BLOB.
//
// OWNERSHIP NOTE (read before extending this file): `SourceDocument` is this slice's (the Ingest
// lane's) entity. `LabModels.swift` (a PARALLEL Domain/Labs lane) declares `LabReport`/`LabResult`/
// `ReferenceRange`/`AnalyteDefinition`/`UserCorrection`/`DerivedTrend` and reuses `LabSensitivityTier`
// (declared there) below — this file does not redeclare that enum, both to avoid a second
// definition of the same vocabulary and because `LabReport`/`LabResult` already carry it, so a
// SourceDocument sharing the identical three-tier scale is the same fact, not a coincidence.
// `LabReport.documentRef` is an opaque `String?` into the `id` this file defines — that lane's own
// header comment says as much; this file does not depend on `LabReport`'s shape in return.

/// On-device OCR status for a vaulted document (LAB-02/LAB-06). `.pending` is the state a
/// freshly-vaulted document starts in: LAB-06 requires that a document is stored and browsable
/// the moment it is vaulted, whether or not OCR has run yet, so `.pending` must be a normal,
/// first-class, immediately-reachable state — never a placeholder nobody is meant to observe.
/// `.failed` is equally first-class for the same reason: "document stores even when extraction
/// fails" (LAB-06's own requirement) means a totally-failed OCR run must still leave a fully
/// usable, browsable `SourceDocument` behind, not an error the user can't get past.
public enum SourceDocumentOCRStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

/// The lab-notebook document vault entity (LAB-02): metadata for one imported PDF or photographed
/// lab report.
///
/// Deliberately holds NO document bytes. `vaultFileRef` names a file inside `DocumentVault`'s own
/// encrypted on-disk store — never a BLOB column — so a multi-megabyte scan never bloats
/// `badan_sensitive.db`: every other sensitive row this database holds is a handful of columns,
/// and a lab-report PDF/photo is orders of magnitude larger. Mixing the two into one file would
/// make routine sensitive-DB operations (checkpoint, vacuum, the whole-file purge `I7` relies on)
/// pay a multi-megabyte tax for every scanned report a user ever adds.
///
/// `sha256` is computed over the document's ORIGINAL, pre-encryption bytes (`DocumentVault.store`),
/// so the hash keeps proving what the source document actually contained no matter how the on-disk
/// storage layer evolves (today: the BDNX/AES-256-GCM container `DocumentVault` reuses from
/// `ExportEncryptor`) — this is LAB-02's own "hash+metadata" requirement, and also the identity a
/// duplicate-import check (`SourceDocumentRepository.document(sha256:)`) is built on: "same PDF
/// imported twice" is answered by the hash of what the file actually contains, not by filename or
/// size, both of which a re-export/re-scan of the identical report can trivially change.
///
/// Lives in `badan_sensitive.db` (I7) unconditionally: a lab report can carry a patient name, date
/// of birth, diagnoses, or a clinician's letterhead, so every `SourceDocument` is sensitive-plus by
/// construction — never conditionally, never based on what OCR later finds inside it.
public struct SourceDocument: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// SHA-256 (lowercase hex) of the original, pre-encryption bytes.
    public var sha256: String
    public var mimeType: String
    /// As the user's share sheet/file picker reported it, when available. Never used as an
    /// identity key (see `sha256`) — purely a display convenience, and honestly absent when the
    /// import path (e.g. a camera capture) never had a filename to begin with.
    public var originalFileName: String?
    public var pageCount: Int
    public var ocrStatus: SourceDocumentOCRStatus
    /// Filename inside `DocumentVault`'s own directory — resolved exclusively by
    /// `DocumentVault.retrieve(vaultFileRef:)`. Nothing outside `DocumentVault` ever opens this
    /// path directly; the indirection is what lets the vault's own on-disk layout change without
    /// this row (or anything that reads it) needing to change too.
    public var vaultFileRef: String
    /// Shared with `LabReport`/`LabResult` (`LabModels.swift`). Defaults stricter than
    /// `LabReport`'s own default (`.standard`) — deliberately: a raw scanned artifact typically
    /// shows a full name, date of birth, and a clinician's letterhead even for an otherwise routine
    /// panel, which is more consistently identifying than the structured fields BADAN extracts
    /// from it.
    public var sensitivityTier: LabSensitivityTier
    public var importedAt: Date
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(
        id: String,
        sha256: String,
        mimeType: String,
        originalFileName: String? = nil,
        pageCount: Int,
        ocrStatus: SourceDocumentOCRStatus = .pending,
        vaultFileRef: String,
        sensitivityTier: LabSensitivityTier = .high,
        importedAt: Date,
        updatedAt: Date,
        originDeviceId: String,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.sha256 = sha256
        self.mimeType = mimeType
        self.originalFileName = originalFileName
        self.pageCount = pageCount
        self.ocrStatus = ocrStatus
        self.vaultFileRef = vaultFileRef
        self.sensitivityTier = sensitivityTier
        self.importedAt = importedAt
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }
}
