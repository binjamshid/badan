import Foundation

/// ULID — Universally Unique Lexicographically Sortable Identifier.
///
/// BADAN mints all entity ids on-device (INVARIANT I8). ULIDs are offline-generatable,
/// time-sortable (good for `ORDER BY id` and B-tree locality), and collision-safe enough
/// for a single-user local store while remaining sync-safe for a future multi-device world.
///
/// Layout: 48-bit millisecond timestamp (10 Crockford-base32 chars) + 80 bits of
/// randomness (16 chars) = 26 chars. Encoding is canonical Crockford base32.
public enum ULID {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Deterministic generator — used by tests and any code that injects a clock/RNG.
    public static func generate(date: Date, rng: inout some RandomNumberGenerator) -> String {
        let ms = UInt64(max(0, date.timeIntervalSince1970) * 1000)
        var chars = [Character]()
        chars.reserveCapacity(26)

        // 48-bit timestamp -> 10 base32 chars (most-significant first).
        var t = ms & 0xFFFF_FFFF_FFFF
        var timeChars = [Character](repeating: alphabet[0], count: 10)
        var i = 9
        while i >= 0 {
            timeChars[i] = alphabet[Int(t & 0x1F)]
            t >>= 5
            i -= 1
        }
        chars.append(contentsOf: timeChars)

        // 80 bits of randomness -> 16 base32 chars.
        for _ in 0..<16 {
            chars.append(alphabet[Int(rng.next() % 32)])
        }
        return String(chars)
    }

    /// Convenience generator using an injected clock (defaults to the system clock) + CSPRNG.
    /// Domain code that already has a `Clock` in scope (e.g. `IngestionPipeline`,
    /// `SeedController`) should pass it explicitly so id-embedded timestamps stay
    /// consistent with the domain's actual time model (e.g. backdated seed data), rather
    /// than always embedding the real wall-clock instant regardless of what the injected
    /// clock says "now" is.
    public static func newID(clock: Clock = SystemClock()) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(date: clock.now(), rng: &rng)
    }

    /// Extract the embedded timestamp (millisecond precision) from a ULID, if valid.
    public static func timestamp(of ulid: String) -> Date? {
        guard ulid.count == 26 else { return nil }
        var value: UInt64 = 0
        for ch in ulid.prefix(10) {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | UInt64(idx)
        }
        return Date(timeIntervalSince1970: Double(value) / 1000.0)
    }
}
