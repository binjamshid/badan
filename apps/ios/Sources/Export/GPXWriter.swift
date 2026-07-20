import CryptoKit
import Foundation

/// EPIC-12: renders a workout's stored GPS trace as GPX 1.1 (plan §22.4).
///
/// GPX is the one format BADAN writes that is **not** BADAN's contract. `csv_columns.json` and
/// `json_bundle.schema.json` are ours to version; GPX 1.1 belongs to topografix, and Strava,
/// Garmin Connect and every map tool the user might open the file in read *that* schema. Two
/// consequences run through this whole file and are easy to "fix" back into breakage:
///
/// 1. **Timestamps are UTC with a `Z`, not a numeric offset.** §22.1's numeric-offset rule
///    (`+00:00`, never `Z`) governs BADAN's own formats so CSV, the JSON bundle and the manifest
///    cannot drift apart. GPX's `xsd:dateTime` accepts both spellings, but every GPX file in the
///    wild is UTC-`Z`, and route points have no per-point timezone to carry an offset from in the
///    first place (`route_points` deliberately has no `tz_id` — see migration v4). Rendering these
///    through `TimestampFormatting` to satisfy a rule about a different contract would make the
///    file more BADAN-consistent and less useful to the person exporting it.
/// 2. **Element order inside `<metadata>`, `<trk>` and `<trkpt>` is fixed by the schema**, not by
///    taste. GPX 1.1 declares them as `xsd:sequence`, so a validating consumer rejects a file that
///    puts `<time>` before `<name>`. The emit order below is the schema's order.
///
/// ## The two gates
///
/// Routes are the only location data BADAN holds, and they sit behind **two independent
/// permissions**, not one:
///
/// - **Route ingestion consent** — what allowed the rows to be captured at all. Enforced upstream
///   in `HealthKitAdapter`; frozen per-route into `workout_routes.consent_snapshot` so "was this
///   row allowed to exist when it was written" stays answerable later.
/// - **Route export consent** — this file's gate. A separate, current-state toggle answering "may
///   these coordinates leave the device". Plan §4.11: each sensitive class "gets its own consent
///   toggle *and* its own export opt-in".
///
/// The snapshot is deliberately NOT consulted here. It records history; export asks a question
/// about now. A user who granted ingestion last year and has since turned export off must get
/// nothing, and a user who turned ingestion off keeps the right to export what was already
/// collected — neither behaviour is reachable if the two gates are conflated into one.
///
/// GPX never appears in Quick Export. That exclusion is structural rather than a default: see
/// `QuickExportPreset.presetScope`, which is private and hardcodes a raw/derived-only scope.
enum GPXExportError: Error, Equatable {
    /// The route-export toggle is off. Distinct from ingestion consent — see the type doc.
    case routeExportNotEnabled
    /// The confirmation describes a different set of routes than the one being written. Almost
    /// always means routes were added, deleted or re-ingested between the confirmation sheet and
    /// the write; the user agreed to a count and a span that are no longer true.
    case confirmationStale(acknowledged: String, actual: String)
    /// A workout was handed in with no usable points. Surfaced rather than skipped so an empty
    /// GPX file never lands in a bundle that claims a route count.
    case emptyRoute(workoutId: String)
}

/// One GPS trace as it comes off `RouteRepository` — a `workout_routes` row's identity plus its
/// ordered points.
///
/// `routeId` is carried even though it never appears in the output, because segment breaks happen
/// at route boundaries and a diagnostic that says "segment 3 came from route X" is the difference
/// between a two-minute and a two-hour investigation.
struct GPXRoute {
    var routeId: String
    var points: [RoutePoint]

    init(routeId: String, points: [RoutePoint]) {
        self.routeId = routeId
        self.points = points
    }
}

/// One workout and every trace attached to it.
///
/// A `<trk>` is per **workout**, not per route (§22.4), so a session that stored several
/// `workout_routes` rows produces one file with one track. That is also what resolves the naming
/// collision the filename rule would otherwise create: `route_<workout-ulid>.gpx` is keyed on the
/// session, and `workout_routes` permits more than one row per session.
struct GPXWorkout {
    /// `sessions.id` — the workout ULID that names the file (I8).
    var workoutId: String
    /// `<trk><name>`. The workout's display label; free text, XML-escaped on the way out.
    var name: String
    var routes: [GPXRoute]

