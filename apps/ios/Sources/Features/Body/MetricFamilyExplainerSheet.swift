import SwiftUI

/// Bilingual, wellness-safe explanations of the metric families the widened read set introduced
/// (EPIC-01 task 5 + task 8, plan §4.9 "no false precision").
///
/// **Why this copy is authored here and not read from the registry.** `MetricDefinition` carries
/// `explainerEn` and nothing else — an English-only field. Rendering that to an Arabic reader is
/// the exact failure the en+ar rule exists to prevent, so family-level copy is written by hand,
/// in both languages, in one place. The registry stays the authority on which metrics exist and
/// what they are called; this is the authority on what a family MEANS to a person reading it.
///
/// **What every explainer must contain**, in this order:
///   1. What the family is, in a sentence a non-specialist finishes.
///   2. How the device actually gets it — the sentence that prevents "why is this blank?".
///   3. The honesty note: what this number is not, or what it can't tell you. Never optional.
/// The third is where plan §4.9 lives. Wrist temperature is the sharp case: HealthKit hands over
/// an absolute skin temperature, BADAN's registry metric is a deviation from the person's own
/// usual level, and the two are not the same number (see `HKTypeMap.NoIngestReason
/// .awaitingDerivation`). The explainer says so rather than letting the label imply a reading
/// exists.
struct MetricFamilyExplainer: Identifiable, Hashable {
    let family: MetricFamily
    let whatItIs: LocalizedString
    let howItsRecorded: LocalizedString
    let honestyNote: LocalizedString

    var id: String { family.rawValue }

    static func forFamily(_ family: MetricFamily) -> MetricFamilyExplainer {
        all.first { $0.family == family } ?? MetricFamilyExplainer(
            family: family,
            whatItIs: LocalizedString(
                en: "Readings BADAN keeps for you in this group.",
                ar: "قراءات يحتفظ بها بدن لك ضمن هذه المجموعة."),
            howItsRecorded: LocalizedString(
                en: "Recorded by whichever source you've connected, or entered by you.",
                ar: "تُسجَّل بواسطة المصدر الذي ربطته، أو تُدخلها بنفسك."),
            honestyNote: LocalizedString(
                en: "Days without a reading simply mean nothing was recorded — not that anything is wrong.",
                ar: "الأيام بلا قراءة تعني ببساطة أنه لم يُسجَّل شيء — لا أن هناك خطأً ما."))
    }

