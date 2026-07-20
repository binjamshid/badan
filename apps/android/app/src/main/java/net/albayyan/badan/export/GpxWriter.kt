package net.albayyan.badan.export

import net.albayyan.badan.domain.RoutePoint
import java.security.MessageDigest
import kotlin.math.abs

/**
 * EPIC-12: renders a workout's stored GPS trace as GPX 1.1 (plan §22.4). Mirror of iOS
 * `GPXWriter`; the two must produce byte-identical documents for the same input.
 *
 * GPX is the one format BADAN writes that is **not** BADAN's contract. `csv_columns.json` and
 * `json_bundle.schema.json` are ours to version; GPX 1.1 belongs to topografix, and Strava,
 * Garmin Connect and every map tool the user might open the file in read *that* schema. Two
 * consequences run through this whole file and are easy to "fix" back into breakage:
 *
 * 1. **Timestamps are UTC with a `Z`, not a numeric offset.** §22.1's numeric-offset rule
 *    (`+00:00`, never `Z`) governs BADAN's own formats so CSV, the JSON bundle and the manifest
 *    cannot drift apart. GPX's `xsd:dateTime` accepts both spellings, but every GPX file in the
 *    wild is UTC-`Z`, and route points have no per-point timezone to carry an offset from in the
 *    first place (`route_points` deliberately has no `tz_id` — see migration v4). Rendering these
 *    through `TimestampFormatting` to satisfy a rule about a different contract would make the
 *    file more BADAN-consistent and less useful to the person exporting it.
 * 2. **Element order inside `<metadata>`, `<trk>` and `<trkpt>` is fixed by the schema**, not by
 *    taste. GPX 1.1 declares them as `xsd:sequence`, so a validating consumer rejects a file that
 *    puts `<time>` before `<name>`. The emit order below is the schema's order.
 *
 * ## The two gates
 *
 * Routes are the only location data BADAN holds, and they sit behind **two independent
 * permissions**, not one:
 *
 * - **Route ingestion consent** — what allowed the rows to be captured at all. Enforced upstream
 *   in `HealthConnectAdapter`; frozen per-route into `workout_routes.consent_snapshot`.
 * - **Route export consent** — this file's gate. A separate, current-state toggle answering "may
 *   these coordinates leave the device" (plan §4.11: each sensitive class gets its own consent
 *   toggle *and* its own export opt-in).
 *
 * The snapshot is deliberately NOT consulted here. It records history; export asks a question
 * about now. A user who granted ingestion last year and has since turned export off must get
 * nothing, and a user who turned ingestion off keeps the right to export what was already
 * collected — neither is reachable if the two gates are conflated.
 *
 * GPX never appears in Quick Export; that exclusion is structural (`QuickExportPreset` hardcodes a
 * raw/derived-only scope with no route knob).
 */

/** GPX export failures. Distinct cases so a caller reports the honest reason, not a generic error. */
sealed class GpxExportException(message: String) : Exception(message) {
    /** The route-export toggle is off. Distinct from ingestion consent — see [GpxWriter]. */
    object RouteExportNotEnabled : GpxExportException("route export toggle is off")

    /**
     * The confirmation describes a different set of routes than the one being written. Almost
     * always means routes were added, deleted or re-ingested between the confirmation sheet and the
     * write; the user agreed to a count and a span that are no longer true.
     */
    class ConfirmationStale(val acknowledged: String, val actual: String) :
        GpxExportException("route export confirmation is stale")

    /**
     * A workout was handed in with no usable points. Surfaced rather than skipped so an empty GPX
     * file never lands in a bundle that claims a route count.
     */
    class EmptyRoute(val workoutId: String) : GpxExportException("workout $workoutId has no route points")
}

/**
 * One GPS trace off `RouteRepository` — a `workout_routes` row's identity plus its ordered points.
 * [routeId] never appears in the output but is carried so a segmentation diagnostic can name the
 * route a break came from.
 */
data class GpxRoute(val routeId: String, val points: List<RoutePoint>)

