import Foundation

/// Parses Garmin Training Center XML (TCX v2) activities into the same DTO shapes
/// `IngestionPipeline.ingest` already knows how to write (EPIC-43 ACC-005). Pure and stateless,
/// exactly like `GPXFileParser` — no database access, no consent decision.
///
/// TCX's `<Activity>/<Lap>/<Track>/<Trackpoint>` structure is similar to GPX's `<trk>/<trkseg>/
/// <trkpt>` but carries more: per-lap distance/calories/heart-rate summaries, and per-trackpoint
/// heart rate, and (via Garmin's `TPX` extension schema) cadence and power. This slice extracts
/// **distance, calories, heart rate, position/altitude, and time** into BADAN's DTOs. It reads —
/// but deliberately does NOT store — cadence (`<Cadence>`, `<RunCadence>`) and power (`<Watts>`):
/// BADAN's metric ontology (`registry.json`) has no registered `activity.cadence`/`activity.power`
/// metric id yet, and emitting a `SampleDTO` under an invented id would be written by this parser
/// only to be silently skipped by `IngestionPipeline.writeSamples`'s `guard registry.definition(
/// dto.metricId) else { continue }` — precisely the silent drop this importer is documented not to
/// do. Naming the gap here (rather than fabricating an id to hang the value on) is the honest
/// version of "extract what you can"; a future ontology slice can wire this branch once those ids
/// exist.
///
/// Element matching is by LOCAL name only (the part after any `:` prefix) rather than by resolved
/// namespace, so a file using Garmin's usual `<ns3:TPX>`-style prefixes and one using an unprefixed
/// default namespace are both read identically without configuring `XMLParser`'s namespace
/// processing — a small, deliberate simplification appropriate for a read-only importer.
enum TCXFileParser {
    static func parse(fileURL: URL) throws -> ParsedFileImport {
        // See `GPXFileParser.parse`'s comment: reading the bytes up front distinguishes an
        // unreadable file from a genuinely malformed one, which `InputStream(url:)` cannot.
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw FileImportError.cannotReadFile
        }
        let parser = XMLParser(data: data)
        let delegate = TCXParserDelegate()
        parser.delegate = delegate
        let ok = parser.parse()
        guard ok else {
            throw FileImportError.malformed(parser.parserError?.localizedDescription ?? "unparseable TCX XML")
        }
        return delegate.result()
    }
}

private final class TCXParserDelegate: NSObject, XMLParserDelegate {
    private struct TCXLap {
        var distanceMeters: Double?
        var calories: Double?
        var avgHeartRateBpm: Double?
        var maxHeartRateBpm: Double?
    }
    private struct TCXPoint {
        var time: Date?
        var lat: Double?
        var lon: Double?
        var altitude: Double?
        var heartRate: Double?
    }
    private struct TCXActivity {
        var sport: String
        var laps: [TCXLap] = []
        var points: [TCXPoint] = []
    }

    private enum HRContext { case lapAverage, lapMaximum, trackpoint }

    private var activities: [TCXActivity] = []
    private var currentActivity: TCXActivity?
    private var currentLap: TCXLap?
    private var currentPoint: TCXPoint?
    private var inPosition = false
    private var hrContext: HRContext?
    private var textBuffer = ""

