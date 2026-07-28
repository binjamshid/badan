import SwiftUI

enum FetchHistoryCopy {
    static let title = LocalizedString(en: "Fetch Health history", ar: "جلب سجل الصحة")
    static let blurb = LocalizedString(
        en: "BADAN reads the last 90 days from Health automatically. Use this to bring in older "
            + "readings that are already stored in Health.",
        ar: "يقرأ بادن آخر ٩٠ يوماً من تطبيق الصحة تلقائياً. استخدم هذا لجلب قراءات أقدم مخزّنة "
            + "بالفعل في الصحة.")

    static let lastYear = LocalizedString(en: "Last year", ar: "السنة الماضية")
    static let lastTwoYears = LocalizedString(en: "Last 2 years", ar: "آخر سنتين")
    static let everything = LocalizedString(en: "Everything available", ar: "كل المتاح")

    static let start = LocalizedString(en: "Fetch", ar: "جلب")
    static let cancel = LocalizedString(en: "Stop", ar: "إيقاف")
    static let resume = LocalizedString(en: "Resume", ar: "استئناف")
    static let resumable = LocalizedString(
        en: "A previous fetch did not finish. Resuming picks up where it stopped.",
        ar: "لم يكتمل جلب سابق. الاستئناف يكمل من حيث توقّف.")

    static let probing = LocalizedString(en: "Checking what Health has…", ar: "جارٍ فحص ما لدى الصحة…")
    static let deriving = LocalizedString(en: "Scoring what arrived…", ar: "جارٍ حساب ما وصل…")

    static func fetching(_ index: String, _ total: String) -> LocalizedString {
        LocalizedString(en: "Fetching month \(index) of \(total)…", ar: "جلب الشهر \(index) من \(total)…")
    }

    static func imported(_ n: String) -> LocalizedString {
        LocalizedString(en: "Added \(n) readings.", ar: "تمت إضافة \(n) قراءة.")
    }

    /// Outcome 2. Rows came back and BADAN already had every one of them. This is a success and has
    /// to read as one — a re-fetch is a no-op by construction, and "reimport" is just this feature
    /// run again rather than a second mechanism.
    static let alreadyUpToDate = LocalizedString(
        en: "Already up to date — everything Health has for this period is already in BADAN.",
        ar: "محدَّث بالفعل — كل ما لدى الصحة لهذه الفترة موجود في بادن.")

    /// Outcome 1, and the one that must not overclaim. HealthKit never tells an app that a READ was
    /// denied — only whether the permission sheet completed — so "nothing was recorded then" and
    /// "BADAN was not granted these types" are genuinely indistinguishable from here. Saying which
    /// one it is would be a guess presented as a fact.
    static let nothingReturned = LocalizedString(
        en: "Health returned nothing for this period. That can mean nothing was recorded then — or "
            + "that BADAN wasn't given access to some types. Health doesn't tell apps which.",
        ar: "لم يُرجع تطبيق الصحة شيئاً لهذه الفترة. قد يعني ذلك عدم تسجيل أي شيء آنذاك — أو أن "
            + "بادن لم يُمنح صلاحية لبعض الأنواع. لا يخبر تطبيق الصحة التطبيقات بأيّهما.")

    static let cancelledNote = LocalizedString(
        en: "Stopped. What was already fetched has been kept and scored.",
        ar: "تم الإيقاف. ما جُلب بالفعل تم الاحتفاظ به وحسابه.")

    /// The same limitation `RecomputeScoresCopy` states, repeated here because this is where a user
    /// importing years of history will meet it.
    static let sleepCaveat = LocalizedString(
        en: "Imported nights keep their sleep records, but only roughly the last month of nights "
            + "gets a sleep score.",
        ar: "تحتفظ الليالي المستوردة بسجلات نومها، لكن درجة النوم تُمنح تقريباً لليالي الشهر الأخير فقط.")

    static let noUndoNote = LocalizedString(
        en: "This adds readings from Health; it never changes or removes what you already have. "
            + "Running it again is safe.",
        ar: "يضيف هذا قراءات من تطبيق الصحة؛ ولا يغيّر أو يحذف ما لديك. تكراره آمن.")
}

