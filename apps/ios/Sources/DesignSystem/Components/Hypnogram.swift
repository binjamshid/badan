import SwiftUI

// MARK: - Hypnogram layout (pure — platform-independent, golden-testable)

/// One segment of a hypnogram along the night's time axis. `stage == nil` marks a stretch of the
/// night with no stage row at all — an *unrecorded gap*, drawn as a neutral hole, never silently
/// closed up (plan §18: a missing stretch is missing data, not a zero). Kept as a pure value type
/// (no `View`, no colour) so the segmentation is unit-tested directly.
struct HypnogramSegment: Hashable {
    let stage: SleepStage?
    /// Fraction of the whole night's span this segment covers (0…1). Widths sum to ~1 across all
    /// segments including gaps, so the bar is time-accurate rather than evenly slicing the stages.
    let fraction: Double
    let seconds: Double
}

/// Turns a night's raw `SessionStage` rows into an ordered, time-proportional segment list plus a
/// per-stage duration ledger — everything the `Hypnogram` view and its accessibility summary render,
/// with no SwiftUI or colour in sight so the segmentation itself can be asserted in a test.
///
/// The span is the earliest stage start to the latest stage end; each stage occupies its true
/// `[start, end]` share of that span, and any time BETWEEN two consecutive stages (a stretch the
/// source reported no stage for) becomes an explicit `stage == nil` gap segment rather than being
/// absorbed into its neighbours. Overlapping rows (a corrected re-ingest landing over an earlier
/// one) are laid in start order and clamped so a later row never renders behind the axis.
struct HypnogramLayout {
    let segments: [HypnogramSegment]
    let totalSeconds: Double
    /// Seconds per stage, for the legend/summary. Only stages actually present appear.
    let stageSeconds: [SleepStage: Double]

    init(stages: [SessionStage]) {
        let ordered = stages
            .filter { $0.endAt > $0.startAt }
            .sorted { $0.startAt < $1.startAt }
        guard let first = ordered.first, let last = ordered.map(\.endAt).max(),
              last > first.startAt else {
            self.segments = []; self.totalSeconds = 0; self.stageSeconds = [:]
            return
        }
        let span = last.timeIntervalSince(first.startAt)

        var segs: [HypnogramSegment] = []
        var ledger: [SleepStage: Double] = [:]
        var cursor = first.startAt
        for stage in ordered {
            // A later row that starts before the cursor (overlap) is clamped to the cursor so the
            // timeline never runs backwards; a fully-superseded row contributes nothing.
            let segStart = max(stage.startAt, cursor)
            guard stage.endAt > segStart else { continue }
            if segStart > cursor {
                let gap = segStart.timeIntervalSince(cursor)
                segs.append(HypnogramSegment(stage: nil, fraction: gap / span, seconds: gap))
            }
            let dur = stage.endAt.timeIntervalSince(segStart)
            segs.append(HypnogramSegment(stage: stage.stage, fraction: dur / span, seconds: dur))
            ledger[stage.stage, default: 0] += dur
            cursor = stage.endAt
        }

        self.segments = segs
        self.totalSeconds = span
        self.stageSeconds = ledger
    }
}

// MARK: - Stage palette

/// The hypnogram's stage tints. These hues **differentiate** stages so the night's architecture is
/// legible at a glance; they deliberately do NOT rank them — there is no "good" or "bad" stage, and
/// the design system's reserved amber (`outOfBand`) is intentionally NOT used here so a hypnogram
/// never reads as a band verdict. Deep→light is a single `primary` depth ramp, REM is the calm
/// informational blue (a recognizable, non-judgmental convention), awake/in-bed are neutral. Colour
/// is never the only signal: every stage carries its bilingual label in the legend and the
/// accessibility summary, exactly as `StatusChip` pairs hue with glyph + text.
enum HypnogramPalette {
    static func fill(_ stage: SleepStage?) -> Color {
        guard let stage else { return BadanColor.textSecondary.opacity(0.18) } // unrecorded gap
        switch stage {
        case .deep: return BadanColor.primary
        case .rem: return BadanColor.info.opacity(0.9)
        case .light, .asleepUnspecified: return BadanColor.primary.opacity(0.5)
        case .awake: return BadanColor.textSecondary.opacity(0.6)
        case .inBed: return BadanColor.textSecondary.opacity(0.3)
        }
    }
}