    static let all: [MetricFamilyExplainer] = [
        MetricFamilyExplainer(
            family: .heart,
            whatItIs: LocalizedString(
                en: "How your heart is beating: its rate through the day, its rate when you're at rest, how much the spacing between beats varies, and an estimate of your cardio fitness.",
                ar: "كيف ينبض قلبك: معدله خلال اليوم، ومعدله أثناء الراحة، ومقدار تفاوت المسافة بين النبضات، وتقدير للياقتك القلبية."),
            howItsRecorded: LocalizedString(
                en: "A watch or band senses your pulse optically at the wrist, throughout the day and more often while you're still. Resting heart rate is worked out once a day; cardio fitness is estimated every few days at best, usually from a brisk outdoor walk or run.",
                ar: "تستشعر الساعة أو السوار نبضك ضوئياً من المعصم، طوال اليوم وبمعدل أكبر أثناء سكونك. ويُحسب معدل القلب أثناء الراحة مرة يومياً؛ أما اللياقة القلبية فتُقدَّر كل بضعة أيام على الأكثر، غالباً من مشي سريع أو جري في الخارج."),
            honestyNote: LocalizedString(
                en: "Heart rate variability is measured differently by different devices, so BADAN keeps each source's trend on its own rather than blending them into one number that would belong to neither.",
                ar: "يُقاس تغيّر معدل القلب بطرق مختلفة بين الأجهزة، لذا يحتفظ بدن باتجاه كل مصدر على حدة بدلاً من دمجها في رقم واحد لا يخصّ أياً منها.")),

        MetricFamilyExplainer(
            family: .respiratory,
            whatItIs: LocalizedString(
                en: "Your breathing rate and the oxygen saturation of your blood.",
                ar: "معدل تنفّسك ونسبة تشبّع الأكسجين في دمك."),
            howItsRecorded: LocalizedString(
                en: "Both are mostly recorded while you sleep, and only by devices built to take them. If you don't wear your device overnight, or it doesn't support these, this family stays empty — that's expected, not a fault.",
                ar: "يُسجَّل كلاهما غالباً أثناء نومك، وبالأجهزة المصمّمة لقياسهما فقط. وإذا لم ترتدِ جهازك ليلاً أو كان لا يدعمهما، تبقى هذه المجموعة فارغة — وهذا متوقّع وليس خللاً."),
            honestyNote: LocalizedString(
                en: "These are wellness readings from a consumer sensor, not a clinical measurement, and BADAN doesn't evaluate them. A range shown here describes your own recorded history and nothing more.",
                ar: "هذه قراءات عافية من مستشعر استهلاكي، لا قياس سريري، وبدن لا يقيّمها. والنطاق المعروض هنا يصف سجلّك أنت ولا شيء غير ذلك.")),

        MetricFamilyExplainer(
            family: .activity,
            whatItIs: LocalizedString(
                en: "How much you moved: steps, distance covered, flights climbed, and the energy your body used — the part you burn moving, and the part it uses just keeping you going.",
                ar: "مقدار حركتك: الخطوات والمسافة المقطوعة والطوابق المصعودة، والطاقة التي استهلكها جسمك — الجزء الذي تحرقه بالحركة، والجزء الذي يستهلكه جسمك لمجرد استمراره."),
            howItsRecorded: LocalizedString(
                en: "Counted continuously by the motion sensors in whatever you're carrying or wearing. Your phone and your watch often both count the same walk, so BADAN asks Apple Health for the already-combined daily total rather than adding the two together itself.",
                ar: "تُحصى باستمرار عبر مستشعرات الحركة في ما تحمله أو ترتديه. وكثيراً ما يحصي هاتفك وساعتك المشية نفسها، لذا يطلب بدن من تطبيق صحة آبل الإجمالي اليومي المدموج مسبقاً بدلاً من جمع الاثنين بنفسه."),
            honestyNote: LocalizedString(
                en: "Energy burned is an estimate everywhere it appears — no wearable measures it directly. It's most useful compared against your own other days, not against a target.",
                ar: "الطاقة المحروقة تقدير أينما ظهرت — فلا جهاز يقيسها مباشرة. وأنفع ما فيها مقارنتها بأيامك الأخرى، لا بهدف محدّد.")),

        MetricFamilyExplainer(
            family: .body,
            whatItIs: LocalizedString(
                en: "Measurements of your body itself: weight, body fat, lean mass, and your height.",
                ar: "قياسات جسمك نفسه: الوزن ونسبة الدهون والكتلة الصافية وطولك."),
            howItsRecorded: LocalizedString(
                en: "These only exist for days you actually measured. Weight usually comes from a connected scale; body fat and lean mass need a scale that estimates them. Gaps here are normal and mean nothing was measured.",
                ar: "لا توجد هذه إلا في الأيام التي قِست فيها فعلاً. ويأتي الوزن عادةً من ميزان متصل؛ أما نسبة الدهون والكتلة الصافية فتحتاج ميزاناً يقدّرهما. والفجوات هنا طبيعية وتعني أنه لم يُقَس شيء."),
            honestyNote: LocalizedString(
                en: "Body composition from a household scale is an estimate that shifts with hydration and time of day, so its direction over weeks says more than any single reading. Your height is kept as a profile detail rather than charted — it feeds calculations, it isn't a trend.",
                ar: "تقدير تركيب الجسم من ميزان منزلي يتغيّر بحسب ترطيب الجسم ووقت القياس، لذا يقول اتجاهه عبر الأسابيع أكثر مما تقوله أي قراءة مفردة. أما طولك فيُحفظ كتفصيل في ملفك لا كرسم بياني — فهو يغذّي الحسابات وليس اتجاهاً.")),

        MetricFamilyExplainer(
            family: .sleep,
            whatItIs: LocalizedString(
                en: "When you were asleep and in bed, and — where your device records them — the stages you passed through.",
                ar: "أوقات نومك وبقائك في الفراش، ومراحل النوم التي مررت بها حيث يسجّلها جهازك."),
            howItsRecorded: LocalizedString(
                en: "Worked out from movement and heart rate while you wear your device overnight. A night you didn't wear it simply isn't there.",
                ar: "تُستنتج من الحركة ومعدل القلب أثناء ارتدائك جهازك ليلاً. والليلة التي لم ترتدِه فيها لا توجد ببساطة."),
            honestyNote: LocalizedString(
                en: "Stages are inferred, not measured — reliable for how long you slept, directional for how that time was divided up.",
                ar: "المراحل مستنتجة لا مقيسة — موثوقة في مدة نومك، وإرشادية في كيفية توزّع تلك المدة.")),
    ]
}