    init(workoutId: String, name: String, routes: [GPXRoute]) {
        self.workoutId = workoutId
        self.name = name
        self.routes = routes
    }
}

/// What the user is shown before a single byte of location data is written: how many routes, from
/// how many workouts, over what span.
///
/// A value type rather than a UI string because the confirmation has to be *checkable*. The
/// fingerprint is the mechanism: `GPXWriter.artifacts` recomputes the plan from the workouts it is
/// actually about to write and refuses if it does not match what the user acknowledged. Without
/// that, "confirm before export" is a screen someone can forget to present, or present against a
/// stale snapshot — and the failure is silent, because the file looks fine.
struct RouteExportPlan: Equatable {
    let workoutCount: Int
    let routeCount: Int
    let pointCount: Int
    /// Earliest and latest point timestamps across every route. `nil` only when there are no
    /// points at all.
    let earliest: Date?
    let latest: Date?

    /// Derives the plan from the exact workout list that will be written.
    static func make(_ workouts: [GPXWorkout]) -> RouteExportPlan {
        let allPoints = workouts.flatMap { $0.routes.flatMap(\.points) }
        return RouteExportPlan(
            workoutCount: workouts.count,
            routeCount: workouts.reduce(0) { $0 + $1.routes.count },
            pointCount: allPoints.count,
            earliest: allPoints.map(\.timestamp).min(),
            latest: allPoints.map(\.timestamp).max())
    }

