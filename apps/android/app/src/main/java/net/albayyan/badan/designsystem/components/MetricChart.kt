package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Numerals
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.floor

/** How a [MetricChart] draws its series. */
enum class ChartStyle { Line, Bar }

/** Cached, derived scale/geometry for a [MetricChart] — only recomputed when inputs change. */
private data class ChartGeometry(
    val minV: Double,
    val vRange: Double,
    val minT: Long,
    val tRange: Long,
)

private fun computeGeometry(series: List<Pair<Long, Double>>, band: Pair<Double, Double>?): ChartGeometry {
    val values = series.map { it.second }
    val times = series.map { it.first }
    var minV = values.min()
    var maxV = values.max()
    if (band != null) {
        minV = minOf(minV, band.first)
        maxV = maxOf(maxV, band.second)
    }
    // Add a small headroom margin and guard the degenerate flat-series case.
    if (minV == maxV) {
        minV -= 1.0
        maxV += 1.0
    } else {
        val pad = (maxV - minV) * 0.08
        minV -= pad
        maxV += pad
    }
    val minT = times.min()
    val maxT = times.max()
    return ChartGeometry(
        minV = minV,
        vRange = maxV - minV,
        minT = minT,
        tRange = (maxT - minT).coerceAtLeast(1L),
    )
}

private fun formatAxisValue(v: Double, language: AppLanguage): String {
    val digits = if (v == floor(v)) 0 else 1
    return Numerals.format(v, language, arabicDigits = false, fractionDigits = digits)
}

private val noDataInPeriod = LocalizedString(en = "No data in this period", ar = "لا توجد بيانات في هذه الفترة")
private val chartSummaryTemplate = LocalizedString(
    en = "Trend chart, {count} points, ranging from {min} to {max}",
    ar = "مخطط اتجاه، {count} نقطة، يتراوح من {min} إلى {max}",
)
private val sparklineSummaryTemplate = LocalizedString(
    en = "Sparkline trend, from {min} to {max}",
    ar = "خط اتجاه مصغّر، من {min} إلى {max}",
)

/**
 * A calm time-series plot for a metric detail (mirror of iOS `MetricChart`), drawn with Compose
 * Canvas since no chart library is available. Renders a series as a smooth line or bars with an
 * optional shaded personal-band behind it, minimal date/value axis labels, and a tap/drag
 * inspection marker. The plot itself always stays visually LTR — time reads left-to-right even
 * when the surrounding chrome is mirrored for RTL, because Canvas coordinates are absolute
 * (x grows rightward) and are not mirrored by layout direction.
 *
 * @param series ordered (epoch-millis, value) points; assumed sorted ascending by time.
 * @param band optional (low, high) personal band drawn as a soft in-band tint behind the plot.
 * @param language used to localize axis/inspection labels; defaults to English for call sites
 *   that have not yet threaded the active [AppLanguage] through (see PERF-221/UIUX-213 notes).
 */