/**
 * One workout and every trace attached to it. A `<trk>` is per **workout**, not per route (§22.4),
 * so a session that stored several `workout_routes` rows produces one file with one track — which
 * is also what resolves the naming collision, since `route_<workout-ulid>.gpx` is keyed on the
 * session and a session may own more than one route.
 */
data class GpxWorkout(
    /** `sessions.id` — the workout ULID that names the file (I8). */
    val workoutId: String,
    /** `<trk><name>`; free text, XML-escaped on the way out. */
    val name: String,
    val routes: List<GpxRoute>,
)

/**
 * What the user is shown before a byte of location data is written: how many routes, from how many
 * workouts, over what span. A value type rather than a UI string because the confirmation has to
 * be *checkable* — [GpxWriter.artifacts] recomputes the plan from the workouts it is about to
 * write and refuses if it does not match what the user acknowledged.
 */
data class RouteExportPlan(
    val workoutCount: Int,
    val routeCount: Int,
    val pointCount: Int,
    /** Earliest / latest point timestamps (epoch millis) across every route; null when empty. */
    val earliest: Long?,
    val latest: Long?,
) {
    /**
     * Stable digest of everything the confirmation states, plus the workout ids behind it. Ids are
     * included so one route cannot be swapped for another of the same vintage without changing the
     * fingerprint. Sorted, so the digest describes the *set* being exported rather than the order a
     * caller assembled it in.
     *
     * This digest is internal to one platform (it gates a confirmation against a write on the same
     * device); it does not need cross-platform parity, only stability within a run.
     */
    fun fingerprint(workouts: List<GpxWorkout>): String {
        val parts = mutableListOf(
            "v1", workoutCount.toString(), routeCount.toString(), pointCount.toString(),
            earliest?.let { (it / 1000).toString() } ?: "-",
            latest?.let { (it / 1000).toString() } ?: "-",
        )
        parts += workouts.map { it.workoutId }.sorted()
        val digest = MessageDigest.getInstance("SHA-256").digest(parts.joinToString("").toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    companion object {
        /** Derives the plan from the exact workout list that will be written. */
        fun make(workouts: List<GpxWorkout>): RouteExportPlan {
            val allTimestamps = workouts.flatMap { w -> w.routes.flatMap { it.points } }.map { it.timestamp }
            return RouteExportPlan(
                workoutCount = workouts.size,
                routeCount = workouts.sumOf { it.routes.size },
                pointCount = allTimestamps.size,
                earliest = allTimestamps.minOrNull(),
                latest = allTimestamps.maxOrNull(),
            )
        }
    }
}

/**
 * Proof that a specific [RouteExportPlan] was put in front of the user and accepted. The only way
 * to obtain one is to build a plan from real workouts and acknowledge *that* — a caller cannot
 * fabricate a confirmation without first computing the thing it is supposed to have shown.
 */
class RouteExportConfirmation(plan: RouteExportPlan, workouts: List<GpxWorkout>) {
    internal val fingerprint: String = plan.fingerprint(workouts)
}

/**
 * Renders [GpxWorkout]s to GPX 1.1 documents. One instance per export run carries the run's
 * generation timestamp so every file in a bundle agrees on it.
 */
class GpxWriter(
    private val appVersion: String,
    /** Generation instant, epoch millis. Rendered UTC into `<metadata><time>`. */
    private val generatedAtMillis: Long,
) {
    /** One rendered file: its name inside the bundle and its bytes. */
    data class Artifact(val fileName: String, val gpx: String)

    /**
     * Renders every workout's trace after checking both gates. The toggle is tested before the
     * confirmation so a build with the feature off reports the honest reason rather than a
     * fingerprint mismatch that sends someone debugging the wrong thing.
     */
    fun artifacts(
        workouts: List<GpxWorkout>,
        routeExportEnabled: Boolean,
        confirmation: RouteExportConfirmation,
    ): List<Artifact> {
        if (!routeExportEnabled) throw GpxExportException.RouteExportNotEnabled

        val actual = RouteExportPlan.make(workouts).fingerprint(workouts)
        if (confirmation.fingerprint != actual) {
            throw GpxExportException.ConfirmationStale(confirmation.fingerprint, actual)
        }

        return workouts.map { workout ->
            if (workout.routes.none { it.points.isNotEmpty() }) {
                throw GpxExportException.EmptyRoute(workout.workoutId)
            }
            Artifact(fileName(workout.workoutId), render(workout))
        }
    }

    /**
     * The GPX document for one workout. Line endings are LF with a trailing newline — XML
     * convention, deliberately not the CRLF the CSV contract mandates (RFC 4180 governs CSV and
     * nothing else).
     */
    fun render(workout: GpxWorkout): String {
        val out = StringBuilder()
        out.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        out.append("<gpx version=\"1.1\" creator=\"BADAN/").append(xmlEscape(appVersion)).append('"')
        out.append(" xmlns=\"http://www.topografix.com/GPX/1/1\"")
        out.append(" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"")
        out.append(" xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1")
        out.append(" http://www.topografix.com/GPX/1/1/gpx.xsd\">\n")

        out.append("  <metadata>\n")
        out.append("    <name>BADAN workout route export</name>\n")
        out.append("    <desc>BADAN ").append(xmlEscape(appVersion))
            .append(" · export schema ").append(ExportSchema.VERSION).append("</desc>\n")
        out.append("    <time>").append(gpxTime(generatedAtMillis)).append("</time>\n")
        out.append("  </metadata>\n")

        out.append("  <trk>\n")
        out.append("    <name>").append(xmlEscape(workout.name)).append("</name>\n")
        for (segment in segments(workout)) {
            out.append("    <trkseg>\n")
            for (point in segment) {
                out.append("      <trkpt lat=\"").append(coordinate(point.lat)).append('"')
                out.append(" lon=\"").append(coordinate(point.lon)).append("\">\n")
                point.altitudeM?.let { out.append("        <ele>").append(elevation(it)).append("</ele>\n") }
                out.append("        <time>").append(gpxTime(point.timestamp)).append("</time>\n")
                out.append("      </trkpt>\n")
            }
            out.append("    </trkseg>\n")
        }
        out.append("  </trk>\n")
        out.append("</gpx>\n")
        return out.toString()
    }

    companion object {
        /**
         * The gap between consecutive fixes that ends a `<trkseg>` (§22.4: "route gaps >60s split
         * segments"). **Strictly** greater — a fix exactly 60s after its predecessor stays in the
         * same segment, which keeps a 1-per-minute sampling cadence from producing one segment per
         * point. A `<trkseg>` asserts continuity (consumers draw a line between consecutive points),
         * so a pause left un-split renders as a straight line across ground never travelled.
         */
        const val SEGMENT_GAP_MILLIS: Long = 60_000

        /** §22.4: `route_<workout-ulid>.gpx`, referenced from the workout object via `route_ref`. */
        fun fileName(workoutId: String): String = "route_$workoutId.gpx"

        /**
         * Splits a workout's points into continuous segments. Two things end a segment: a gap of
         * more than [SEGMENT_GAP_MILLIS] between consecutive fixes (§22.4), and a **route
         * boundary** — two `workout_routes` rows are two separately-captured traces, and joining
         * them into one `<trkseg>` would assert a continuity the data does not support even if
         * their timestamps abut.
         *
         * Routes are ordered by their first point so an out-of-order caller still gets a
         * chronological track; points inside a route are re-sorted by timestamp defensively (a
         * backwards route would otherwise produce one bogus break per inversion).
         */
        fun segments(workout: GpxWorkout): List<List<RoutePoint>> {
            val routes = workout.routes
                .map { route -> route.points.sortedBy { it.timestamp } }
                .filter { it.isNotEmpty() }
                .sortedBy { it.first().timestamp }

            val segments = mutableListOf<List<RoutePoint>>()
            for (points in routes) {
                var current = mutableListOf<RoutePoint>()
                for (point in points) {
                    val previous = current.lastOrNull()
                    if (previous != null && point.timestamp - previous.timestamp > SEGMENT_GAP_MILLIS) {
                        segments.add(current)
                        current = mutableListOf()
                    }
                    current.add(point)
                }
                if (current.isNotEmpty()) segments.add(current)
            }
            return segments
        }

        /**
         * Latitude/longitude at a fixed seven decimal places (~1.1 cm). Fixed width, not trimmed:
         * `CsvWriter.decimal` would render a whole-degree coordinate as `25` and its trailing-zero
         * trimming is one more thing to match across platforms.
         *
         * Rounding is done in integer space, not with `String.format("%.7f")`, because the JVM's
         * `String.format` rounds half-up on the exact decimal expansion while C's `printf` (iOS)
         * rounds half-to-even on the exact binary value; they disagree on dyadic rationals like
         * `25.00390625`, which is exactly the sort of value a synthetic fixture coordinate lands
         * on. Doing the multiply-and-round explicitly makes both platforms run the same two
         * IEEE-754 operations. See iOS `GPXWriter.coordinate`.
         */
        fun coordinate(value: Double): String = fixedPoint(value, 7)

        /** Elevation at one decimal place — decimetres, already finer than a barometric altimeter. */
        fun elevation(value: Double): String = fixedPoint(value, 1)

        /**
         * Fixed-point decimal rendering with half-away-from-zero rounding, built from integer parts
         * so no locale, no `%f` implementation and no trailing-zero policy can differ across
         * platforms.
         */
        private fun fixedPoint(value: Double, decimals: Int): String {
            var scale = 1.0
            repeat(decimals) { scale *= 10 }
            val scaled = value * scale
            // Half away from zero, spelled out rather than delegated: `Math.round` rounds half
            // toward positive infinity (-2.5 -> -2), and southern/western coordinates are negative.
            val magnitude = Math.floor(abs(scaled) + 0.5).toLong()
            val divisor = scale.toLong()
            val whole = magnitude / divisor
            val fraction = magnitude % divisor
            var fractionText = fraction.toString()
            while (fractionText.length < decimals) fractionText = "0$fractionText"
            // Sign from the input, not from `whole`: -0.0000001 has a whole part of 0 and still
            // belongs south of the equator.
            val negative = scaled < 0 && magnitude != 0L
            return "${if (negative) "-" else ""}$whole.$fractionText"
        }

        /**
         * GPX `xsd:dateTime`: UTC, second precision, `Z`. Sub-second precision is dropped — GNSS
         * fixes arrive at 1 Hz and carrying millis only here would give the format its own
         * rendering rule for no reader's benefit. Two fixes in one second share a `<time>`; their
         * order is preserved by their order in the file, which is what a `<trkseg>` means.
         *
         * Civil-time arithmetic from the epoch rather than a `SimpleDateFormat`: this is the one
         * timestamp in the codebase that must be UTC and end in `Z`, and the shared formatter would
         * have to be configured differently or taught a second shape. `CivilTime` is the standard
         * Howard Hinnant civil-from-days algorithm and matches iOS `GPXWriter.gpxTime` bit for bit.
         */
        fun gpxTime(epochMillis: Long): String {
            val seconds = Math.floorDiv(epochMillis, 1000L)
            val time = CivilTime.fromEpochSeconds(seconds)
            fun pad(value: Long, width: Int): String {
                var text = value.toString()
                while (text.length < width) text = "0$text"
                return text
            }
            return "${pad(time.year, 4)}-${pad(time.month, 2)}-${pad(time.day, 2)}T" +
                "${pad(time.hour, 2)}:${pad(time.minute, 2)}:${pad(time.second, 2)}Z"
        }

        /**
         * XML text escaping for the free-text fields (`creator`, `<name>`). Covers the five
         * predefined entities; `"` and `'` matter because `creator` is an attribute value.
         */
        fun xmlEscape(text: String): String {
            val out = StringBuilder(text.length)
            for (c in text) {
                when (c) {
                    '&' -> out.append("&amp;")
                    '<' -> out.append("&lt;")
                    '>' -> out.append("&gt;")
                    '"' -> out.append("&quot;")
                    '\'' -> out.append("&apos;")
                    else -> out.append(c)
                }
            }
            return out.toString()
        }
    }
}