// MARK: - Hypnogram

/// A compact hypnogram: the night's sleep stages laid out along a left-to-right time axis, with a
/// legend of the stages that actually occurred and their durations. Wellness-safe by construction —
/// it describes the shape of the night, never grades it.
///
/// The time axis is pinned left-to-right even inside an RTL screen (like `MetricChart` and
/// `MetricSparkline`): a night runs earlier→later regardless of reading direction. The surrounding
/// legend follows the ambient direction so Arabic labels mirror normally.
struct Hypnogram: View {
    let stages: [SessionStage]
    var language: AppLanguage
    /// The bar's own height; the legend sits beneath it.
    var barHeight: CGFloat

    private let layout: HypnogramLayout

    init(stages: [SessionStage], language: AppLanguage, barHeight: CGFloat = 40) {
        self.stages = stages
        self.language = language
        self.barHeight = barHeight
        self.layout = HypnogramLayout(stages: stages)
    }

    /// The stages present, in a fixed depth-order for the legend (not chronological — the legend
    /// names the palette, the bar carries the sequence).
    private static let legendOrder: [SleepStage] = [.deep, .rem, .light, .asleepUnspecified, .awake, .inBed]

    var body: some View {
        if layout.segments.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                bar
                legend
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(layout.segments.enumerated()), id: \.offset) { _, seg in
                    HypnogramPalette.fill(seg.stage)
                        .frame(width: max(0, geo.size.width * seg.fraction))
                }
            }
            .frame(height: barHeight)
            .clipShape(RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
        }
        .frame(height: barHeight)
        // Time reads left-to-right even on an RTL screen.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        // Wraps so a night with many stages never clips at large Dynamic Type sizes.
        FlowRow(spacing: BadanSpace.space3, rowSpacing: BadanSpace.space1) {
            ForEach(Self.legendOrder.filter { (layout.stageSeconds[$0] ?? 0) > 0 }, id: \.self) { stage in
                HStack(spacing: BadanSpace.space1) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(HypnogramPalette.fill(stage))
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(stage.displayName, language: language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }

    /// A spoken summary that names each present stage and its duration — the audio equivalent of the
    /// bar, so a VoiceOver user gets the same "what did the night look like" answer sighted users do.
    private var accessibilitySummary: String {
        let parts = Self.legendOrder.compactMap { stage -> String? in
            guard let secs = layout.stageSeconds[stage], secs > 0 else { return nil }
            let minutes = Int((secs / 60).rounded())
            let unit = language == .ar ? "دقيقة" : "min"
            return "\(stage.displayName.resolved(language)) \(Numerals.accessibleSpokenForm(Double(minutes))) \(unit)"
        }
        let heading = language == .ar ? "مراحل النوم" : "Sleep stages"
        return ([heading] + parts).joined(separator: ", ")
    }
}

// MARK: - Need-vs-actual bar

/// The pure geometry behind `SleepNeedVsActualBar`: where the personal need band and the actual
/// sleep sit on a shared 0…max track. Kept separate from the view so the fractions — the honest
/// core, since an off-by-one here would misplace the band — are unit-tested directly.
///
/// The track's max is a little past whichever is larger, the top of the need band or the actual
/// sleep, so neither the band nor the marker ever pins to the very edge. Fractions are clamped to
/// 0…1 defensively.
struct NeedVsActualLayout: Hashable {
    let bandLowFraction: Double
    let bandHighFraction: Double
    let centerFraction: Double
    let actualFraction: Double
    let trackMaxSeconds: Double

    init(actualSeconds: Double, needLowSeconds: Double, needCenterSeconds: Double, needHighSeconds: Double) {
        let top = max(needHighSeconds, actualSeconds)
        let trackMax = top > 0 ? top * 1.08 : 1
        func frac(_ v: Double) -> Double { min(1, max(0, v / trackMax)) }
        self.bandLowFraction = frac(needLowSeconds)
        self.bandHighFraction = frac(needHighSeconds)
        self.centerFraction = frac(needCenterSeconds)
        self.actualFraction = frac(actualSeconds)
        self.trackMaxSeconds = trackMax
    }
}

/// A calm "how last night compared to what your body needed" bar. The need is drawn as a **range**
/// (a shaded band with a centre tick), never a fake-exact target line (plan §4 principle 9); the
/// actual sleep is a filled bar up to its point. No red/green — the fill is `primary`, the need band
/// is the same soft `inBand` wash used for personal ranges everywhere else, so this reads as context,
/// not a grade.
struct SleepNeedVsActualBar: View {
    let actualSeconds: Double
    let needLowSeconds: Double
    let needCenterSeconds: Double
    let needHighSeconds: Double
    var language: AppLanguage
    /// Pre-formatted, bilingual value strings the owner supplies (so this component never reaches for
    /// a `ValueFormatter`): the actual duration and the need range text.
    var actualText: String
    var needRangeText: String
    var barHeight: CGFloat = 22

    private var layout: NeedVsActualLayout {
        NeedVsActualLayout(actualSeconds: actualSeconds, needLowSeconds: needLowSeconds,
                           needCenterSeconds: needCenterSeconds, needHighSeconds: needHighSeconds)
    }

    private static let actualLabel = LocalizedString(en: "Slept", ar: "نمت")
    private static let needLabel = LocalizedString(en: "Your need", ar: "حاجتك")

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    // Track
                    Capsule().fill(BadanColor.surfaceElevated)
                    // Need band (the range)
                    RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                        .fill(BadanColor.inBand.opacity(0.22))
                        .frame(width: max(0, w * (layout.bandHighFraction - layout.bandLowFraction)))
                        .offset(x: w * layout.bandLowFraction)
                    // Need centre tick
                    Rectangle()
                        .fill(BadanColor.inBand.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: w * layout.centerFraction)
                    // Actual sleep fill
                    Capsule()
                        .fill(BadanColor.primary)
                        .frame(width: max(0, w * layout.actualFraction))
                        .opacity(0.85)
                }
                .frame(height: barHeight)
            }
            .frame(height: barHeight)
            .environment(\.layoutDirection, .leftToRight) // duration axis is LTR
            .accessibilityHidden(true)

            HStack(spacing: BadanSpace.space3) {
                legendSwatch(color: BadanColor.primary.opacity(0.85),
                             label: "\(env(Self.actualLabel)) · \(actualText)")
                legendSwatch(color: BadanColor.inBand.opacity(0.35),
                             label: "\(env(Self.needLabel)) · \(needRangeText)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(env(Self.actualLabel)) \(actualText). \(env(Self.needLabel)) \(needRangeText)")
    }

    private func env(_ ls: LocalizedString) -> String { ls.resolved(language) }

    private func legendSwatch(color: Color, label: String) -> some View {
        HStack(spacing: BadanSpace.space1) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(label)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - FlowRow

/// A minimal wrapping row (leading-aligned), used by the hypnogram legend so stage chips flow onto a
/// second line instead of clipping at large Dynamic Type sizes. Kept here (not a shared layout file)
/// since the hypnogram is its only caller today; promote it if a second surface needs it.
struct FlowRow: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    init(spacing: CGFloat = 8, rowSpacing: CGFloat = 4) {
        self.spacing = spacing; self.rowSpacing = rowSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0, totalHeight: CGFloat = 0, maxRowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + rowSpacing
                maxRowWidth = max(maxRowWidth, rowWidth)
                rowWidth = size.width; rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth)
        return CGSize(width: min(maxRowWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + rowSpacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
