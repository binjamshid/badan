import CoreLocation
import MapKit
import SwiftUI

/// A workout's GPS trace, drawn two ways (EPIC-03 task 5: "map preview via MapKit — offline
/// tolerant"; §9.2 performance line: "map preview lazy").
///
/// **Why the default preview is not a map.** `MKMapView` fetches its tiles over the network. With
/// no connection it renders an empty grid, and the trace — the only part of this that is actually
/// the user's data — sits on a blank rectangle that reads as a broken screen. So the default is a
/// plain vector polyline drawn from the stored points by `RouteTraceShape`: no network, no
/// framework, no async, correct on a plane. Tapping "Show on map" mounts the real `Map` on
/// demand, which is also what makes the preview lazy in the sense §9.2 asks for — a workout
/// detail screen that never opens the map never pays for MapKit at all.
///
/// **The shape is the honest fallback, not a degraded one.** It shows the same coordinates at the
/// same relative positions; what it lacks is the streets underneath. For "what did that run look
/// like", it answers the question by itself.
struct WorkoutRoutePreview: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let points: [RoutePoint]
    /// Total points stored, which can exceed `points.count` if a caller ever pre-downsamples.
    /// Shown at power altitude as a provenance fact about the trace.
    let storedPointCount: Int

    @State private var showsMap = false

    private static let traceHeight: CGFloat = 180

    private static let header = LocalizedString(en: "Route", ar: "المسار")
    private static let showOnMap = LocalizedString(en: "Show on map", ar: "عرض على الخريطة")
    private static let hideMap = LocalizedString(en: "Hide map", ar: "إخفاء الخريطة")
    private static let offlineNote = LocalizedString(
        en: "The map background needs a connection. Your route is drawn from what's stored on this device either way.",
        ar: "تحتاج خلفية الخريطة إلى اتصال. أما مسارك فيُرسم مما هو محفوظ على هذا الجهاز في الحالتين.")
    private static let pointsLabel = LocalizedString(en: "{n} recorded points", ar: "{n} نقطة مسجّلة")
    private static let traceAccessibility = LocalizedString(
        en: "Route shape from {n} recorded points. Distance and duration are listed above.",
        ar: "شكل المسار من {n} نقطة مسجّلة. المسافة والمدة مذكورتان أعلاه.")
    private static let tooFewPoints = LocalizedString(
        en: "This route has too few points to draw.",
        ar: "هذا المسار يحتوي على نقاط أقل من أن تُرسم.")

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(Self.header, language: env.language) {
                    if drawable.count >= 2 {
                        Button {
                            withAnimation(BadanMotion.easeInOut(BadanMotion.standard, reduceMotion: reduceMotion)) {
                                showsMap.toggle()
                            }
                        } label: {
                            Text(env.s(showsMap ? Self.hideMap : Self.showOnMap))
                                .font(BadanFont.link)
                                .foregroundStyle(BadanColor.primary)
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: BadanSpace.touchMin)
                    }
                }

                if drawable.count < 2 {
                    Text(env.s(Self.tooFewPoints))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                } else if showsMap {
                    mapView
                    Text(env.s(Self.offlineNote))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    traceView
                }

                if env.depth.showsPowerDetail {
                    Text(env.s(Self.pointsLabel.filling(["n": env.format.integer(storedPointCount)])))
                        .font(BadanFont.caption.monospacedDigit())
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }

    // MARK: - Offline trace

    private var traceView: some View {
        RouteTraceShape(coordinates: drawable)
            .stroke(BadanColor.primary,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .frame(height: Self.traceHeight)
            .frame(maxWidth: .infinity)
            .padding(BadanSpace.space2)
            .background(BadanColor.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            // A polyline conveys nothing to VoiceOver, and there is no honest way to narrate a
            // shape. Point it at the numbers that ARE readable rather than leaving an unlabeled
            // element in the rotor — matching how `MetricSparkline` is hidden in favour of the
            // `StatBox` beside it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(env.s(Self.traceAccessibility.filling([
                "n": env.format.integer(storedPointCount)
            ])))
    }

    // MARK: - Map

    /// Mounted only while `showsMap` — see the type doc.
    ///
    /// `interactionModes: []` and no user-location content on purpose: this is a picture of a
    /// finished route, and a map that could recentre on the user's current position would be the
    /// one place in this feature that touches live location, which the route-consent copy
    /// promises never happens.
    private var mapView: some View {
        Map(initialPosition: .rect(boundingRect), interactionModes: []) {
            MapPolyline(coordinates: drawable)
                .stroke(BadanColor.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .frame(height: Self.traceHeight)
        .clipShape(RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(env.s(Self.traceAccessibility.filling([
            "n": env.format.integer(storedPointCount)
        ])))
    }

    /// The region the trace occupies, padded so the line never runs along the frame edge.
    /// Built from the points themselves rather than from a centre+span guess so a 200 m lap and a
    /// 90 km ride both fill the frame.
    private var boundingRect: MKMapRect {
        drawable.reduce(MKMapRect.null) { rect, coordinate in
            let point = MKMapPoint(coordinate)
            return rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        .insetBy(dx: -boundingInset, dy: -boundingInset)
    }

    /// Padding in map points, scaled off the trace's own extent so it is proportional at every
    /// zoom. A flat inset would swallow a short route and be invisible on a long one.
    private var boundingInset: Double {
        let rect = drawable.reduce(MKMapRect.null) { rect, coordinate in
            let point = MKMapPoint(coordinate)
            return rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        // A perfectly straight north-south route has zero width; fall back to the other axis so
        // the inset never collapses to nothing.
        return max(rect.size.width, rect.size.height, 1) * 0.12
    }

    /// The coordinates actually drawn, downsampled.
    ///
    /// `RouteRepository.points` returns the whole trace unpaged by design, and a long ride can
    /// pass 10,000 fixes. Stroking 10,000 segments into a 180pt-tall frame draws several points
    /// per pixel — invisible detail at real cost on every layout pass. `maxDrawnPoints` keeps the
    /// visible shape identical while bounding the work.
    private var drawable: [CLLocationCoordinate2D] {
        RouteTraceShape.downsample(points, limit: Self.maxDrawnPoints)
    }

    /// ~800 segments is more than a phone-width frame can resolve and cheap to stroke.
    private static let maxDrawnPoints = 800
}

/// The vector polyline behind the offline preview: latitude/longitude normalized into the view's
/// own frame.
///
/// Uses a flat equirectangular projection (longitude scaled by cos(latitude)) rather than the
/// Web-Mercator maths `MKMapPoint` applies. Over a single workout — tens of kilometres at most —
/// the two are visually indistinguishable, and this one needs no framework, no `MKMapPoint`
/// conversion per fix, and no map projection to reason about. The shape is a preview of a path,
/// not a navigational artifact.
struct RouteTraceShape: Shape {
    var coordinates: [CLLocationCoordinate2D]

    nonisolated func path(in rect: CGRect) -> Path {
        guard coordinates.count >= 2 else { return Path() }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else { return Path() }

        // Longitude degrees narrow toward the poles; without this a route in Muscat or Oslo would
        // render stretched sideways compared to the same route near the equator.
        let midLatRadians = ((minLat + maxLat) / 2) * .pi / 180
        let lonScale = max(cos(midLatRadians), 0.01)

        let spanX = max((maxLon - minLon) * lonScale, .ulpOfOne)
        let spanY = max(maxLat - minLat, .ulpOfOne)
        // One scale for both axes so the route keeps its real aspect ratio — independently
        // fitting each axis would turn a long straight out-and-back into a square scribble.
        let scale = min(rect.width / spanX, rect.height / spanY)
        let drawnWidth = spanX * scale
        let drawnHeight = spanY * scale
        let originX = rect.minX + (rect.width - drawnWidth) / 2
        let originY = rect.minY + (rect.height - drawnHeight) / 2

        func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            let x = originX + (coordinate.longitude - minLon) * lonScale * scale
            // Latitude increases northward, screen y increases downward.
            let y = originY + (maxLat - coordinate.latitude) * scale
            return CGPoint(x: x, y: y)
        }

        var path = Path()
        path.move(to: project(coordinates[0]))
        for coordinate in coordinates.dropFirst() {
            path.addLine(to: project(coordinate))
        }
        return path
    }

    /// Evenly-strided downsample that always keeps the first and last fix, so the drawn trace
    /// starts and ends exactly where the recorded one did. Striding (rather than, say,
    /// Douglas–Peucker simplification) is deliberate: it is O(n), allocation-light, and cannot
    /// reshape the route, which a tolerance-based simplifier can when the tolerance is wrong.
    static func downsample(_ points: [RoutePoint], limit: Int) -> [CLLocationCoordinate2D] {
        guard limit > 1 else { return [] }
        guard points.count > limit else {
            return points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        let stride = Double(points.count - 1) / Double(limit - 1)
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(limit)
        for index in 0..<limit {
            let source = points[min(Int((Double(index) * stride).rounded()), points.count - 1)]
            out.append(CLLocationCoordinate2D(latitude: source.latitude, longitude: source.longitude))
        }
        return out
    }
}
