import SwiftUI

/// The power-mode lineage line for a datum: an ingestion-path icon, the source name, the
/// human ingestion-path label and when it arrived. Makes "where did this number come from"
/// a visible row rather than a promise.
struct ProvenanceRow: View {
    var sourceName: String
    var ingestionPath: IngestionPath
    var timestamp: Date
    var language: AppLanguage

    init(sourceName: String, ingestionPath: IngestionPath, timestamp: Date, language: AppLanguage) {
        self.sourceName = sourceName
        self.ingestionPath = ingestionPath
        self.timestamp = timestamp
        self.language = language
    }

    var body: some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: iconName)
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(sourceName)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textPrimary)
            Text(ingestionPath.displayLabel.resolved(language))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Text(timestampText)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
        }
    }

    private var timestampText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    private var iconName: String {
        switch ingestionPath {
        case .platformStore: return "heart.text.square"
        case .manual: return "square.and.pencil"
        case .fileImport: return "square.and.arrow.down"
        case .derived: return "function"
        case .vendor: return "link"
        }
    }
}
