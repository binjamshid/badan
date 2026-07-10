import Foundation

/// Loads bundled JSON data resources (the compiled ontology/dictionaries/templates). The
/// data is authored in `packages/` and mirrored into the app bundle by
/// `scripts/sync_ios_resources.sh`.
enum BundleJSON {
    private static let decoder = JSONDecoder()

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("Missing bundled resource \(name).json")
            return nil
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            assertionFailure("Failed to decode \(name).json: \(error)")
            return nil
        }
    }
}
