import SwiftUI

/// Strings only the anatomy sheet needs — the calm, honest "why is it saying that" vocabulary.
private enum AnatomyStrings {
    static let baseline = LocalizedString(en: "Your baseline", ar: "خط الأساس")
    static let center = LocalizedString(en: "Center", ar: "المركز")
    static let daysUsed = LocalizedString(en: "Days used", ar: "الأيام المستخدمة")
    static let dedupHeading = LocalizedString(en: "Duplicate handling", ar: "معالجة التكرار")
    static let oneKept = LocalizedString(en: "One source kept, one suppressed.",
                                         ar: "مصدر واحد محتفظ به، وآخر مستبعد.")
    static let kept = LocalizedString(en: "Kept", ar: "المحتفظ به")
    static let straightFromRecords = LocalizedString(
        en: "This reads straight from your records — no extra calculation.",
        ar: "تُقرأ هذه القيمة مباشرة من سجلاتك — دون أي حساب إضافي.")
    static let noBaselineYet = LocalizedString(
        en: "Not enough history yet to draw a typical range.",
        ar: "لا يوجد سجل كافٍ بعد لرسم نطاق معتاد.")
}

/// The "How this was worked out" sheet (VS-4). Presented modally in its own stack, it shows the
/// personal baseline (center, band, days used, provisional honesty), the records that fed the
/// latest computed value, the frozen algorithm version, and — for sleep time-asleep — the
/// reversible dedup decision that kept one source and suppressed a duplicate sibling.
struct MetricAnatomySheet: View {
    let data: MetricDetailData

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space5) {
                    baselineCard
                    if let manifest = data.manifest, !manifest.inputs.isEmpty {
                        recordsCard(manifest)
                    } else {
                        straightFromRecordsCard
                    }
                    if let method = methodString {
                        methodCard(method)
                    }
                    if !data.recentDedup.isEmpty {
                        dedupCard
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(Loc.anatomyTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { dismiss() }
                }
            }
        }
    }

    // MARK: Baseline

    private var baselineCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(AnatomyStrings.baseline)) {
                    if data.baseline?.provisional ?? true { ProvisionalBadge(language: env.language) }
                }
                if let b = data.baseline {
                    infoRow(label: env.s(AnatomyStrings.center),
                            value: env.format.full(metricId: data.def.metricId, canonicalValue: b.center))
                    infoRow(label: env.s(Loc.personalRange), value: bandText(b))
                    infoRow(label: env.s(AnatomyStrings.daysUsed), value: env.format.integer(b.nPoints))
                } else {
                    Text(env.s(AnatomyStrings.noBaselineYet))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Contributing records

    private func recordsCard(_ manifest: InputManifest) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.contributingRecords))
                ForEach(Array(manifest.inputs.enumerated()), id: \.offset) { _, input in
                    let inputDef = env.registry.definitionOrFallback(input.metricId)
                    infoRow(label: inputDef.label(depth: env.depth, language: env.language),
                            value: env.format.full(metricId: input.metricId, canonicalValue: input.value))
                }
            }
        }
    }

    private var straightFromRecordsCard: some View {
        BadanCard {
            Text(env.s(AnatomyStrings.straightFromRecords))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Method

    private func methodCard(_ method: String) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                SectionHeader(env.s(Loc.algorithm))
                Text(method)
                    .font(BadanFont.bodyCompact.monospacedDigit())
                    .foregroundStyle(BadanColor.textPrimary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Dedup (sleep time-asleep only)

    private var dedupCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(AnatomyStrings.dedupHeading))
                Text(env.s(AnatomyStrings.oneKept))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(data.recentDedup.prefix(3)) { decision in
                    VStack(alignment: .leading, spacing: BadanSpace.space1) {
                        HStack(spacing: BadanSpace.space2) {
                            PillLabel(env.s(AnatomyStrings.kept), systemImage: "checkmark", tint: BadanColor.inBand)
                            PillLabel(env.s(Loc.suppressedDuplicate), systemImage: "arrow.uturn.backward",
                                      tint: BadanColor.textSecondary)
                        }
                        if decision.reversible {
                            Text(env.s(Loc.reversible))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                        Text("\(decision.rule) · \(decision.ruleVersion)")
                            .font(BadanFont.caption.monospacedDigit())
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Helpers

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Text(label)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Text(value)
                .font(BadanFont.bodyCompact.monospacedDigit())
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: BadanSpace.touchMin)
    }

    private func bandText(_ b: Baseline) -> String {
        let low = env.format.heroValue(metricId: data.def.metricId, canonicalValue: b.bandLow)
        let high = env.format.heroValue(metricId: data.def.metricId, canonicalValue: b.bandHigh)
        if let unit = env.format.unitLabel(metricId: data.def.metricId) {
            return "\(low) – \(high) \(unit)"
        }
        return "\(low) – \(high)"
    }

    private var methodString: String? {
        if let d = data.latestDerivedValue { return "\(d.algorithmId)@\(d.algorithmVersion)" }
        return data.baseline?.algorithmVersion
    }
}
