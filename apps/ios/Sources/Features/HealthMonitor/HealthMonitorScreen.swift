import SwiftUI

// MARK: - Local strings

/// Copy only the Health Monitor needs — the calm, method-not-verdict vocabulary EPIC-27 calls for.
/// Shared vocabulary (range positions, "still learning") comes from `Loc`; these fill the gaps.
private enum HealthMonitorStrings {
    static let title = LocalizedString(en: "Health Monitor", ar: "مراقب الصحة")
    static let subtitle = LocalizedString(
        en: "Your vitals against your own usual range.",
        ar: "مؤشراتك الحيوية مقارنةً بنطاقك المعتاد.")
    static let noReadingYet = LocalizedString(en: "No reading yet", ar: "لا توجد قراءة بعد")
    static let asOf = LocalizedString(en: "As of {day}", ar: "بتاريخ {day}")
    static let usualRange = LocalizedString(en: "Usual range {low}–{high}", ar: "النطاق المعتاد {low}–{high}")
    static let atUsualLevel = LocalizedString(en: "At your usual level", ar: "عند مستواك المعتاد")
    static let aboveUsualLevel = LocalizedString(en: "Above your usual level", ar: "أعلى من مستواك المعتاد")
    static let belowUsualLevel = LocalizedString(en: "Below your usual level", ar: "أدنى من مستواك المعتاد")
    static let dayOf = LocalizedString(en: "Day {n} of {total}", ar: "اليوم {n} من {total}")
    static let allQuiet = LocalizedString(
        en: "Nothing to show yet — connect a source that records your vitals.",
        ar: "لا شيء لعرضه بعد — أضف مصدراً يسجّل مؤشراتك الحيوية.")
}

// MARK: - Fetch inputs

/// Everything the read-model build needs to run off the main actor (PERF-01, mirroring
/// `HomeFetchInputs`): the thread-safe repository references plus a `now` snapshot. `DeviationEngine`
/// itself is constructed *inside* the detached task from these Sendable references, so no `@MainActor`
/// state crosses the boundary.
struct HealthMonitorFetchInputs {
    var derivation: DerivationRepository
    var measurements: MeasurementRepository
    var catalog: CatalogRepository
    var registry: MetricRegistry
    var sensorQuality: SensorQualityMap
    var now: Date
}

// MARK: - View model

@Observable
@MainActor
final class HealthMonitorViewModel {
    var state: LoadState<HealthMonitorReadModel> = .loading

    /// Builds the Health Monitor read model on a detached task so the vitals fan-out never blocks the
    /// main thread. A cancelled load (navigating away before it finishes) never clobbers state.
    func load(_ env: AppEnvironment) async {
        let inputs = HealthMonitorFetchInputs(
            derivation: env.derivation, measurements: env.measurements, catalog: env.catalog,
            registry: env.registry, sensorQuality: .shared, now: env.now())

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        switch outcome {
        case .success(let model):
            state = .loaded(model)
        case .failure(let error):
            LoadErrorLog.log(error, screen: "HealthMonitor")
            state = .error(env.s(LoadErrorCopy.message))
        }
    }

    nonisolated static func fetch(_ inputs: HealthMonitorFetchInputs) -> Result<HealthMonitorReadModel, Error> {
        do {
            let engine = DeviationEngine(
                derivation: inputs.derivation, measurements: inputs.measurements, catalog: inputs.catalog,
                registry: inputs.registry, sensorQuality: inputs.sensorQuality, clock: SystemClock())
            return .success(try engine.buildReadModel(asOf: inputs.now))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Screen

/// EPIC-27 — the vitals dashboard, under Body. One tile per tracked vital (RHR, HRV, respiratory rate,
/// SpO2, wrist-temperature deviation), each judged only against the person's OWN band, with a calm
/// out-of-range note and a per-source sensor-quality label. Temperature is a deviation by construction
/// (the read model carries no absolute skin temperature to render). A persistent "not a medical
/// evaluation" footer sits below the fold at all times.
///
/// Casual shows the tiles — value, position, sparkline. Power adds the band edges, the calibration
/// count, and the sensor-quality method label (plan §11 EPIC-27: "Casual: tiles only; power: bands, n,
/// source labels").
struct HealthMonitorScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm = HealthMonitorViewModel()
    /// EPIC-34. A separate view model, not a field on the vitals read model: the stress surface is
    /// gated by its own density detector and answers "hidden" for most devices, so it must render
    /// (and explain itself) even when the vitals fan-out fails — hence its own load, outside the
    /// vitals `StatefulContainer`.
    @State private var stressVM = StressSurfaceViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                StatefulContainer(
                    vm.state,
                    retryTitle: env.s(LoadErrorCopy.retry),
                    onRetry: { Task { await vm.load(env) } }
                ) { model in
                    content(model)
                }
                StressTrendCard(vm: stressVM)
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(HealthMonitorStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        // The "not a medical evaluation" footer is PERSISTENT (plan §11 EPIC-27 risk mitigation):
        // pinned to the bottom safe area so it stays on screen at every scroll position, not just at
        // the end of the list. Its exact wording lives in the read model (`DeviationEngine.disclaimer`)
        // and is asserted by a test, so a view can never quietly drop or reword it.
        .safeAreaInset(edge: .bottom) {
            if case .loaded(let model) = vm.state {
                MedicalFooter(text: model.disclaimer, language: env.language)
            }
        }
        .task(id: HealthMonitorLoadKey(profile: env.profile, generation: env.dataGeneration)) {
            await vm.load(env)
        }
        .task(id: HealthMonitorLoadKey(profile: env.profile, generation: env.dataGeneration)) {
            await stressVM.load(env)
        }
    }

    @ViewBuilder
    private func content(_ model: HealthMonitorReadModel) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space4) {
            Text(HealthMonitorStrings.subtitle, language: env.language)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Every tracked vital is always shown — a vital with no reading is an honest no-data
            // tile, never omitted, so the dashboard's shape is stable. When ALL of them are no-data
            // (nothing connected records vitals) a single calm hint replaces the wall of empties.
            if model.vitals.allSatisfy({ $0.state == .noData }) {
                allQuietHint
            } else {
                ForEach(model.vitals) { tile in
                    VitalTileCard(tile: tile)
                }
            }
        }
    }

