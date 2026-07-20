import SwiftUI
import UIKit

// MARK: - Copy

private enum QuickExportCopy {
    static let title = LocalizedString(en: "Quick Export", ar: "تصدير سريع")
    static let subtitle = LocalizedString(
        en: "Your records, in a few taps. Sensitive records and workout routes are never included here — use the builder for those.",
        ar: "سجلاتك في نقرات قليلة. لا تُدرَج هنا أبداً السجلات الحساسة ومسارات التمارين — استخدم المُنشئ لتلك.")
    static let trust = LocalizedString(
        en: "Everything here stays on your device until you share it.",
        ar: "كل شيء هنا يبقى على جهازك حتى تشاركه.")
    static let period = LocalizedString(en: "Period", ar: "الفترة")
    static let format = LocalizedString(en: "Format", ar: "الصيغة")
    static let prepare = LocalizedString(en: "Prepare export", ar: "تجهيز التصدير")
    static let preparing = LocalizedString(en: "Preparing…", ar: "جارٍ التجهيز…")
    static let readyToShare = LocalizedString(en: "Ready to share", ar: "جاهز للمشاركة")
    static let records = LocalizedString(en: "records", ar: "سجل")
    static let noRecords = LocalizedString(
        en: "No records in this period yet — nothing to share.",
        ar: "لا سجلات في هذه الفترة بعد — لا شيء لمشاركته.")
    static let changeSelection = LocalizedString(en: "Change selection", ar: "تغيير التحديد")
    static let couldntPrepare = LocalizedString(
        en: "That export couldn't be prepared. Nothing left your device.",
        ar: "تعذّر تجهيز هذا التصدير. لم يغادر شيء جهازك.")
    static let tryAgain = LocalizedString(en: "Try again", ar: "حاول مرة أخرى")

    /// VoiceOver label for the ready state — includes the row count as a spoken number, per §16
    /// ("VO labels incl. row counts").
    static func readyAccessibility(count: Int, format: ExportFormat) -> LocalizedString {
        let spoken = Numerals.accessibleSpokenForm(Double(count))
        return LocalizedString(
            en: "Ready to share: \(spoken) records, \(format.rawValue.uppercased()).",
            ar: "جاهز للمشاركة: \(spoken) سجلاً، \(format.rawValue.uppercased()).")
    }
}

// MARK: - Range

/// The three Quick Export windows (§12 EPIC-10). Deliberately its own tiny enum rather than
/// reusing `ExportRange` (last30/last90/all/custom) — Quick Export offers a *different* triple
/// (Last 7 / Last 30 / All time, no custom) and maps onto the seeded `QuickExportPreset` rows,
/// which are the structural guarantee that sensitive data and routes can't ride along.
enum QuickExportRange: String, CaseIterable, Hashable {
    case last7, last30, all

    func label(_ format: ValueFormatter) -> LocalizedString {
        switch self {
        case .last7:
            let n = format.integer(7)
            return LocalizedString(en: "Last \(n) days", ar: "آخر \(n) أيام")
        case .last30:
            let n = format.integer(30)
            return LocalizedString(en: "Last \(n) days", ar: "آخر \(n) يوماً")
        case .all:
            return LocalizedString(en: "All time", ar: "كل الوقت")
        }
    }

    /// The seeded preset this (range, format) pair runs. This is the only mapping from a Quick
    /// Export selection to a runnable configuration, and every destination it can reach is a
    /// `QuickExportPreset` whose scope is hardcoded non-sensitive, non-route (see that type).
    func preset(_ format: ExportFormat) -> QuickExportPreset {
        switch (self, format) {
        case (.last7, .csv): return .last7CSV
        case (.last7, .json): return .last7JSON
        case (.last30, .csv): return .last30CSV
        case (.last30, .json): return .last30JSON
        case (.all, .csv): return .allTimeCSV
        case (.all, .json): return .allTimeJSON
        }
    }
}

// MARK: - View model

