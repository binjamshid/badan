import SwiftUI
import Charts
import Accessibility

/// A calm time-series plot for a metric detail. Renders a series as a line or bars with an
/// optional shaded personal-band behind it and minimal axes. The plot itself always stays
/// LTR — time reads left-to-right even when the surrounding chrome is mirrored for RTL.
struct MetricChart: View {
    enum Style { case line, bar }

    /// Internal plottable point (tuple series map to this so we stay `Identifiable`).
    struct Point: Identifiable, Equatable {
        var date: Date
        var value: Double
        var id: Double { date.timeIntervalSince1970 }
        init(date: Date, value: Double) { self.date = date; self.value = value }
    }

    var points: [Point]
    var style: Style
    var band: (low: Double, high: Double)?
    /// Unit suffix shown alongside the Y-axis tick labels (e.g. "bpm"), so the chart still
    /// reads correctly if viewed away from the screen's header. Nil keeps axis numerals bare.
    var unit: String?
    var language: AppLanguage
    var arabicDigits: Bool

    /// Copy local to this component — kept self-contained rather than reaching into a
    /// shared strings file, matching how `ProvisionalBadge` keeps its own label.
    private enum Copy {
        static let noDataInRange = LocalizedString(
            en: "Not enough data in this range",
            ar: "لا توجد بيانات كافية في هذه الفترة")
        static let trendUp = LocalizedString(en: "trending up", ar: "في اتجاه تصاعدي")
        static let trendDown = LocalizedString(en: "trending down", ar: "في اتجاه تنازلي")
        static let trendSteady = LocalizedString(en: "steady", ar: "مستقر")
        static let withinRange = LocalizedString(en: "within your usual range", ar: "ضمن نطاقك المعتاد")
        static let aboveRange = LocalizedString(en: "above your usual range", ar: "أعلى من نطاقك المعتاد")
        static let belowRange = LocalizedString(en: "below your usual range", ar: "أقل من نطاقك المعتاد")
        static let latestValue = LocalizedString(en: "latest", ar: "آخر قيمة")
        static let outlierCaption = LocalizedString(
            en: "1 value outside range not shown to scale",
            ar: "قيمة واحدة خارج النطاق لم تُعرض بمقياسها الفعلي")
        static let outlierCaptionPlural = LocalizedString(
            en: "{n} values outside range not shown to scale",
            ar: "{n} قيم خارج النطاق لم تُعرض بمقياسها الفعلي")
    }

    /// - Parameters:
    ///   - language/arabicDigits: default to English/Western-digit so existing call sites
    ///     compile unchanged; callers should pass `env.language`/`env.profile.arabicDigits`
    ///     to get chart numerals matching the rest of the screen.
    init(
        series: [(date: Date, value: Double)],
        style: Style = .line,
        band: (low: Double, high: Double)? = nil,
        unit: String? = nil,
        language: AppLanguage = .en,
        arabicDigits: Bool = false
    ) {
        // Defend against NaN/infinite values reaching Charts' layout/scaling (OPT-096).
        self.points = series.filter { $0.value.isFinite }.map { Point(date: $0.date, value: $0.value) }
        self.style = style
        self.band = band
        self.unit = unit
        self.language = language
        self.arabicDigits = arabicDigits
    }

    /// Accepts pre-built points directly, for callers that already cache `[Point]` once per
    /// data load instead of remapping tuples on every render (PERF-049).
    init(
        points: [Point],
        style: Style = .line,
        band: (low: Double, high: Double)? = nil,
        unit: String? = nil,
        language: AppLanguage = .en,
        arabicDigits: Bool = false
    ) {
        self.points = points.filter { $0.value.isFinite }
        self.style = style
        self.band = band
        self.unit = unit
        self.language = language
        self.arabicDigits = arabicDigits
    }

    @State private var selectedDate: Date?

    var body: some View {
        if points.isEmpty {
            EmptyStateView(icon: "chart.xyaxis.line", title: Copy.noDataInRange.resolved(language), message: "")
        } else {
            chart
        }
    }

    // MARK: Chart