/// The sheet a Body surface presents for one family: what it is, how it's recorded, the honesty
/// note, and — the practical half — what BADAN can actually read for it on this device.
///
/// The "what BADAN reads" rows come from `HKTypeMap`, so the list is the real read set rather
/// than a prose summary that can quietly fall behind it, and each row carries that type's
/// `BackfillCaveat.explainer` (already bilingual in the type map) — which is EPIC-01 task 8's
/// backfill honesty surfaced where somebody looking at an empty chart will actually meet it.
struct MetricFamilyExplainerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let family: MetricFamily

    private static let howRecordedHeader = LocalizedString(en: "How it's recorded", ar: "كيف يُسجَّل")
    private static let worthKnowingHeader = LocalizedString(en: "Worth knowing", ar: "ما يستحق المعرفة")
    private static let readsHeader = LocalizedString(en: "What BADAN reads for this", ar: "ما يقرأه بدن لهذا")
    private static let notReadYet = LocalizedString(
        en: "Read with your permission, but not charted yet — BADAN would need to work out how it compares to your own usual level first, and it won't show a number it can't stand behind.",
        ar: "يُقرأ بإذنك لكنه غير مرسوم بعد — إذ يحتاج بدن أولاً إلى معرفة كيف يقارَن بمستواك المعتاد، ولن يعرض رقماً لا يستطيع الوقوف خلفه.")
    private static let profileDetail = LocalizedString(
        en: "Kept as a detail in your profile rather than a chart.",
        ar: "يُحفظ كتفصيل في ملفك لا كرسم بياني.")

    private var explainer: MetricFamilyExplainer { MetricFamilyExplainer.forFamily(family) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    Text(env.s(explainer.whatItIs))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    paragraphCard(Self.howRecordedHeader, icon: family.symbolName,
                                  tint: BadanColor.primary, body: explainer.howItsRecorded)
                    paragraphCard(Self.worthKnowingHeader, icon: "info.circle",
                                  tint: BadanColor.info, body: explainer.honestyNote)

                    if !readRows.isEmpty {
                        SectionHeader(Self.readsHeader, language: env.language)
                        BadanCard {
                            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                                ForEach(readRows) { row in
                                    readRow(row)
                                }
                            }
                        }
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(family.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Read rows

    /// One HealthKit type BADAN reads for this family, resolved through the registry so the name
    /// shown is the same bilingual name every other surface uses.
    private struct ReadRow: Identifiable {
        let id: String
        let name: LocalizedString
        let caveat: LocalizedString
        /// True for `.authorizationOnly` rows — asked for, but deliberately not turned into
        /// charted values yet. Marked rather than hidden: a type in the permission sheet that
        /// appears nowhere in the app is precisely the thing that reads as BADAN taking more
        /// than it admits to.
        let isReadButNotCharted: Bool
    }

    private var readRows: [ReadRow] {
        HKTypeMap.table.compactMap { entry -> ReadRow? in
            switch entry.strategy {
            case .authorizationOnly(let reason):
                // These rows carry no `metricId` by construction (`HKTypeMap.validate` enforces
                // it), so their family can't be resolved through the registry — map the two
                // known cases by hand and skip anything new rather than guessing a home for it.
                let (owner, name): (MetricFamily, LocalizedString) = {
                    switch reason {
                    case .profileAttribute:
                        return (.body, LocalizedString(en: "Height", ar: "الطول"))
                    case .awaitingDerivation:
                        return (.body, LocalizedString(en: "Wrist temperature", ar: "حرارة المعصم"))
                    }
                }()
                guard owner == family else { return nil }
                return ReadRow(
                    id: entry.platformType, name: name,
                    caveat: reason == .profileAttribute ? Self.profileDetail : Self.notReadYet,
                    isReadButNotCharted: true)
            case .anchoredSample, .anchoredInterval, .statisticsCumulative:
                guard let metricId = entry.metricId,
                      let definition = env.registry.definition(metricId),
                      definition.familyGroup == family else { return nil }
                return ReadRow(
                    id: entry.platformType, name: definition.displayName,
                    caveat: entry.caveat.explainer, isReadButNotCharted: false)
            }
        }
    }

    private func readRow(_ row: ReadRow) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            HStack(spacing: BadanSpace.space2) {
                Text(env.s(row.name))
                    .font(BadanFont.bodyCompact.weight(.medium))
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
                if row.isReadButNotCharted {
                    PillLabel(env.s(Self.notChartedChip), systemImage: "hourglass",
                              tint: BadanColor.info, filled: false)
                }
            }
            Text(env.s(row.caveat))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // One VoiceOver stop per type instead of three disconnected ones, matching `StatBox`'s
        // combined-label convention.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(env.s(row.name)), \(env.s(row.caveat))")
    }

    private static let notChartedChip = LocalizedString(en: "Not charted yet", ar: "غير مرسوم بعد")

    private func paragraphCard(_ title: LocalizedString, icon: String, tint: Color,
                               body: LocalizedString) -> some View {
        BadanCard {
            HStack(alignment: .top, spacing: BadanSpace.space3) {
                Image(systemName: icon)
                    .imageScale(.medium)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(env.s(title))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(env.s(body))
                        .font(BadanFont.bodyCompact)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