    private var allQuietHint: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
                Text(HealthMonitorStrings.allQuiet, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// (F5) The `.task(id:)` identity — mirrors `HomeLoadKey`/`BodyLoadKey`. See `AppEnvironment.dataGeneration`.
private struct HealthMonitorLoadKey: Equatable {
    let profile: CustomizationProfile
    let generation: Int
}

// MARK: - Vital tile

private struct VitalTileCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let tile: VitalTile

    var body: some View {
        NavigationLink { MetricDetailScreen(metricId: tile.metricId) } label: {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    header
                    valueRow
                    if let annotation = tile.annotation {
                        Text(annotation, language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.outOfBandOnTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if tile.state == .calibrating {
                        calibrationHint
                    }
                    if hasSparkline, !dynamicTypeSize.isAccessibilitySize {
                        HealthMonitorTilePresentation.sparkline(tile: tile)
                            .frame(height: 34)
                            .accessibilityHidden(true)
                    }
                    if env.depth.showsPowerDetail {
                        powerDetail
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: tile.family.symbolName)
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            Text(tile.title, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Image(systemName: "chevron.forward")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
        }
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space3) {
            if let reading = tile.reading {
                Text(HealthMonitorTilePresentation.readingText(tile: tile, reading: reading, format: env.format))
                    .font(BadanFont.numeralM)
                    .foregroundStyle(BadanColor.textPrimary)
                if let unit = HealthMonitorTilePresentation.unitText(tile: tile, format: env.format) {
                    Text(unit)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            } else {
                Text(HealthMonitorStrings.noReadingYet, language: env.language)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Spacer(minLength: BadanSpace.space2)
            if let chip = statusChip {
                chip
            }
        }
    }

    /// The band position / directional chip. Absent while calibrating (nothing is claimed yet),
    /// no-data (nothing to place), or stale is handled inside `chipStatus` (a stale tile still shows
    /// its last known position, matching the read model's own `state`).
    private var statusChip: StatusChip? {
        guard let mapped = HealthMonitorTilePresentation.chip(for: tile.state) else { return nil }
        // "as of <day>" replaces a live chip's authority on a stale tile, so the position never reads
        // as current when the reading is days old.
        if tile.isStale, let day = tile.asOfDay {
            return StatusChip(.info, label: env.s(HealthMonitorStrings.asOf.filling(["day": day])), language: env.language)
        }
        return StatusChip(mapped.status, label: env.s(mapped.label), language: env.language)
    }

    private var hasSparkline: Bool {
        tile.sparkline.compactMap(\.value).count >= 2
    }

    /// A compact calibration line for a tile whose band is still filling — a ProvisionalBadge plus, at
    /// power depth, the "Day n of N" countdown from the band's own point count. The full `CalibrationNote`
    /// is reserved for the score cards; a vitals tile just needs the honest "not judging yet" cue.
    private var calibrationHint: some View {
        HStack(spacing: BadanSpace.space2) {
            ProvisionalBadge(language: env.language)
            if env.depth.showsPowerDetail, let band = tile.band {
                Text(dayOfText(nPoints: band.nPoints, windowDays: band.windowDays))
                    .font(BadanFont.caption.monospacedDigit())
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var powerDetail: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            if let band = tile.band, !band.provisional {
                Text(bandText(band))
                    .font(BadanFont.caption.monospacedDigit())
                    .foregroundStyle(BadanColor.textSecondary)
            }
            if let quality = tile.sourceQuality {
                SourceQualityChip(quality: quality, language: env.language)
            }
        }
    }

    private func bandText(_ band: PersonalBand) -> String {
        let low = env.format.heroValue(metricId: tile.metricId, canonicalValue: band.low)
        let high = env.format.heroValue(metricId: tile.metricId, canonicalValue: band.high)
        return HealthMonitorStrings.usualRange.filling(["low": low, "high": high]).resolved(env.language)
    }

    private func dayOfText(nPoints: Int, windowDays: Int) -> String {
        CalibrationCount.dayPhrase(n: min(nPoints, windowDays), total: windowDays,
                                   language: env.language, format: env.format, template: HealthMonitorStrings.dayOf)
    }
}

// MARK: - Source-quality chip

/// The per-source sensor-quality label (plan §11 EPIC-27): which source produced the reading and how
/// much that sensor class is worth for this family — an honesty surface, never a suppressor. Renders
/// straight from `SensorQualityLevel`'s already-bilingual `label` + `symbolName` + `tint`.
private struct SourceQualityChip: View {
    let quality: SourceQualityLabel
    var language: AppLanguage

    var body: some View {
        HStack(spacing: BadanSpace.space1) {
            Image(systemName: quality.level.symbolName)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text("\(quality.sourceDisplayName) · \(quality.level.label.resolved(language))")
                .font(BadanFont.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(quality.level.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(quality.sourceDisplayName), \(quality.level.label.resolved(language))")
    }
}

// MARK: - Medical footer

/// The persistent "not a medical evaluation" strip. Calm and factual (no alarm chrome) — it states
/// what the surface is, never a verdict. Its text comes from the read model so the wording is
/// single-sourced and test-asserted.
private struct MedicalFooter: View {
    let text: LocalizedString
    var language: AppLanguage

    var body: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(text, language: language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BadanSpace.space4)
        .padding(.vertical, BadanSpace.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Token surface + a top hairline so the pinned footer reads as a distinct strip above the
        // content, matching `StorageFallbackBanner` rather than introducing a non-token material.
        .background(BadanColor.surfaceElevated)
        .overlay(alignment: .top) {
            Rectangle().fill(BadanColor.separator).frame(height: 1)
        }
    }
}

// MARK: - Pure presentation helpers (testable)

/// The pure mapping from a `VitalTile`'s read-model state to its presentation — chip status/label,
/// reading text, unit, sparkline. Extracted so the tile's honesty rules (a `.calibrating` state never
/// gets a band chip; a deviation reading always carries its sign; temperature never shows a unitless
/// bare number) are unit-tested without standing up a view.
enum HealthMonitorTilePresentation {
    struct ChipSpec { let status: StatusChip.Status; let label: LocalizedString }

    /// The band-position / directional chip for a state, or `nil` when nothing should be claimed
    /// (no-data, still calibrating). A stale tile still returns its last known position here; the view
    /// layer swaps in an "as of <day>" chip so it doesn't read as a live verdict.
    static func chip(for state: VitalState) -> ChipSpec? {
        switch state {
        case .noData, .calibrating:
            return nil
        case .withinBand:
            return ChipSpec(status: .inBand, label: Loc.inYourRange)
        case .aboveBand:
            return ChipSpec(status: .above, label: Loc.aboveYourRange)
        case .belowBand:
            return ChipSpec(status: .below, label: Loc.belowYourRange)
        case .deviation(let direction):
            switch direction {
            case .atUsual: return ChipSpec(status: .inBand, label: HealthMonitorStrings.atUsualLevel)
            case .aboveUsual: return ChipSpec(status: .above, label: HealthMonitorStrings.aboveUsualLevel)
            case .belowUsual: return ChipSpec(status: .below, label: HealthMonitorStrings.belowUsualLevel)
            }
        }
    }

    /// The value text. An `.absolute` reading formats through the user's unit profile; a `.deviation`
    /// (temperature only) always carries an explicit sign so "+0.3" and "−0.2" are never confused with
    /// an absolute reading, and a zero deviation is written "±0" rather than a bare "0".
    static func readingText(tile: VitalTile, reading: VitalReading, format: ValueFormatter) -> String {
        switch reading {
        case .absolute(let v):
            return format.heroValue(metricId: tile.metricId, canonicalValue: v)
        case .deviation(let v):
            let magnitude = format.heroValue(metricId: tile.metricId, canonicalValue: abs(v))
            let sign = v > 0 ? "+" : (v < 0 ? "\u{2212}" : "\u{00B1}")
            return "\(sign)\(magnitude)"
        }
    }

    /// The unit shown beside the value, or `nil` when the value is self-describing (durations) or the
    /// registry gives no unit label.
    static func unitText(tile: VitalTile, format: ValueFormatter) -> String? {
        format.unitLabel(metricId: tile.metricId)
    }

    /// The tile sparkline. Scales against the personal band when present so a vital with genuinely tiny
    /// variance doesn't render as dramatically as one with real variance, matching `MetricSparkline`'s
    /// own band-relative scaling. Gaps (nil points) are dropped from the plotted series but the missing
    /// days remain absent (never zero-filled), so a gap reads as a gap.
    @MainActor
    static func sparkline(tile: VitalTile) -> MetricSparkline {
        let series: [(date: Date, value: Double)] = tile.sparkline.compactMap { point in
            guard let value = point.value, let date = DayAttribution.date(fromDayKey: point.day, tz: TimeZone.current.identifier)
            else { return nil }
            return (date: date, value: value)
        }
        let band = tile.band.map { (low: $0.low, high: $0.high) }
        return MetricSparkline(series: series, band: band)
    }
}
