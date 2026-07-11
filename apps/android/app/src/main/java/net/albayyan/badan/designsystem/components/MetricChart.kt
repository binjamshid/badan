package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import net.albayyan.badan.designsystem.BadanTheme

/** How a [MetricChart] draws its series. */
enum class ChartStyle { Line, Bar }

/**
 * A calm time-series plot for a metric detail (mirror of iOS `MetricChart`), drawn with Compose
 * Canvas since no chart library is available. Renders a series as a smooth line or bars with an
 * optional shaded personal-band behind it. The plot itself always stays visually LTR — time
 * reads left-to-right even when the surrounding chrome is mirrored for RTL, because Canvas
 * coordinates are absolute (x grows rightward) and are not mirrored by layout direction.
 *
 * @param series ordered (epoch-millis, value) points; assumed sorted ascending by time.
 * @param band optional (low, high) personal band drawn as a soft in-band tint behind the plot.
 */
@Composable
fun MetricChart(
    series: List<Pair<Long, Double>>,
    style: ChartStyle = ChartStyle.Line,
    band: Pair<Double, Double>? = null,
    modifier: Modifier = Modifier,
) {
    val colors = BadanTheme.colors
    val chartModifier = modifier
        .fillMaxWidth()
        .defaultMinSize(minHeight = 160.dp)

    if (series.isEmpty()) {
        Canvas(modifier = chartModifier) {}
        return
    }

    val values = series.map { it.second }
    val times = series.map { it.first }
    val bandLow = band?.first
    val bandHigh = band?.second

    var minV = values.min()
    var maxV = values.max()
    if (bandLow != null) minV = minOf(minV, bandLow)
    if (bandHigh != null) maxV = maxOf(maxV, bandHigh)
    // Add a small headroom margin and guard the degenerate flat-series case.
    if (minV == maxV) {
        minV -= 1.0
        maxV += 1.0
    } else {
        val pad = (maxV - minV) * 0.08
        minV -= pad
        maxV += pad
    }
    val vRange = maxV - minV

    val minT = times.min()
    val maxT = times.max()
    val tRange = (maxT - minT).coerceAtLeast(1L)

    Canvas(modifier = chartModifier) {
        val w = size.width
        val h = size.height

        fun xFor(t: Long): Float = ((t - minT).toFloat() / tRange.toFloat()) * w
        fun yFor(v: Double): Float = (h - ((v - minV) / vRange).toFloat() * h)

        // Shaded personal band behind the plot — one soft in-band tint, never a good/bad zone.
        if (bandLow != null && bandHigh != null) {
            val yHigh = yFor(bandHigh)
            val yLow = yFor(bandLow)
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
                val barW = slot * 0.6f
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
    }
}

/**
 * A compact, axis-less line for cards (mirror of iOS `MetricSparkline`) — just the shape of the
 * recent trend. Also stays visually LTR.
 */
@Composable
fun MetricSparkline(values: List<Double>, modifier: Modifier = Modifier) {
    val colors = BadanTheme.colors
    val sparkModifier = modifier
        .fillMaxWidth()
        .defaultMinSize(minHeight = 28.dp)

    Canvas(modifier = sparkModifier) {
        if (values.size < 2) return@Canvas
        val minV = values.min()
        val maxV = values.max()
        val range = (maxV - minV).let { if (it == 0.0) 1.0 else it }
        val w = size.width
        val h = size.height

        val path = Path()
        values.forEachIndexed { index, v ->
            val x = index.toFloat() / (values.size - 1).toFloat() * w
            val y = h - ((v - minV) / range).toFloat() * h
            if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(
            path = path,
            color = colors.primary,
            style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round),
        )
    }
}
