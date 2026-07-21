import Foundation

/// One curated behavior a user can tap on the journal screen (`behaviors.json`). Same
/// dictionary-vs-custom split as `SymptomDictionary`: the curated set ships as bundled data,
/// anything else is a free-text `customLabel` on the `JournalEntry` itself.
///
/// `sensitiveClass` is carried per behavior rather than assumed for the whole family, so the data
/// file states the I7 classification for each row instead of it living only in code — and so a
/// future entry cannot be quietly added at a lower class. Every entry today is `sensitivePlus`;
/// `BehaviorDictionary.allAreSensitivePlus` is what a test asserts against.
public struct BehaviorDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var nameEn: String
    public var nameAr: String
    public var valueKind: BehaviorValueKind
    /// Canonical unit — present only for `.quantity` behaviors.
    public var unit: String?
    public var category: String
    public var sensitiveClass: SensitiveClass

    public var displayName: LocalizedString { LocalizedString(en: nameEn, ar: nameAr) }
}

/// The canonical, localized behavior vocabulary (`behaviors.json`) — the tags the daily journal
/// offers. Byte-for-byte the same data Android reads, so a behavior id logged on one platform
/// resolves to the same name (and the same `valueKind`) on the other, which is what lets a
/// correlation computed on one device be read on the other.
final class BehaviorDictionary {
    static let shared = BehaviorDictionary()

    let all: [BehaviorDefinition]
    private let byId: [String: BehaviorDefinition]

    private struct File: Decodable { let behaviors: [BehaviorDefinition] }

    init(behaviors: [BehaviorDefinition]? = nil) {
        let loaded = behaviors ?? BundleJSON.load(File.self, "behaviors")?.behaviors ?? []
        self.all = loaded
        self.byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func definition(_ id: String?) -> BehaviorDefinition? { id.flatMap { byId[$0] } }

    /// Display name for a logged entry. An unknown id (a dictionary row removed in a later
    /// version, read back from an old journal row) falls back to the id itself rather than an
    /// empty string, so a historical entry never renders nameless.
    func displayName(forId id: String?, customLabel: String?) -> LocalizedString {
        if let def = definition(id) { return def.displayName }
        if let customLabel, !customLabel.isEmpty { return LocalizedString(en: customLabel, ar: customLabel) }
        if let id, !id.isEmpty { return LocalizedString(en: id, ar: id) }
        return LocalizedString(en: "Behavior", ar: "سلوك")
    }

    /// The value shape a chip should collect for `id`, defaulting to `.boolean` for an id the
    /// dictionary doesn't know — the safest shape, since it asks for no number the app would then
    /// have to invent a unit for.
    func valueKind(forId id: String?) -> BehaviorValueKind { definition(id)?.valueKind ?? .boolean }

    /// Every behavior is sensitive-plus (I7). Exposed rather than assumed so the invariant is
    /// checkable from the loaded data, not just asserted in a comment.
    var allAreSensitivePlus: Bool { all.allSatisfy { $0.sensitiveClass == .sensitivePlus } }

    /// Categories in file order — the chip-group order the journal screen renders.
    var categories: [String] {
        var seen = Set<String>(); var ordered: [String] = []
        for b in all where !seen.contains(b.category) { seen.insert(b.category); ordered.append(b.category) }
        return ordered
    }

    func inCategory(_ category: String) -> [BehaviorDefinition] { all.filter { $0.category == category } }

    func search(_ query: String) -> [BehaviorDefinition] {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.nameEn.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
                || $0.nameAr.contains(query)
        }
    }
}
