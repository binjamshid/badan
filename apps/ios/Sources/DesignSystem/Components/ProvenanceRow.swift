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
                .lineLimit(1)
                .truncationMode(.tail)
            Text(ingestionPath.displayLabel.resolved(language))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: BadanSpace.space2)
            Text(timestampText)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .lineLimit(1)
                // A record timestamp is a technical identifier, not prose — keep it
                // left-to-right in both languages, matching InsightsWhyDisclosure.
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    // Cached once per type instead of allocating a fresh `DateFormatter` on every render;
    // only the locale (a cheap property set) changes between calls.
    private static let cachedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var timestampText: String {
        Self.cachedFormatter.locale = Locale(identifier: language.localeIdentifier)
        return Self.cachedFormatter.string(from: timestamp)
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

#Preview("ProvenanceRow") {
    VStack(alignment: .leading, spacing: BadanSpace.space2) {
        ProvenanceRow(sourceName: "Apple Watch", ingestionPath: .platformStore, timestamp: .now, language: .en)
        ProvenanceRow(sourceName: "An unusually long vendor-provided source name", ingestionPath: .fileImport,
                      timestamp: .now, language: .en)
        ProvenanceRow(sourceName: "أدخلتها بنفسك", ingestionPath: .manual, timestamp: .now, language: .ar)
    }
    .padding()
}
