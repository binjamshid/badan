import SwiftUI
import Charts

/// A calm time-series plot for a metric detail. Renders a series as a line or bars with an
/// optional shaded personal-band behind it and minimal axes. The plot itself always stays
/// LTR — time reads left-to-right even when the surrounding chrome is mirrored for RTL.
struct MetricChart: View {
    enum Style { case line, bar }

    /// Internal plottable point (tuple series map to this so we stay `Identifiable`).
    struct Point: Identifiable {
        var date: Date
        var value: Double
        var id: Double { date.timeIntervalSince1970 }
        init(date: Date, value: Double) { self.date = date; self.value = value }
    }

    var points: [Point]
    var style: Style
    var band: (low: Double, high: Double)?

    init(series: [(date: Date, value: Double)], style: Style = .line, band: (low: Double, high: Double)? = nil) {
        self.points = series.map { Point(date: $0.date, value: $0.value) }
        self.style = style
        self.band = band
    }

    var body: some View {
        Chart {
            if let band, let first = points.first?.date, let last = points.last?.date {
                RectangleMark(
                    xStart: .value("Start", first),
                    xEnd: .value("End", last),
                    yStart: .value("Low", band.low),
                    yEnd: .value("High", band.high)
                )
                .foregroundStyle(BadanColor.inBand.opacity(0.10))
            }
            ForEach(points) { point in
                switch style {
                case .line:
                    LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(BadanColor.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                case .bar:
                    BarMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .foregroundStyle(BadanColor.primary.opacity(0.85))
                        .cornerRadius(BadanRadius.chip / 2)
                }
            }
        }
        .chartXAxis {
            AxisMarks(position: .bottom) { _ in
                AxisGridLine().foregroundStyle(BadanColor.separator.opacity(0.5))
                AxisValueLabel()
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(BadanColor.separator.opacity(0.5))
                AxisValueLabel()
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
        .chartLegend(.hidden)
        // Time axis stays LTR even inside an RTL screen.
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// A compact, axis-less line for cards — just the shape of the recent trend.
struct MetricSparkline: View {
    var values: [Double]
    var tint: Color

    init(values: [Double], tint: Color = BadanColor.primary) {
        self.values = values
        self.tint = tint
    }

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            LineMark(x: .value("Index", index), y: .value("Value", value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .environment(\.layoutDirection, .leftToRight)
    }
}