    private var chart: some View {
        Group {
            if let clampedDomain {
                unscaledChart.chartYScale(domain: clampedDomain)
            } else {
                unscaledChart
            }
        }
        .overlay(alignment: .top) { selectionCaption }
        .overlay(alignment: .bottomTrailing) { outlierCaption }
        // Time axis stays LTR even inside an RTL screen.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityChartDescriptor(
            ChartAccessibilityRepresentable(points: points, unit: unit, language: language, arabicDigits: arabicDigits)
        )
        .animation(.easeInOut(duration: 0.25), value: points)
    }

    private var unscaledChart: some View {
        Chart {
            if let band, let bandStart = points.first?.date, let bandEnd = bandEndDate {
                RectangleMark(
                    xStart: .value("Start", bandStart),
                    xEnd: .value("End", bandEnd),
                    yStart: .value("Low", band.low),
                    yEnd: .value("High", band.high)
                )
                .foregroundStyle(BadanColor.inBand.opacity(0.10))
                RuleMark(y: .value("Band low", band.low))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(BadanColor.inBand.opacity(0.35))
                RuleMark(y: .value("Band high", band.high))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(BadanColor.inBand.opacity(0.35))
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
            if let selectedDate, let selectedPoint = nearestPoint(to: selectedDate) {
                RuleMark(x: .value("Selected", selectedPoint.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(BadanColor.textSecondary.opacity(0.6))
                PointMark(x: .value("Selected", selectedPoint.date), y: .value("Value", selectedPoint.value))
                    .foregroundStyle(BadanColor.primary)
                    .symbolSize(50)
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
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(BadanColor.separator.opacity(0.5))
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(yAxisLabel(raw))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        // Tap-to-inspect: drag along the plot to see the nearest point's date + value.
        .chartXSelection(value: $selectedDate)
    }

    // A single point produces a zero-width `first == last` band rectangle that silently
    // renders nothing; widen it by a token day either side so a lone reading still shows its
    // personal-range context (OPT-095).
    private var bandEndDate: Date? {
        guard let first = points.first?.date, let last = points.last?.date else { return nil }
        if points.count == 1 { return first.addingTimeInterval(86_400) }
        return last
    }

    private func yAxisLabel(_ raw: Double) -> String {
        let number = Numerals.format(raw, language: language, arabicDigits: arabicDigits)
        guard let unit else { return number }
        return "\(number) \(unit)"
    }

    private func nearestPoint(to date: Date) -> Point? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    @ViewBuilder
    private var selectionCaption: some View {
        if let selectedDate, let point = nearestPoint(to: selectedDate) {
            Text("\(dateText(point.date)) · \(yAxisLabel(point.value))")
                .font(BadanFont.caption.monospacedDigit())
                .foregroundStyle(BadanColor.textPrimary)
                .padding(.horizontal, BadanSpace.space2)
                .padding(.vertical, BadanSpace.space1)
                .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                        .strokeBorder(BadanColor.separator, lineWidth: 1))
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: Outlier clamping (UIUX-088)
    //
    // Swift Charts auto-fits the Y axis to the true min/max of `points`; one erroneous or
    // extreme outlier can compress the rest of a long series into a near-flat line. When the
    // series shows a genuine outlier (Tukey's 1.5×IQR fence) we clamp the visible domain to
    // the non-outlier range (plus the personal band, so it never gets clipped) and surface a
    // small caption naming how many points sit outside it. Short series (<5 points) are left
    // to auto-scale, since a percentile isn't meaningful yet.
    private var clampedDomain: ClosedRange<Double>? {
        guard points.count >= 5 else { return nil }
        let values = points.map(\.value).sorted()
        guard let q1 = percentile(values, 0.25), let q3 = percentile(values, 0.75) else { return nil }
        let iqr = q3 - q1
        guard iqr > 0, let dataMin = values.first, let dataMax = values.last else { return nil }
        let lowerFence = q1 - 1.5 * iqr
        let upperFence = q3 + 1.5 * iqr
        guard dataMin < lowerFence || dataMax > upperFence else { return nil }
        var low = max(dataMin, lowerFence)
        var high = min(dataMax, upperFence)
        if let band {
            low = min(low, band.low)
            high = max(high, band.high)
        }
        guard low < high else { return nil }
        let pad = (high - low) * 0.1
        return (low - pad)...(high + pad)
    }

    private var outlierCount: Int {
        guard let clampedDomain else { return 0 }
        return points.filter { !clampedDomain.contains($0.value) }.count
    }

    @ViewBuilder
    private var outlierCaption: some View {
        if outlierCount > 0 {
            Text(outlierCaptionText)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .padding(.horizontal, BadanSpace.space1)
        }
    }

    private var outlierCaptionText: String {
        if outlierCount == 1 { return Copy.outlierCaption.resolved(language) }
        return Copy.outlierCaptionPlural.filling(["n": Numerals.format(outlierCount, language: language, arabicDigits: arabicDigits)]).resolved(language)
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lowerIndex = Int(rank.rounded(.down))
        let upperIndex = Int(rank.rounded(.up))
        if lowerIndex == upperIndex { return sorted[lowerIndex] }
        let weight = rank - Double(lowerIndex)
        return sorted[lowerIndex] * (1 - weight) + sorted[upperIndex] * weight
    }

    // MARK: Accessibility (FEAT-237)
    //
    // A synthesized spoken summary — trend direction, latest value, and personal-range
    // position — as a first VoiceOver-usable step for a component that previously exposed
    // nothing at all. `AXChartDescriptor` (below) adds the fuller audio-graph experience.
    private var accessibilitySummary: String {
        var parts: [String] = []
        if points.count >= 2, let first = points.first, let last = points.last, first.value != last.value {
            parts.append(last.value > first.value ? Copy.trendUp.resolved(language) : Copy.trendDown.resolved(language))
        } else if points.count >= 2 {
            parts.append(Copy.trendSteady.resolved(language))
        }
        if let last = points.last {
            parts.append("\(Copy.latestValue.resolved(language)) \(yAxisLabel(last.value))")
            if let band {
                if last.value < band.low { parts.append(Copy.belowRange.resolved(language)) }
                else if last.value > band.high { parts.append(Copy.aboveRange.resolved(language)) }
                else { parts.append(Copy.withinRange.resolved(language)) }
            }
        }
        return parts.joined(separator: ", ")
    }
}

/// `AXChartDescriptorRepresentable` for `MetricChart`, enabling iOS's native audio-graph
/// gesture (VoiceOver users can "hear" the trend shape, not just a spoken summary) (FEAT-240).
private struct ChartAccessibilityRepresentable: AXChartDescriptorRepresentable {
    var points: [MetricChart.Point]
    var unit: String?
    var language: AppLanguage
    var arabicDigits: Bool

    func makeChartDescriptor() -> AXChartDescriptor {
        let xValues = points.map { $0.date.timeIntervalSince1970 }
        let yValues = points.map(\.value)
        let xMin = xValues.min() ?? 0
        let xMax = xValues.max() ?? xMin + 1
        let yMin = yValues.min() ?? 0
        let yMax = yValues.max() ?? yMin + 1

        let xAxis = AXNumericDataAxisDescriptor(
            title: "Date",
            range: xMin...max(xMax, xMin + 1),
            gridlinePositions: []
        ) { [language] value in
            let formatter = DateFormatter()
            formatter.locale = language.locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: Date(timeIntervalSince1970: value))
        }

        let unit = self.unit
        let language = self.language
        let arabicDigits = self.arabicDigits
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Value",
            range: yMin...max(yMax, yMin + 1),
            gridlinePositions: []
        ) { value in
            let number = Numerals.format(value, language: language, arabicDigits: arabicDigits)
            return unit.map { "\(number) \($0)" } ?? number
        }

        let series = AXDataSeriesDescriptor(
            name: "",
            isContinuous: true,
            dataPoints: points.map {
                AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.value)
            }
        )

        return AXChartDescriptor(
            title: "",
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

/// A compact, axis-less line for cards — just the shape of the recent trend. Backed by a
/// lightweight `Shape`/`Path` rather than the full Charts framework, since it is purely
/// decorative and never interacted with (PERF-048).
struct MetricSparkline: View {
    private var points: [(x: CGFloat, value: Double)]
    var tint: Color
    /// Optional personal-range band. When present the sparkline scales relative to the band
    /// rather than its own local min/max, so a metric with genuinely tiny variance doesn't
    /// render as dramatically as one with real variance (UIUX-090).
    var band: (low: Double, high: Double)?

    /// Plots by raw array position (evenly spaced). Kept for existing callers; prefer the
    /// `series:` initializer when dates are available so real gaps show as real gaps.
    init(values: [Double], tint: Color = BadanColor.primary, band: (low: Double, high: Double)? = nil) {
        let finite = values.filter { $0.isFinite }
        let count = max(finite.count - 1, 1)
        self.points = finite.enumerated().map { index, value in
            (x: CGFloat(index) / CGFloat(count), value: value)
        }
        self.tint = tint
        self.band = band
    }

    /// Plots by actual date, so a series with real gaps (e.g. day 1, 2, 9, 10) renders with
    /// visible gaps instead of implying a smooth, evenly-spaced trend (OPT-098).
    init(series: [(date: Date, value: Double)], tint: Color = BadanColor.primary, band: (low: Double, high: Double)? = nil) {
        let finite = series.filter { $0.value.isFinite }.sorted { $0.date < $1.date }
        if let first = finite.first?.date, let last = finite.last?.date, last > first {
            let span = last.timeIntervalSince(first)
            self.points = finite.map { (x: CGFloat($0.date.timeIntervalSince(first) / span), value: $0.value) }
        } else {
            let count = max(finite.count - 1, 1)
            self.points = finite.enumerated().map { index, item in (x: CGFloat(index) / CGFloat(count), value: item.value) }
        }
        self.tint = tint
        self.band = band
    }

    var body: some View {
        // A single point (or fewer) has no line to draw; render nothing rather than force
        // every call site to duplicate this guard (OPT-100).
        if points.count < 2 {
            Color.clear
        } else {
            SparklinePath(points: points, band: band)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The polyline shape behind `MetricSparkline`, normalized to its own frame.
private struct SparklinePath: Shape {
    var points: [(x: CGFloat, value: Double)]
    var band: (low: Double, high: Double)?

    nonisolated func path(in rect: CGRect) -> Path {
        guard points.count >= 2 else { return Path() }
        let values = points.map(\.value)
        // Scale relative to the personal band when available (UIUX-090); otherwise fall back
        // to the series' own local min/max, matching the prior auto-scaling behavior.
        let low = band?.low ?? values.min() ?? 0
        let high = band?.high ?? values.max() ?? 1
        let range = max(high - low, .ulpOfOne)

        func point(_ p: (x: CGFloat, value: Double)) -> CGPoint {
            let clampedValue = min(max(p.value, low), high)
            let normalizedY = 1 - (CGFloat(clampedValue - low) / CGFloat(range))
            return CGPoint(x: p.x * rect.width, y: normalizedY * rect.height)
        }

        var path = Path()
        path.move(to: point(points[0]))
        for p in points.dropFirst() {
            path.addLine(to: point(p))
        }
        return path
    }
}

#Preview("MetricChart") {
    let now = Date()
    let series = (0..<14).map { i in (date: now.addingTimeInterval(Double(i) * -86_400), value: 60 + Double.random(in: -5...5)) }
    return VStack(spacing: BadanSpace.space5) {
        MetricChart(series: series, band: (low: 55, high: 65), unit: "bpm", language: .en)
            .frame(height: 200)
        MetricChart(series: [], language: .en)
            .frame(height: 200)
    }
    .padding()
}

#Preview("MetricSparkline") {
    VStack(alignment: .leading, spacing: BadanSpace.space3) {
        MetricSparkline(values: [58, 60, 59, 63, 61, 64, 62])
            .frame(width: 76, height: 28)
        MetricSparkline(values: [1])
            .frame(width: 76, height: 28)
    }
    .padding()
}