    private static func localName(_ raw: String) -> String {
        guard let idx = raw.lastIndex(of: ":") else { return raw }
        return String(raw[raw.index(after: idx)...])
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
               qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        textBuffer = ""
        switch Self.localName(elementName) {
        case "Activity":
            currentActivity = TCXActivity(sport: attributeDict["Sport"] ?? "Other")
        case "Lap":
            currentLap = TCXLap()
        case "Trackpoint":
            currentPoint = TCXPoint()
        case "Position":
            inPosition = true
        case "AverageHeartRateBpm":
            hrContext = .lapAverage
        case "MaximumHeartRateBpm":
            hrContext = .lapMaximum
        case "HeartRateBpm":
            hrContext = .trackpoint
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
               qualifiedName qName: String?) {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        textBuffer = ""
        switch Self.localName(elementName) {
        case "DistanceMeters":
            // The element name is shared by `<Lap><DistanceMeters>` (the lap's total) and
            // `<Trackpoint><DistanceMeters>` (per-point cumulative distance). Only the lap total
            // is kept — `WorkoutTotals` has one `distanceMeters` field for the whole workout, and
            // there is no per-point DTO field to hold a running cumulative figure in.
            // AUDIT FIX: every numeric field below now requires `.isFinite` in addition to a
            // successful parse — `Double.init?(String)` alone accepts "nan"/"inf"/hex-float
            // tokens, which would otherwise become garbage figures silently persisted as trusted
            // workout totals/samples.
            if currentPoint == nil, let v = Double(text), v.isFinite { currentLap?.distanceMeters = v }
        case "Calories":
            if let v = Double(text), v.isFinite { currentLap?.calories = v }
        case "Value":
            guard let v = Double(text), v.isFinite else { break }
            switch hrContext {
            case .lapAverage: currentLap?.avgHeartRateBpm = v
            case .lapMaximum: currentLap?.maxHeartRateBpm = v
            case .trackpoint: currentPoint?.heartRate = v
            case nil: break
            }
        case "AverageHeartRateBpm", "MaximumHeartRateBpm", "HeartRateBpm":
            hrContext = nil
        case "Time":
            if currentPoint != nil { currentPoint?.time = Self.parseTime(text) }
        case "LatitudeDegrees":
            if inPosition { let v = Double(text); currentPoint?.lat = (v?.isFinite == true) ? v : nil }
        case "LongitudeDegrees":
            if inPosition { let v = Double(text); currentPoint?.lon = (v?.isFinite == true) ? v : nil }
        case "Position":
            inPosition = false
        case "AltitudeMeters":
            if currentPoint != nil {
                let v = Double(text)
                currentPoint?.altitude = (v?.isFinite == true) ? v : nil
            }
        case "Cadence", "RunCadence", "Watts", "Speed":
            break   // read but not stored — see this file's type doc
        case "Trackpoint":
            if let point = currentPoint { currentActivity?.points.append(point) }
            currentPoint = nil
        case "Lap":
            if let lap = currentLap { currentActivity?.laps.append(lap) }
            currentLap = nil
        case "Activity":
            if let activity = currentActivity { activities.append(activity) }
            currentActivity = nil
        default:
            break
        }
    }

    func result() -> ParsedFileImport {
        var parsed = ParsedFileImport()
        guard !activities.isEmpty else { return parsed }
        let source = SourceDescriptor(id: "file:tcx", displayName: "TCX file import",
                                      type: .fileImport, priority: 0)
        var recordsProcessed = 0
        var workouts: [WorkoutDTO] = []
        var samples: [SampleDTO] = []

        for (index, activity) in activities.enumerated() {
            recordsProcessed += activity.points.count
            let timedPoints = activity.points.filter { $0.time != nil }
            let times = timedPoints.compactMap(\.time)
            guard let start = times.min(), let end = times.max() else { continue }

            let totalDistance = activity.laps.compactMap(\.distanceMeters).reduce(0, +)
            let totalCalories = activity.laps.compactMap(\.calories).reduce(0, +)
            let lapAverages = activity.laps.compactMap(\.avgHeartRateBpm)
            let lapMaxima = activity.laps.compactMap(\.maxHeartRateBpm)
            let trackpointHR = timedPoints.compactMap(\.heartRate)

            // Prefer the file's own lap-level summary (what the device itself reported); fall
            // back to deriving it from the trackpoint readings this parser already collected when
            // a file carries no lap summary at all — never fabricated when neither is present.
            let avgHR: Double? = !lapAverages.isEmpty ? lapAverages.reduce(0, +) / Double(lapAverages.count)
                : (!trackpointHR.isEmpty ? trackpointHR.reduce(0, +) / Double(trackpointHR.count) : nil)
            let maxHR: Double? = !lapMaxima.isEmpty ? lapMaxima.max() : trackpointHR.max()

            var totals = WorkoutTotals()
            if totalDistance > 0 { totals.distanceMeters = totalDistance }
            if totalCalories > 0 { totals.energyKcal = totalCalories }
            totals.avgHeartRateBpm = avgHR
            totals.maxHeartRateBpm = maxHR

            let externalId = "tcx-workout-\(source.id)-\(start.epochMillis)-\(index)"

            let routePoints = timedPoints.compactMap { p -> RoutePointDTO? in
                guard let lat = p.lat, let lon = p.lon, let time = p.time else { return nil }
                return RoutePointDTO(latitude: lat, longitude: lon, altitudeMeters: p.altitude, timestamp: time)
            }
            let route: RouteDTO? = routePoints.isEmpty ? nil
                : RouteDTO(externalId: externalId, points: routePoints, consent: .denied)

            workouts.append(WorkoutDTO(
                activityType: Self.activitySlug(forSport: activity.sport),
                start: start, end: end, tz: "GMT", sourceId: source.id,
                externalId: externalId, sourceWorkoutUUID: externalId, totals: totals, route: route,
                qualityFlags: [.tzAssumed]))

            // Per-trackpoint heart rate -> the SAME `heart.hr` samples live HealthKit sync writes,
            // so an imported TCX's HR shows up wherever any other HR sample does (Metric Detail,
            // baselines) instead of being locked inside the workout's own totals.
            for point in timedPoints {
                guard let hr = point.heartRate, let time = point.time else { continue }
                let sampleExternalId = "tcx-hr-\(source.id)-\(time.epochMillis)-\(index)"
                samples.append(SampleDTO(metricId: MetricID.heartRate, value: hr, unit: "bpm",
                                         start: time, tz: "GMT", sourceId: source.id,
                                         externalId: sampleExternalId, qualityFlags: [.tzAssumed]))
            }
        }

        parsed.descriptors = workouts.isEmpty ? [] : [source]
        parsed.workouts = workouts
        parsed.samples = samples
        parsed.recordsProcessed = recordsProcessed
        return parsed
    }

    /// TCX's `Sport` attribute is a closed, three-value schema enum (`Running` | `Biking` |
    /// `Other`) — unlike GPX's free-text `<type>` hint, so no "keep the original as evidence"
    /// fallback is needed here.
    private static func activitySlug(forSport sport: String) -> String {
        switch sport.lowercased() {
        case "running": return "running"
        case "biking": return "cycling"
        default: return "other"
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTime(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? iso.date(from: s)
    }
}
