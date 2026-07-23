import Foundation

/// Parses GPX 1.1 track files into the same `WorkoutDTO`/`RoutePointDTO` shapes
/// `IngestionPipeline.ingest` already knows how to write (EPIC-43 ACC-005). Pure and stateless:
/// no database access, no consent decision (`FileImporter` applies the live route-consent value
/// at commit time — see its doc), no I/O beyond reading the one file handed in.
///
/// Reads exactly the elements `GPXWriter.render(_:)` writes per track point (that file, lines
/// ~229-244): `<trk><name>`/`<type>`, `<trkseg><trkpt lat= lon=><ele/><time/></trkpt></trkseg>`.
/// A GPX file can carry much more (waypoints, `<rte>` navigation routes, vendor extensions) — none
/// of that is read here; only `<trk>` is, which is BADAN's own round-trip target and the ordinary
/// shape for an exported workout track. Multiple `<trk>` elements produce one `WorkoutDTO` each.
enum GPXFileParser {
    static func parse(fileURL: URL) throws -> ParsedFileImport {
        // Read the bytes up front rather than handing `XMLParser` an `InputStream(url:)` directly:
        // a stream over a missing/unreadable file opens "successfully" and only fails once the
        // parser starts pulling from it, which surfaces as an indistinguishable XML parse error —
        // `Data(contentsOf:)` throws immediately and honestly for that case instead.
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw FileImportError.cannotReadFile
        }
        let parser = XMLParser(data: data)
        let delegate = GPXParserDelegate()
        parser.delegate = delegate
        let ok = parser.parse()
        guard ok else {
            throw FileImportError.malformed(parser.parserError?.localizedDescription ?? "unparseable GPX XML")
        }
        return delegate.result()
    }
}