@Observable
@MainActor
final class QuickExportViewModel {
    var range: QuickExportRange = .last30
    var format: ExportFormat = .csv
    var isRunning = false
    var prepared: Prepared?
    var errorText: String?

    /// A generated-but-not-yet-shared export: the files on disk and the count the user sees before
    /// deciding to share (§16 friction note — preset ambiguity is answered by a real count, not a
    /// guess).
    struct Prepared {
        let files: [URL]
        let rowCount: Int
        let range: QuickExportRange
        let format: ExportFormat
    }

    func prepare(env: AppEnvironment) {
        guard !isRunning else { return }
        isRunning = true
        errorText = nil
        prepared = nil
        let service = ExportManageService(env: env)
        service.ensureSeeded()
        let preset = range.preset(format)
        let template = preset.template(now: env.now(), originDeviceId: env.deviceId)
        let selectedRange = range
        let selectedFormat = format
        Task {
            do {
                // `service.run` dispatches the (synchronous, offline) generation off the main
                // actor itself, so a large "all time" export never freezes the card or trips the
                // iOS watchdog.
                let result = try await service.run(template: template, passphrase: nil, consent: nil)
                prepared = Prepared(files: result.files, rowCount: result.rowCount,
                                    range: selectedRange, format: selectedFormat)
                Announce.status(env.s(QuickExportCopy.readyAccessibility(
                    count: result.rowCount, format: selectedFormat)))
            } catch {
                errorText = String(describing: error)
            }
            isRunning = false
        }
    }

    /// Discard the prepared files without sharing — deletes the temp folder so a prepared-then-
    /// abandoned export doesn't linger on disk (ledger #19's "don't outlive its purpose").
    func discard(env: AppEnvironment) {
        if let files = prepared?.files {
            let folders = Set(files.map { $0.deletingLastPathComponent().path })
            for folder in folders { env.exporter.deleteExportedFiles(at: folder) }
        }
        prepared = nil
        errorText = nil
    }
}

// MARK: - Card