    /// Stable digest of everything the confirmation copy states, plus the workout ids behind it.
    ///
    /// Ids are included deliberately. Counts and a span alone would let one route be swapped for
    /// another of the same vintage without changing the fingerprint — the user would have agreed
    /// to export three rides in March and would get three *different* rides in March.
    ///
    /// This digest gates a confirmation against a write on the same device; it is internal to one
    /// platform and needs stability within a run, not cross-platform byte parity.
    func fingerprint(of workouts: [GPXWorkout]) -> String {
        var parts: [String] = [
            "v1", String(workoutCount), String(routeCount), String(pointCount),
            earliest.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "-",
            latest.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "-",
        ]
        // Sorted so the digest describes the *set* being exported, not the order a caller
        // happened to assemble it in — reordering a list is not a change the user needs to
        // re-confirm.
        parts.append(contentsOf: workouts.map(\.workoutId).sorted())
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Proof that a specific `RouteExportPlan` was put in front of the user and accepted.
///
/// Deliberately has no public initializer taking a bare string: the only way to obtain one is to
/// build a plan from real workouts and acknowledge *that*. A caller cannot fabricate a
/// confirmation without first computing the thing it is supposed to have shown.
struct RouteExportConfirmation {
    fileprivate let fingerprint: String

    init(acknowledging plan: RouteExportPlan, from workouts: [GPXWorkout]) {
        self.fingerprint = plan.fingerprint(of: workouts)
    }
}

/// Renders `GPXWorkout`s to GPX 1.1 documents. Stateless; one instance per export run carries the
/// run's generation timestamp so every file in a bundle agrees on it.
struct GPXWriter {
    /// The gap between consecutive fixes that ends a `<trkseg>` (§22.4: "route gaps >60s split
    /// segments"). **Strictly** greater — a fix exactly 60s after its predecessor stays in the
    /// same segment, which is the reading that keeps a 1-per-minute sampling cadence from
    /// producing one segment per point.
    ///
    /// The point of splitting is that a `<trkseg>` asserts continuity: consumers draw a line
    /// between consecutive points in a segment. Without the split, a pause — a tunnel, a lost
    /// lock, a paused workout — renders as a straight line across whatever the athlete did not
    /// actually travel, and distance computed off the file is wrong in the athlete's favour.
    static let segmentGapSeconds: TimeInterval = 60

    /// Emitted at the root as `creator` and echoed in `<metadata><desc>`.
    private let appVersion: String
    private let generatedAt: Date

    init(appVersion: String, generatedAt: Date) {
        self.appVersion = appVersion
        self.generatedAt = generatedAt
    }

    /// One rendered file: its name inside the bundle and its bytes.
    struct Artifact: Equatable {
        let fileName: String
        let gpx: String
    }

    /// §22.4: `route_<workout-ulid>.gpx`, referenced from the workout object via `route_ref`.
    static func fileName(workoutId: String) -> String { "route_\(workoutId).gpx" }

    /// Renders every workout's trace, after checking both gates.
    ///
    /// Order of checks matters and is not arbitrary: the toggle is tested before the confirmation,
    /// so a build with the feature off reports the honest reason rather than a fingerprint
    /// mismatch that sends someone debugging the wrong thing.
    func artifacts(for workouts: [GPXWorkout],
                   routeExportEnabled: Bool,
                   confirmation: RouteExportConfirmation) throws -> [Artifact] {
        guard routeExportEnabled else { throw GPXExportError.routeExportNotEnabled }

        let actual = RouteExportPlan.make(workouts).fingerprint(of: workouts)
        guard confirmation.fingerprint == actual else {
            throw GPXExportError.confirmationStale(acknowledged: confirmation.fingerprint, actual: actual)
        }

        return try workouts.map { workout in
            guard workout.routes.contains(where: { !$0.points.isEmpty }) else {
                throw GPXExportError.emptyRoute(workoutId: workout.workoutId)
            }
            return Artifact(fileName: Self.fileName(workoutId: workout.workoutId),
                            gpx: render(workout))
        }
    }

    /// The GPX document for one workout. Line endings are LF and there is a trailing newline —
    /// XML convention, deliberately not the CRLF the CSV contract mandates (RFC 4180 governs CSV
    /// and nothing else).
    func render(_ workout: GPXWorkout) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<gpx version=\"1.1\" creator=\"BADAN/\(Self.xmlEscape(appVersion))\""
        out += " xmlns=\"http://www.topografix.com/GPX/1/1\""
        out += " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
        out += " xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1"
        out += " http://www.topografix.com/GPX/1/1/gpx.xsd\">\n"

        // `<metadata>`: name, desc, time — the schema's sequence order. §22.4 asks for the export
        // timestamp and the BADAN version here; `creator` above carries the version too because
        // that is where GPX consumers actually look for it.
        out += "  <metadata>\n"
        out += "    <name>BADAN workout route export</name>\n"
        out += "    <desc>BADAN \(Self.xmlEscape(appVersion)) · export schema \(ExportSchema.version)</desc>\n"
        out += "    <time>\(Self.gpxTime(generatedAt))</time>\n"
        out += "  </metadata>\n"

        out += "  <trk>\n"
        out += "    <name>\(Self.xmlEscape(workout.name))</name>\n"
        for segment in Self.segments(of: workout) {
            out += "    <trkseg>\n"
            for point in segment {
                out += "      <trkpt lat=\"\(Self.coordinate(point.latitude))\""
                out += " lon=\"\(Self.coordinate(point.longitude))\">\n"
                if let elevation = point.altitudeMeters {
                    out += "        <ele>\(Self.elevation(elevation))</ele>\n"
                }
                out += "        <time>\(Self.gpxTime(point.timestamp))</time>\n"
                out += "      </trkpt>\n"
            }
            out += "    </trkseg>\n"
        }
        out += "  </trk>\n"
        out += "</gpx>\n"
        return out
    }

    // MARK: - Segmentation

    /// Splits a workout's points into continuous segments.
    ///
    /// Two things end a segment:
    ///
    /// - a gap of more than `segmentGapSeconds` between consecutive fixes (§22.4);
    /// - a **route boundary**. Two `workout_routes` rows are two separately-captured traces, and
    ///   joining them into one `<trkseg>` would assert a continuity the data does not support even
    ///   if their timestamps happen to abut. This is not in §22.4 because §22.4 assumes the common
    ///   one-route case; the schema permits several and this is the honest rendering of them.
    ///
    /// Routes are ordered by their first point so a caller that assembled them out of order still
    /// gets a chronological track; points inside a route arrive in `seq` order from the repository
    /// and are re-sorted by timestamp defensively (a route whose points went backwards would
    /// otherwise produce one bogus segment break per inversion, which reads like data loss).
    static func segments(of workout: GPXWorkout) -> [[RoutePoint]] {
        let routes = workout.routes
            .map { route in route.points.sorted { $0.timestamp < $1.timestamp } }
            .filter { !$0.isEmpty }
            .sorted { ($0.first?.timestamp ?? .distantPast) < ($1.first?.timestamp ?? .distantPast) }

        var segments: [[RoutePoint]] = []
        for points in routes {
            var current: [RoutePoint] = []
            for point in points {
                if let previous = current.last,
                   point.timestamp.timeIntervalSince(previous.timestamp) > segmentGapSeconds {
                    segments.append(current)
                    current = []
                }
                current.append(point)
            }
            if !current.isEmpty { segments.append(current) }
        }
        return segments
    }

    // MARK: - Rendering primitives

    /// Latitude/longitude at a fixed seven decimal places.
    ///
    /// Fixed width, not trimmed: `CSVWriter.decimal` would render a whole-degree coordinate as
    /// `25`, which is a valid number and a strange-looking coordinate, and its trailing-zero
    /// trimming is one more thing that has to match across platforms. Seven places is ~1.1 cm —
    /// two orders of magnitude finer than any consumer GNSS fix — so nothing real is discarded.
    ///
    /// The rounding is done in integer space rather than with `%.7f` on purpose. C's `printf`
    /// rounds half-to-even on the double's exact binary value; the JVM's `String.format` rounds
    /// half-up on its exact decimal expansion. They agree on essentially every input and disagree
    /// on exact multiples of 1/256 (whose decimal expansion terminates at the eighth place, e.g.
    /// `25.00390625` → `25.0039062` versus `25.0039063`). A synthetic fixture coordinate is
    /// exactly the kind of value that lands on a dyadic rational, so the byte-parity fixture would
    /// have been the thing to discover this. Multiplying and rounding explicitly makes both
    /// platforms run the same two IEEE-754 operations.
    static func coordinate(_ value: Double) -> String { fixedPoint(value, decimals: 7) }

    /// Elevation at one decimal place. Barometric altimeters are accurate to roughly a metre;
    /// decimetres are already generous and centimetres would be inventing precision.
    static func elevation(_ value: Double) -> String { fixedPoint(value, decimals: 1) }

    /// Fixed-point decimal rendering with half-away-from-zero rounding, built from integer parts
    /// so no locale, no `%f` implementation and no trailing-zero policy can differ across
    /// platforms. See `coordinate` for why that matters here specifically.
    private static func fixedPoint(_ value: Double, decimals: Int) -> String {
        var scale = 1.0
        for _ in 0..<decimals { scale *= 10 }
        let scaled = value * scale
        // Half away from zero, spelled out rather than delegated: Swift's `rounded()` and the
        // JVM's `Math.round` disagree on negative halves (-2.5 -> -3 versus -2), and southern /
        // western coordinates are negative.
        let magnitude = (abs(scaled) + 0.5).rounded(.down)
        let units = Int64(magnitude)
        let divisor = Int64(scale)
        let whole = units / divisor
        let fraction = units % divisor
        var fractionText = String(fraction)
        while fractionText.count < decimals { fractionText = "0" + fractionText }
        // The sign is taken from the input, not from `whole`: -0.0000001 has a whole part of 0
        // and still belongs south of the equator.
        let negative = scaled < 0 && units != 0
        return "\(negative ? "-" : "")\(whole).\(fractionText)"
    }

    /// GPX `xsd:dateTime`: UTC, second precision, `Z`.
    ///
    /// Sub-second precision is dropped. BADAN renders every other timestamp to the second, GNSS
    /// fixes arrive at 1 Hz, and carrying milliseconds only here would give the format its own
    /// rendering rule for no reader's benefit. Two fixes inside one second therefore share a
    /// `<time>`; their order is preserved by their order in the file, which is what a `<trkseg>`
    /// means.
    static func gpxTime(_ date: Date) -> String {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let civil = CivilTime.from(epochSeconds: seconds)
        func pad(_ value: Int64, _ width: Int) -> String {
            var text = String(value)
            while text.count < width { text = "0" + text }
            return text
        }
        return "\(pad(civil.year, 4))-\(pad(civil.month, 2))-\(pad(civil.day, 2))T"
            + "\(pad(civil.hour, 2)):\(pad(civil.minute, 2)):\(pad(civil.second, 2))Z"
    }

    /// XML text escaping for the free-text fields (`creator`, `<name>`). Covers the five
    /// predefined entities; `"` and `'` matter because `creator` is an attribute value.
    static func xmlEscape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }
}
