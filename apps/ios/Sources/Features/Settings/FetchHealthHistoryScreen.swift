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

    /// (AUDIT 2026-08-06) Replaces `noUndoNote`, which promised this "never changes or removes what
    /// you already have". That was false when it was written and is deliberately false now.
    ///
    /// It was already false because the historical walk goes through the ordinary pipeline: it
    /// re-runs sleep dedup and rewrites nightly rollups for every night it touches. INGESTION-01 is
    /// precisely that — this screen silently flipping which source won a stored night, because the
    /// walk resolved every source priority to 0.
    ///
    /// It is now deliberately false because correcting a stored value against Health is the whole
    /// point: re-reading is how a user repairs the daily totals INGESTION-02 truncated, and those
    /// rows can only be repaired by overwriting them (`interval_records` is a true in-place upsert
    /// with no revision chain, so the correct total survives nowhere on the device).
    ///
    /// What IS still true, and is what the copy now promises instead: manual entries are untouched.
    /// The upsert key is `(metric_id, external_id, source_id)` and a hand-logged row carries
    /// neither a HealthKit external id nor the HealthKit source, so no re-read can address it.
    static let correctsExistingNote = LocalizedString(
        en: "This re-reads from Health. Missing readings are added, and stored readings that "
            + "disagree with Health are corrected to match it. Anything you logged by hand in "
            + "BADAN is never touched, and running it again is safe.",
        ar: "يعيد هذا القراءة من تطبيق الصحة. تُضاف القراءات الناقصة، وتُصحَّح القراءات المخزّنة "
            + "التي تخالف ما لدى الصحة لتطابقه. أمّا ما سجّلته بنفسك في بادن فلا يُمَسّ، وتكراره آمن.")

    /// Why a user who never wanted older history might still want to run this. Names the two
    /// defects plainly and says what re-reading fixes, without dressing either up as a feature.
    ///
    /// Deliberately not a dismissible one-time banner keyed to a version flag: BADAN cannot tell
    /// which installs were affected (a truncated daily total is indistinguishable from a genuinely
    /// quiet day — that is the whole reason the repair has to be a blind re-read), so an alert
    /// claiming "your data is wrong" would be a guess presented as a fact. This states the
    /// condition and lets the user decide, the same posture `nothingReturned` takes.
    static let repairNote = LocalizedString(
        en: "Worth running once: a fault fixed in this version could leave some daily totals "
            + "older than 90 days lower than they should be, and could score a night from the "
            + "wrong source. Re-reading the affected period corrects both.",
        ar: "يُستحسن تشغيله مرّة: خلل عولج في هذا الإصدار قد يترك بعض المجاميع اليومية الأقدم من "
            + "٩٠ يوماً أقل مما ينبغي، وقد يحتسب ليلة من المصدر الخطأ. إعادة قراءة الفترة المتأثرة "
            + "تصحّح الأمرين.")
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

                repairCard

                if env.isHistoricalImportRunning {
                    runningCard
                } else {
                    presetCard
                    if env.hasResumableHistoricalImport { resumeCard }
                }

                if let outcome = env.historicalImportOutcome { outcomeCard(outcome) }

                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    LText(FetchHistoryCopy.sleepCaveat)
                    LText(FetchHistoryCopy.correctsExistingNote)
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

    /// (AUDIT 2026-08-06) The repair prompt. Shown unconditionally rather than gated on a
    /// "was this install affected" flag, because that flag cannot honestly be computed — see
    /// `FetchHistoryCopy.repairNote`.
    private var repairCard: some View {
        BadanCard {
            LText(FetchHistoryCopy.repairNote)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