/// EPIC-10 — the casual, ≤3-tap export. Pick a period (default: last 30), a format (default: CSV),
/// tap Prepare, see the record count, tap Share. The power builder and the template library sit a
/// tap away for anyone who needs more; this card is the whole surface for someone who just wants
/// their data.
struct QuickExportCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vm = QuickExportViewModel()
    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(QuickExportCopy.title))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    Text(QuickExportCopy.subtitle, language: env.language)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let prepared = vm.prepared {
                        preparedView(prepared)
                    } else {
                        selectionView
                    }

                    if let error = vm.errorText {
                        errorView(error)
                    }

                    trustRow
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(activityItems: shareURLs) { completed in
                guard completed else { return }
                vm.discard(env: env)
            }
        }
    }

    // MARK: Selection

    private var selectionView: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            labeledSegment(QuickExportCopy.period) {
                QuickSegmented(
                    options: QuickExportRange.allCases.map { (value: $0, label: env.s($0.label(env.format))) },
                    selection: Binding(get: { vm.range }, set: { vm.range = $0 }))
            }
            labeledSegment(QuickExportCopy.format) {
                QuickSegmented(
                    options: ExportFormat.allCases.map { (value: $0, label: $0.rawValue.uppercased()) },
                    selection: Binding(get: { vm.format }, set: { vm.format = $0 }))
            }
            prepareButton
        }
    }

    private func labeledSegment<Segment: View>(_ label: LocalizedString,
                                               @ViewBuilder _ segment: () -> Segment) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(label, language: env.language)
                .font(BadanFont.caption.weight(.medium))
                .foregroundStyle(BadanColor.textSecondary)
            segment()
        }
    }

    private var prepareButton: some View {
        Button(action: { vm.prepare(env: env) }) {
            HStack(spacing: BadanSpace.space2) {
                if vm.isRunning {
                    ProgressView().tint(BadanColor.onPrimary)
                    Text(QuickExportCopy.preparing, language: env.language)
                } else {
                    Image(systemName: "sparkles").accessibilityHidden(true)
                    Text(QuickExportCopy.prepare, language: env.language)
                }
            }
            .font(BadanFont.body.weight(.semibold))
            .foregroundStyle(BadanColor.onPrimary)
            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin + 4)
            .background(BadanColor.primary,
                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(vm.isRunning)
        .opacity(vm.isRunning ? 0.75 : 1)
    }

    // MARK: Prepared

    @ViewBuilder
    private func preparedView(_ prepared: QuickExportViewModel.Prepared) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: prepared.rowCount == 0 ? "tray" : "checkmark.seal.fill")
                    .imageScale(.large)
                    .foregroundStyle(prepared.rowCount == 0 ? BadanColor.textSecondary : BadanColor.inBand)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prepared.rowCount == 0 ? env.s(QuickExportCopy.noRecords)
                                                : env.s(QuickExportCopy.readyToShare))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if prepared.rowCount > 0 {
                        Text(recordCountText(prepared))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
                Spacer(minLength: BadanSpace.space2)
                PillLabel(prepared.format.rawValue.uppercased(), tint: BadanColor.primary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(prepared.rowCount == 0
                ? env.s(QuickExportCopy.noRecords)
                : env.s(QuickExportCopy.readyAccessibility(count: prepared.rowCount, format: prepared.format)))

            if prepared.rowCount > 0 && !prepared.files.isEmpty {
                shareButton(prepared)
            }
            changeSelectionButton
        }
    }

    private func recordCountText(_ prepared: QuickExportViewModel.Prepared) -> String {
        "\(env.format.integer(prepared.rowCount)) \(env.s(QuickExportCopy.records)) · \(env.s(prepared.range.label(env.format)))"
    }

    private func shareButton(_ prepared: QuickExportViewModel.Prepared) -> some View {
        Button {
            shareURLs = prepared.files
            showShare = true
        } label: {
            HStack(spacing: BadanSpace.space2) {
                Image(systemName: "square.and.arrow.up").accessibilityHidden(true)
                Text(Loc.share, language: env.language)
            }
            .font(BadanFont.body.weight(.semibold))
            .foregroundStyle(BadanColor.onPrimary)
            .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin + 4)
            .background(BadanColor.primary,
                        in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var changeSelectionButton: some View {
        Button {
            withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                vm.discard(env: env)
            }
        } label: {
            Text(QuickExportCopy.changeSelection, language: env.language)
                .font(BadanFont.link)
                .foregroundStyle(BadanColor.primary)
                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
        }
        .buttonStyle(.plain)
    }

    // MARK: Error

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            HStack(alignment: .top, spacing: BadanSpace.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(BadanColor.outOfBand)
                    .accessibilityHidden(true)
                Text(QuickExportCopy.couldntPrepare, language: env.language)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if env.depth.showsPowerDetail {
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: { vm.prepare(env: env) }) {
                Text(QuickExportCopy.tryAgain, language: env.language)
                    .font(BadanFont.body.weight(.medium))
                    .foregroundStyle(BadanColor.primary)
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                    .overlay(RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                        .strokeBorder(BadanColor.primary, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(BadanSpace.space3)
        .background(BadanColor.outOfBand.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
    }

    // MARK: Trust

    private var trustRow: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "wifi.slash")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(QuickExportCopy.trust, language: env.language)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Segmented control

/// The same weight+border-carried-selection segmented control `ExportCenterScreen` uses (A6:
/// selection is never conveyed by hue alone), kept local to Quick Export so the two surfaces don't
/// couple through a shared private type.
private struct QuickSegmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: BadanSpace.space1) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = selection == option.value
                Button {
                    selection = option.value
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text(option.label)
                        .font(BadanFont.chip.weight(isSelected ? .bold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                        .foregroundStyle(isSelected ? BadanColor.primary : BadanColor.textSecondary)
                        .background(isSelected ? BadanColor.primary.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: BadanRadius.control - 2, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: BadanRadius.control - 2, style: .continuous)
                            .strokeBorder(isSelected ? BadanColor.primary : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(BadanSpace.space1)
        .background(BadanColor.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
    }
}