/// Settings → Backup & restore → Fetch Health history (D-35 item 2b).
///
/// Deliberately NOT bolted onto `SyncNowRow`. That button is a debounce override on the anchored
/// live path; conflating "sync now" with "fetch 2019" would misdescribe both — one asks for what
/// changed since the last anchor, the other asks for a window the anchor system cannot reach at all.
struct FetchHealthHistoryScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var preset: Preset = .lastYear

    enum Preset: CaseIterable, Identifiable {
        case lastYear, lastTwoYears, everything
        var id: Self { self }

        var label: LocalizedString {
            switch self {
            case .lastYear: return FetchHistoryCopy.lastYear
            case .lastTwoYears: return FetchHistoryCopy.lastTwoYears
            case .everything: return FetchHistoryCopy.everything
            }
        }

        /// How far back to ask. "Everything available" is bounded at ten years rather than being
        /// unbounded: the walk issues one query per type per month, and an open-ended start would
        /// spend hundreds of queries on years before the user owned a device. Health has nothing
        /// older than its own first sample regardless, so the clamp costs no real data.
        var days: Int {
            switch self {
            case .lastYear: return 365
            case .lastTwoYears: return 730
            case .everything: return 3650
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                LText(FetchHistoryCopy.blurb)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if env.isHistoricalImportRunning {
                    runningCard
                } else {
                    presetCard
                    if env.hasResumableHistoricalImport { resumeCard }
                }

                if let outcome = env.historicalImportOutcome { outcomeCard(outcome) }

                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    LText(FetchHistoryCopy.sleepCaveat)
                    LText(FetchHistoryCopy.noUndoNote)
                }
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(FetchHistoryCopy.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var presetCard: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            BadanCard {
                SettingsRadioGroup(
                    options: Preset.allCases,
                    title: { $0.label.resolved(env.language) },
                    subtitle: { _ in "" },
                    isOn: { $0 == preset }
                ) { preset = $0 }
            }
            Button {
                let now = Date()
                env.startHistoricalImport(
                    from: DayAttribution.addingDays(-preset.days, to: now, tz: TimeZone.current.identifier),
                    to: now)
            } label: {
                Text(FetchHistoryCopy.start, language: env.language)
                    .font(BadanFont.body)
                    .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!env.isHealthKitConnected)
        }
    }

    private var runningCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(spacing: BadanSpace.space3) {
                    ProgressView().controlSize(.small)
                    Text(phaseLabel, language: env.language)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                }
                Button(role: .cancel) { env.cancelHistoricalImport() } label: {
                    Text(FetchHistoryCopy.cancel, language: env.language)
                        .font(BadanFont.link)
                        .frame(minHeight: BadanSpace.touchMin)
                }
            }
        }
    }

    private var resumeCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                LText(FetchHistoryCopy.resumable)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { env.resumeHistoricalImport() } label: {
                    Text(FetchHistoryCopy.resume, language: env.language)
                        .font(BadanFont.link)
                        .frame(minHeight: BadanSpace.touchMin)
                }
            }
        }
    }

    private func outcomeCard(_ outcome: HistoricalImportOutcome) -> some View {
        BadanCard {
            LText(outcomeText(outcome))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The three outcomes, kept distinct. See each copy constant for why conflating them would be
    /// a claim BADAN cannot support.
    private func outcomeText(_ outcome: HistoricalImportOutcome) -> LocalizedString {
        switch outcome {
        case .nothingReturned: return FetchHistoryCopy.nothingReturned
        case .alreadyUpToDate: return FetchHistoryCopy.alreadyUpToDate
        case .imported(let written): return FetchHistoryCopy.imported(env.format.integer(written))
        case .cancelled: return FetchHistoryCopy.cancelledNote
        case .failed(let message): return LocalizedString(en: message, ar: message)
        }
    }

    private var phaseLabel: LocalizedString {
        switch env.historicalImport?.phase {
        case .fetching(let index, let total):
            return FetchHistoryCopy.fetching(env.format.integer(index), env.format.integer(total))
        case .deriving: return FetchHistoryCopy.deriving
        default: return FetchHistoryCopy.probing
        }
    }
}