/// SAX delegate doing the actual walk. A class (not the enum above) because `XMLParserDelegate`
/// requires reference semantics; kept private and used only inside `GPXFileParser.parse`.
private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    private struct GPXTrack {
        var typeHint: String?
        var points: [RoutePointDTO] = []
    }

    /// A `<trkpt>` under construction. `lat`/`lon` come from attributes at `didStartElement`;
    /// `elevation`/`time` are filled in as their child elements close.
    private struct GPXPointBuilder {
        var lat: Double
        var lon: Double
        var elevation: Double?
        var time: Date?
    }

    private var tracks: [GPXTrack] = []
    private var currentTrack: GPXTrack?
    private var currentPoint: GPXPointBuilder?
    private var inTrkpt = false
    private var textBuffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
               qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        textBuffer = ""
        switch elementName {
        case "trk":
            currentTrack = GPXTrack()
        case "trkpt":
            inTrkpt = true
            // Missing or unparseable lat/lon is a real GPX schema violation (both are required
            // attributes) — this ONE point is skipped rather than aborting the whole file, so a
            // single bad fix in an otherwise-good track doesn't discard everything around it.
            // AUDIT FIX: `.isFinite` required too — `Double.init?` alone accepts "nan"/"inf"/hex-
            // float tokens, which would otherwise become a garbage coordinate silently persisted
            // into `route_points` and corrupt distance/route-summary math downstream.
            if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
               let lat = Double(latStr), let lon = Double(lonStr), lat.isFinite, lon.isFinite {
                currentPoint = GPXPointBuilder(lat: lat, lon: lon)
            } else {
                currentPoint = nil
            }
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
        switch elementName {
        case "type":
            // `<type>` is not part of the base GPX 1.1 `trkType` content model as BADAN's own
            // `GPXWriter` emits it, but several real-world exporters (Strava, Garmin Connect)
            // add it as a de facto convention naming the activity. Read opportunistically; a
            // file without it (including every file BADAN itself writes) falls back to "other"
            // in `result()` below, which is the honest default rather than a guess.
            if currentTrack != nil, !inTrkpt { currentTrack?.typeHint = text }
        case "ele":
            // AUDIT FIX: reject a non-finite elevation the same way lat/lon already are — an
            // absent/rejected value stays nil (never invented), it is never worse than a silently
            // corrupt one.
            if inTrkpt {
                let parsed = Double(text)
                currentPoint?.elevation = (parsed?.isFinite == true) ? parsed : nil
            }
        case "time":
            if inTrkpt { currentPoint?.time = Self.parseTime(text) }
        case "trkpt":
            inTrkpt = false
            // A point with no usable timestamp cannot be ordered against its neighbors or land in
            // `RoutePointDTO` (whose `timestamp` is non-optional) — skipped, not fabricated.
            if let point = currentPoint, let time = point.time {
                currentTrack?.points.append(RoutePointDTO(
                    latitude: point.lat, longitude: point.lon, altitudeMeters: point.elevation,
                    timestamp: time))
            }
            currentPoint = nil
        case "trk":
            if let track = currentTrack { tracks.append(track) }
            currentTrack = nil
        default:
            break
        }
    }

    /// Builds the final DTOs once parsing has finished. A track with zero usable points (every
    /// `<trkpt>` was malformed, or the track is empty) contributes no workout at all — an honest
    /// "nothing here", not a zero-point workout.
    func result() -> ParsedFileImport {
        var parsed = ParsedFileImport()
        guard !tracks.isEmpty else { return parsed }
        let source = SourceDescriptor(id: "file:gpx", displayName: "GPX file import",
                                      type: .fileImport, priority: 0)
        var recordsProcessed = 0
        var workouts: [WorkoutDTO] = []
        for (index, track) in tracks.enumerated() {
            recordsProcessed += track.points.count
            guard !track.points.isEmpty else { continue }
            let ordered = track.points.sorted { $0.timestamp < $1.timestamp }
            guard let start = ordered.first?.timestamp, let end = ordered.last?.timestamp else { continue }

            let externalId = "gpx-workout-\(source.id)-\(start.epochMillis)-\(index)"
            // §22.4-adjacent honesty: GPX's `<time>` is always the absolute UTC instant (the "Z"
            // suffix), but the file carries no LOCAL timezone for the workout — "GMT" is a real
            // reading of the instant, not a guess about where it happened, hence `.tzAssumed`
            // rather than a bare unflagged tz.
            workouts.append(WorkoutDTO(
                activityType: Self.activitySlug(fromTypeHint: track.typeHint),
                start: start, end: end, tz: "GMT", sourceId: source.id,
                externalId: externalId, sourceWorkoutUUID: externalId,
                totals: WorkoutTotals(distanceMeters: Self.totalDistanceMeters(ordered)),
                route: RouteDTO(externalId: externalId, points: ordered, consent: .denied),
                qualityFlags: [.tzAssumed]))
        }
        parsed.descriptors = workouts.isEmpty ? [] : [source]
        parsed.workouts = workouts
        parsed.recordsProcessed = recordsProcessed
        return parsed
    }

    /// A coarse, best-effort activity classification from a non-standard `<type>` hint — never
    /// silently mislabels: an unrecognized hint keeps its own text as evidence (mirrors
    /// `AppleHealthMapping.activitySlug`'s `other_<name>` fallback), and no hint at all is
    /// honestly "other", not a guess.
    private static func activitySlug(fromTypeHint hint: String?) -> String {
        guard let hint, !hint.isEmpty else { return "other" }
        let lowered = hint.lowercased()
        if lowered.contains("run") { return "running" }
        if lowered.contains("bik") || lowered.contains("cycl") { return "cycling" }
        if lowered.contains("walk") { return "walking" }
        if lowered.contains("hik") { return "hiking" }
        if lowered.contains("swim") { return "swimming" }
        let slug = lowered.map { ch -> Character in (ch.isLetter || ch.isNumber) ? ch : "_" }
        return "other_" + String(slug)
    }

    /// Sum of consecutive great-circle distances across the whole ordered trace. An honest
    /// geometric fact derivable from the points themselves — not present in GPX 1.1 as a field,
    /// unlike TCX's `<DistanceMeters>` or Apple Health's `totalDistance` attribute, so this is
    /// the only way a GPX-imported workout gets a distance total at all.
    private static func totalDistanceMeters(_ points: [RoutePointDTO]) -> Double? {
        guard points.count > 1 else { return nil }
        var sum = 0.0
        for i in 1..<points.count {
            sum += Self.haversineMeters(points[i - 1], points[i])
        }
        return sum
    }

    private static func haversineMeters(_ a: RoutePointDTO, _ b: RoutePointDTO) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
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