@Composable
fun MetricChart(
    series: List<Pair<Long, Double>>,
    style: ChartStyle = ChartStyle.Line,
    band: Pair<Double, Double>? = null,
    language: AppLanguage = AppLanguage.EN,
    modifier: Modifier = Modifier,
) {
    val colors = BadanTheme.colors
    val chartModifier = modifier
        .fillMaxWidth()
        .defaultMinSize(minHeight = 160.dp)

    if (series.isEmpty()) {
        Box(chartModifier, contentAlignment = Alignment.Center) {
            Text(
                text = noDataInPeriod.resolved(language),
                style = BadanType.caption,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
        return
    }

    val geometry = remember(series, style, band) { computeGeometry(series, band) }
    var selectedIndex by remember(series) { mutableStateOf<Int?>(null) }
    val dateFormatter = remember(language) {
        DateFormat.getDateInstance(DateFormat.SHORT, Locale.forLanguageTag(language.localeTag))
    }
    val axisPaint = remember { android.graphics.Paint().apply { isAntiAlias = true } }
    val summary = remember(series, language) {
        val minVal = series.minOf { it.second }
        val maxVal = series.maxOf { it.second }
        chartSummaryTemplate.filling(
            mapOf(
                "count" to series.size.toString(),
                "min" to formatAxisValue(minVal, language),
                "max" to formatAxisValue(maxVal, language),
            ),
        ).resolved(language)
    }

    Canvas(
        modifier = chartModifier
            .semantics { contentDescription = summary }
            .pointerInput(series) {
                detectTapGestures { offset ->
                    selectedIndex = nearestSeriesIndex(series, offset.x, size.width.toFloat(), geometry)
                }
            }
            .pointerInput(series) {
                detectDragGestures(
                    onDrag = { change, _ ->
                        selectedIndex = nearestSeriesIndex(series, change.position.x, size.width.toFloat(), geometry)
                    },
                )
            },
    ) {
        val w = size.width
        val h = size.height

        fun xFor(t: Long): Float = ((t - geometry.minT).toFloat() / geometry.tRange.toFloat()) * w
        fun yFor(v: Double): Float = (h - ((v - geometry.minV) / geometry.vRange).toFloat() * h)

        // Shaded personal band behind the plot — one soft in-band tint, never a good/bad zone.
        if (band != null) {
            val yHigh = yFor(band.second)
            val yLow = yFor(band.first)
            drawRect(
                color = colors.inBand.copy(alpha = 0.10f),
                topLeft = Offset(0f, yHigh),
                size = Size(w, (yLow - yHigh).coerceAtLeast(0f)),
            )
        }

        when (style) {
            ChartStyle.Line -> {
                val path = Path()
                series.forEachIndexed { index, (t, v) ->
                    val x = xFor(t)
                    val y = yFor(v)
                    if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
                }
                drawPath(
                    path = path,
                    color = colors.primary,
                    style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round),
                )
            }

            ChartStyle.Bar -> {
                val slot = w / series.size
                val barW = (slot * 0.6f).coerceAtLeast(2.dp.toPx())
                series.forEach { (t, v) ->
                    val cx = xFor(t)
                    val y = yFor(v)
                    val left = (cx - barW / 2f).coerceIn(0f, (w - barW).coerceAtLeast(0f))
                    drawRoundRect(
                        color = colors.primary.copy(alpha = 0.85f),
                        topLeft = Offset(left, y),
                        size = Size(barW, (h - y).coerceAtLeast(0f)),
                        cornerRadius = CornerRadius(barW * 0.18f, barW * 0.18f),
                    )
                }
            }
        }

        // Minimal axis labels — min/max value on the y-axis, first/last date on the x-axis.
        val nativeCanvas = drawContext.canvas.nativeCanvas
        axisPaint.color = colors.textSecondary.toArgb()
        axisPaint.textSize = 11.sp.toPx()
        val maxValueLabel = formatAxisValue(geometry.minV + geometry.vRange, language)
        val minValueLabel = formatAxisValue(geometry.minV, language)
        val firstDateLabel = dateFormatter.format(Date(geometry.minT))
        val lastDateLabel = dateFormatter.format(Date(geometry.minT + geometry.tRange))
        nativeCanvas.drawText(maxValueLabel, 4.dp.toPx(), axisPaint.textSize + 2.dp.toPx(), axisPaint)
        nativeCanvas.drawText(minValueLabel, 4.dp.toPx(), h - 18.dp.toPx(), axisPaint)
        nativeCanvas.drawText(firstDateLabel, 4.dp.toPx(), h - 4.dp.toPx(), axisPaint)
        val lastWidth = axisPaint.measureText(lastDateLabel)
        nativeCanvas.drawText(lastDateLabel, w - lastWidth - 4.dp.toPx(), h - 4.dp.toPx(), axisPaint)

        // Tap/drag inspection — nearest-point marker with a floating value/date label.
        selectedIndex?.let { idx ->
            val (t, v) = series[idx]
            val cx = xFor(t)
            val cy = yFor(v)
            drawCircle(color = colors.primary, radius = 5.dp.toPx(), center = Offset(cx, cy))
            drawCircle(color = colors.surface, radius = 2.dp.toPx(), center = Offset(cx, cy))
            val label = "${formatAxisValue(v, language)}  ${dateFormatter.format(Date(t))}"
            axisPaint.color = colors.textPrimary.toArgb()
            val labelWidth = axisPaint.measureText(label)
            val lx = (cx - labelWidth / 2f).coerceIn(4.dp.toPx(), (w - labelWidth - 4.dp.toPx()).coerceAtLeast(4.dp.toPx()))
            val ly = (cy - 12.dp.toPx()).coerceAtLeast(axisPaint.textSize + 2.dp.toPx())
            nativeCanvas.drawText(label, lx, ly, axisPaint)
        }
    }
}

/** Finds the series index whose plotted x-position is nearest to [touchX]. */
private fun nearestSeriesIndex(
    series: List<Pair<Long, Double>>,
    touchX: Float,
    canvasWidth: Float,
    geometry: ChartGeometry,
): Int? {
    if (series.isEmpty() || canvasWidth <= 0f) return null
    return series.indices.minByOrNull { i ->
        val x = ((series[i].first - geometry.minT).toFloat() / geometry.tRange.toFloat()) * canvasWidth
        abs(x - touchX)
    }
}

/**
 * A compact, axis-less line for cards (mirror of iOS `MetricSparkline`) — just the shape of the
 * recent trend. Also stays visually LTR.
 */
@Composable
fun MetricSparkline(values: List<Double>, language: AppLanguage = AppLanguage.EN, modifier: Modifier = Modifier) {
    val colors = BadanTheme.colors
    val sparkModifier = modifier
        .fillMaxWidth()
        .defaultMinSize(minHeight = 28.dp)

    val range = remember(values) {
        if (values.size < 2) {
            null
        } else {
            val minV = values.min()
            val maxV = values.max()
            minV to (maxV - minV).let { if (it == 0.0) 1.0 else it }
        }
    }
    val summary = remember(values, language) {
        if (values.size < 2) {
            null
        } else {
            sparklineSummaryTemplate.filling(
                mapOf(
                    "min" to formatAxisValue(values.min(), language),
                    "max" to formatAxisValue(values.max(), language),
                ),
            ).resolved(language)
        }
    }

    Canvas(
        modifier = sparkModifier.let { base ->
            if (summary != null) base.semantics { contentDescription = summary } else base
        },
    ) {
        if (values.size < 2 || range == null) return@Canvas
        val (minV, r) = range
        val w = size.width
        val h = size.height

        val path = Path()
        values.forEachIndexed { index, v ->
            val x = index.toFloat() / (values.size - 1).toFloat() * w
            val y = h - ((v - minV) / r).toFloat() * h
            if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(
            path = path,
            color = colors.primary,
            style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round),
        )
    }
}
