import SwiftUI

// MARK: - Screen-local bilingual strings

/// Strings only the workout-capture surface needs. Shared vocabulary comes from `Loc`; these
/// fill the gaps with real Arabic. Framing stays neutral — activity is never moralized and a
/// rest day is presented as valid, not as a shortfall.
private enum WorkoutLogStrings {
    static let logMovement = LocalizedString(en: "Log a workout", ar: "سجّل تمريناً")
    static let optionalDetails = LocalizedString(en: "Optional details", ar: "تفاصيل اختيارية")
    static let distance = LocalizedString(en: "Distance", ar: "المسافة")
    static let recentWorkouts = LocalizedString(en: "Recent workouts", ar: "التمارين الأخيرة")
    static let recoverySub = LocalizedString(
        en: "Nothing logged today — rest is part of movement too.",
        ar: "لم تُسجَّل حركة اليوم — الراحة جزء من النشاط أيضاً.")
    static let noneYet = LocalizedString(en: "No workouts in the last two weeks.",
                                         ar: "لا تمارين في الأسبوعين الماضيين.")
    static let effortLight = LocalizedString(en: "Light", ar: "خفيف")
    static let effortHard = LocalizedString(en: "Max effort", ar: "أقصى جهد")
    static let savedManually = LocalizedString(en: "Saved as your own entry", ar: "يُحفَظ كإدخال منك")
    static let rpe = LocalizedString(en: "RPE", ar: "الجهد")
    static let km = LocalizedString(en: "km", ar: "كم")
    static let kcal = LocalizedString(en: "kcal", ar: "سعرة")
    static let meters = LocalizedString(en: "m", ar: "م")
    static let seconds = LocalizedString(en: "s", ar: "ث")
    static let ofScale = LocalizedString(en: "of 10", ar: "من 10")
    static let when = LocalizedString(en: "When", ar: "الوقت")
    static let thisWeek = LocalizedString(en: "This week", ar: "هذا الأسبوع")
    static let sessions = LocalizedString(en: "sessions", ar: "جلسات")
    static let totalTime = LocalizedString(en: "total", ar: "الإجمالي")
    static let highCalorieNotice = LocalizedString(
        en: "That's a lot of calories for one session — double check it.",
        ar: "هذا عدد كبير من السعرات لجلسة واحدة — تحقّق منه.")
    static let highDistanceNotice = LocalizedString(
        en: "That's a long distance — double check it.",
        ar: "هذه مسافة طويلة — تحقّق منها.")
    static let enterMinutes = LocalizedString(en: "Enter minutes", ar: "أدخل الدقائق")
    static let loggedTodayPrefix = LocalizedString(en: "Logged today", ar: "سُجِّل اليوم")
    static let saveErrorTitle = LocalizedString(en: "Couldn't save — try again.", ar: "تعذّر الحفظ — حاول مرة أخرى.")
    static let savedConfirmation = LocalizedString(en: "Saved", ar: "تم الحفظ")
    static let quickRepeatHint = LocalizedString(
        en: "Tap to reuse these details for a new entry",
        ar: "اضغط لإعادة استخدام هذه التفاصيل في إدخال جديد")
    static let openWorkoutHint = LocalizedString(
        en: "Opens the full workout, with its heart rate and route",
        ar: "يفتح التمرين كاملاً مع معدل ضربات القلب والمسار")
    // EPIC-03: the list is no longer manual-only, so its heading no longer implies it is.
    static let history = LocalizedString(en: "Your workouts", ar: "تمارينك")
    static let fromDevice = LocalizedString(en: "From your device", ar: "من جهازك")
    static let setAside = LocalizedString(en: "Set aside", ar: "موضوع جانباً")
    static let setAsideExplanation = LocalizedString(
        en: "You logged this by hand too. The recorded version is shown because it carries more detail — nothing was deleted, and your entry is still in your record and in every export.",
        ar: "سجّلته يدوياً أيضاً. وتُعرض النسخة المسجَّلة تلقائياً لأنها تحمل تفاصيل أكثر — لم يُحذف شيء، وإدخالك ما زال في سجلّك وفي كل تصدير.")
    static let overlapDetail = LocalizedString(en: "{pct}% overlap", ar: "تداخل بنسبة {pct}٪")
    static let whyLabel = LocalizedString(en: "Why?", ar: "لماذا؟")
    static let routeChip = LocalizedString(en: "Route", ar: "مسار")
    static let bpm = LocalizedString(en: "bpm", ar: "ن/د")
}

// MARK: - Activity model

/// The quick-add activity types. `rawValue` is the stable English key stored on the record
/// (matching seeded data); display is bilingual and mirror-safe.
enum WorkoutActivity: String, CaseIterable, Identifiable {
    case run = "Run"
    case walk = "Walk"
    case strength = "Strength"
    case cycle = "Cycle"
    case other = "Other"

    var id: String { rawValue }

    var label: LocalizedString {
        switch self {
        case .run: return LocalizedString(en: "Run", ar: "جري")
        case .walk: return LocalizedString(en: "Walk", ar: "مشي")
        case .strength: return LocalizedString(en: "Strength", ar: "قوة")
        case .cycle: return LocalizedString(en: "Cycle", ar: "دراجة")
        case .other: return LocalizedString(en: "Other", ar: "أخرى")
        }
    }

    var symbol: String {
        switch self {
        case .run: return "figure.run"
        case .walk: return "figure.walk"
        case .strength: return "dumbbell.fill"
        case .cycle: return "bicycle"
        case .other: return "figure.mixed.cardio"
        }
    }

    /// Bilingual label for a stored activity string. Known values resolve to their proper
    /// bilingual label; anything else (e.g. a future HealthKit-sourced activity type not in
    /// this closed set) gets a normalized, title-cased presentation instead of a verbatim
    /// passthrough, so Arabic UI never silently shows raw, un-mirrored English text (OPT-135).
    static func label(forStored raw: String) -> LocalizedString {
        if let known = WorkoutActivity(rawValue: raw) { return known.label }
        let normalized = raw.capitalized
        return LocalizedString(en: normalized, ar: normalized)
    }

    static func symbol(forStored raw: String) -> String {
        WorkoutActivity(rawValue: raw)?.symbol ?? "figure.mixed.cardio"
    }
}

// MARK: - View model

/// The thread-safe slice of `AppEnvironment` the unified-list fetch needs, mirroring
/// `BodyFetchInputs`/`SourcesFetchInputs` (PERF-01): repository references and value types only.
struct WorkoutListFetchInputs {
    var logging: LoggingRepository
    var measurements: MeasurementRepository
    var reconciliation: ReconciliationRepository
    var from: Date
    var to: Date
}

@Observable
@MainActor
final class WorkoutLogViewModel {
    /// The unified history: device-recorded workouts and hand-logged entries in one list, with
    /// suppressed manual twins attached to the ingested row that set them aside (EPIC-03 task 5).
    var items: [UnifiedWorkoutList.Item] = []
    var loggedToday: Bool = false

    /// Snapshotted once per view-model lifetime (i.e. per screen appearance) rather than read
    /// live on every `load`/`save` call, so a timezone change mid-session (e.g. a flight)
    /// can't silently flip the calm "recovery day" messaging or misattribute a save's tz
    /// mid-flow (OPT-136, same fix family as OPT-110).
    let tz: String = TimeZone.current.identifier

    /// Load the last two weeks from BOTH stores and note whether anything is attributed to today.
    ///
    /// (EPIC-03) This used to read `logging.workouts` alone on the main actor. Two things changed
    /// and they are related: the query now also reads `sessions` plus a `forSuppressed` lookup per
    /// manual entry, which is more work than belongs on the main thread — so it moved to a
    /// detached task like every other screen's fetch — and reading `workout_entries` alone is
    /// exactly the bug `IngestionPipeline.dedupWorkouts`' doc warns about, where a watch-recorded
    /// run and its hand-typed twin both appear as separate workouts.
    func load(_ env: AppEnvironment) async {
        let now = env.now()
        let inputs = WorkoutListFetchInputs(
            logging: env.logging, measurements: env.measurements, reconciliation: env.reconciliation,
            from: now.addingTimeInterval(-14 * 86_400), to: now)

        let loaded = await Task.detached(priority: .userInitiated) {
            Self.fetch(inputs)
        }.value

        guard !Task.isCancelled else { return }

        items = loaded
        let startOfToday = DayAttribution.startOfDay(now, tz: tz)
        // Counts suppressed children too: the user DID log a workout today even if an ingested
        // twin is currently standing in for it, and telling them "nothing logged today" would be
        // false and would invite a duplicate entry.
        loggedToday = loaded.contains { item in
            item.startAt >= startOfToday || item.suppressedChildren.contains { $0.entry.startAt >= startOfToday }
        }
    }

    /// Kept `internal` (not `private`) so the list-assembly behaviour is reachable from tests,
    /// matching `BodyViewModel.fetch`.
    ///
    /// A failed read yields an empty list rather than propagating: this screen's primary job is
    /// capture, and a history query that fails must not block someone from logging a workout.
    /// The capture path has its own explicit error handling (OPT-129).
    nonisolated static func fetch(_ inputs: WorkoutListFetchInputs) -> [UnifiedWorkoutList.Item] {
        let manual = (try? inputs.logging.workouts(from: inputs.from, to: inputs.to)) ?? []
        let ingested = (try? inputs.measurements.sessions(kind: .workout, from: inputs.from, to: inputs.to)) ?? []
        // Resolved once per entry into a dictionary rather than passing a closure that queries
        // per lookup: `assemble` consults the lookup twice per suppressed entry (once to attach,
        // once to check its winner is on screen), and a repository round trip per call would make
        // that an N+1 over a list the user scrolls.
        var decisions: [String: ReconciliationDecision] = [:]
        for entry in manual {
            if let decision = try? inputs.reconciliation.forSuppressed(entry.id) {
                decisions[entry.id] = decision
            }
        }
        return UnifiedWorkoutList.assemble(ingested: ingested, manual: manual) { decisions[$0] }
    }

    /// Insert a manual workout ending at `endAt` (usually "now", or a user-picked backdate —
    /// FEAT-140). Throws instead of swallowing a failed write, so the caller can keep the form
    /// intact and tell the user rather than silently clearing it as if the save had succeeded
    /// (OPT-129). The caller reloads; this no longer does, since the reload is now async.
    func save(activity: WorkoutActivity, minutes: Int, rpe: Int,
              energyKcal: Double?, distanceM: Double?, endAt: Date, env: AppEnvironment) throws {
        let entry = WorkoutEntry(
            id: ULID.newID(),
            activityType: activity.rawValue,
            startAt: endAt.addingTimeInterval(-Double(minutes) * 60),
            endAt: endAt,
            tzId: tz,
            energyKcal: energyKcal,
            distanceM: distanceM,
            perceivedEffort: rpe,
            ingestionPath: .manual,
            updatedAt: env.now(),
            originDeviceId: env.deviceId)
        try env.logging.upsertWorkout(entry)
        // (F5) A saved workout changes Timeline and Home's activity module, not just this
        // screen's own list. Without the bump those screens keep showing pre-save data until
        // something else happens to invalidate them — and since this screen's own `.task(id:)`
        // now folds in `dataGeneration`, the bump is also what reloads the list here.
        env.bumpDataGeneration()
    }
}

// MARK: - Screen

/// Under-10-second workout capture, pushed as its own screen. Pick an activity, set duration
/// and perceived effort, optionally add energy + distance + a backdate, then save. Recent
/// workouts sit below; when nothing is logged today a calm "recovery day" note stands in —
/// never a nag.
struct WorkoutLogView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vm = WorkoutLogViewModel()
    /// (EPIC-01 task 5, plan §13.1) This is the "workout surface" the staged-permission plan
    /// names: opening it is what asks for workouts + energy + distance, each behind its own
    /// explainer. The gate itself remembers what has already been asked, so a returning user
    /// sees nothing.
    @State private var permissions = HealthPermissionGate()

    // Capture state
    @State private var activity: WorkoutActivity = .run
    @State private var minutes: Int = 30
    @State private var rpe: Double = 5
    @State private var kcalText: String = ""
    @State private var distanceText: String = ""
    /// When the workout happened. Defaults to "now" but can be backdated to earlier today or
    /// a prior day, matching `SymptomLogView.whenCard` (FEAT-140).
    @State private var loggedAt: Date = Date()
    @State private var maxDate: Date = Date()

    // Direct-entry duration state (UIUX-145): the Stepper stays as the primary control, but a
    // tap on the value opens a numeric field for long/precise durations without dozens of taps.
    @State private var isEditingMinutes = false
    @State private var minutesText: String = ""

    // Save-flow state
    @State private var isSaving = false
    @State private var saveErrorText: String?
    @State private var savedTick = 0
    @State private var showSavedToast = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case kcal, distance, minutesEntry
    }

    private var power: Bool { env.depth.showsPowerDetail }
    private let topAnchor = "workoutFormTop"

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: BadanSpace.space4) {
                    if let today = todaysWorkoutSummary {
                        loggedTodayBanner(today)
                    }
                    activityCard
                        .id(topAnchor)
                    durationCard
                    effortCard
                    optionalCard
                    whenCard
                    saveButton
                    WorkoutHistorySection(items: vm.items, loggedToday: vm.loggedToday) { item in
                        prefill(from: item)
                        withAnimation { proxy.scrollTo(topAnchor, anchor: .top) }
                    }
                }
                .padding(BadanSpace.space4)
            }
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(Loc.logWorkout))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Decimal/number-pad fields have no built-in Return key on iOS — this is the only
            // dismissal affordance for them on a stationary form (EASE-096).
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(env.s(Loc.done)) { focusedField = nil }
            }
        }
        .overlay(alignment: .top) {
            if showSavedToast {
                savedToast
                    .padding(.top, BadanSpace.space2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion), value: showSavedToast)
        .sensoryFeedback(.success, trigger: savedTick)
        .onChange(of: focusedField) { _, newValue in
            if newValue != .minutesEntry { commitMinutesText() }
        }
        .permissionExplainer(permissions)
        // (BUG-12/13 pattern) Keyed on `dataGeneration` as well as the profile, so a background
        // sync that ingests a workout — or suppresses a manual twin — redraws this list instead
        // of leaving it showing the pre-sync history. This screen's own saves bump the same
        // counter, which is what reloads after a save now that `vm.save` no longer does.
        .task(id: WorkoutLogLoadKey(profile: env.profile, generation: env.dataGeneration)) {
            loggedAt = env.now()
            maxDate = env.now()
            await vm.load(env)
        }
        // Separate from the load task on purpose: staging must run once per appearance, not
        // again every time a sync bumps `dataGeneration` — a permission explainer that
        // re-evaluates on every data change is one background wake away from feeling like a nag.
        .task { permissions.request(HealthPermissionBundle.workoutSurface) }
    }

    // MARK: - Logged-today summary

    private var todaysWorkoutSummary: UnifiedWorkoutList.Item? {
        guard vm.loggedToday else { return nil }
        let startOfToday = DayAttribution.startOfDay(env.now(), tz: vm.tz)
        return vm.items
            .filter { $0.startAt >= startOfToday }
            .max(by: { $0.startAt < $1.startAt })
    }

    /// A brief "already logged today" summary above the (otherwise always-blank) capture form,
    /// so a returning user isn't left guessing whether they already logged before filling out
    /// another entry (UIUX-150).
    private func loggedTodayBanner(_ workout: UnifiedWorkoutList.Item) -> some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(env.s(WorkoutLogStrings.loggedTodayPrefix))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    Text("\(env.s(WorkoutActivity.label(forStored: workout.activityType))) · \(env.format.duration(seconds: workout.durationSeconds, unit: "min"))")
                        .font(BadanFont.bodyCompact.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                }
                Spacer(minLength: BadanSpace.space2)
            }
        }
    }

    // MARK: - Form cards

    private var activityCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.activityType))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BadanSpace.space2) {
                        ForEach(WorkoutActivity.allCases) { option in
                            activityPill(option)
                        }
                    }
                    .padding(.vertical, BadanSpace.space1)
                }
            }
        }
    }

    private func activityPill(_ option: WorkoutActivity) -> some View {
        let selected = option == activity
        return Button {
            activity = option
        } label: {
            HStack(spacing: BadanSpace.space1) {
                Image(systemName: option.symbol)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(env.s(option.label))
                    .font(BadanFont.chip)
                    .lineLimit(1)
                if selected {
                    // Pair color with an explicit mark, consistent with the checkmark-plus-
                    // color selection convention used elsewhere (SettingsRadioGroup, Onboarding
                    // depth picker) rather than relying on fill/contrast alone (UIUX-149).
                    Image(systemName: "checkmark")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? BadanColor.onPrimary : BadanColor.textPrimary) // (DS1)
            .padding(.horizontal, BadanSpace.space3)
            .frame(minHeight: BadanSpace.touchMin)
            .background(
                (selected ? BadanColor.primary : BadanColor.surface),
                in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                    .strokeBorder(selected ? Color.clear : BadanColor.separator, lineWidth: 1))
        }
    }

    private var durationCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.duration)) {
                    if power {
                        // Raw seconds are a power-only affordance.
                        Text("\(env.format.integer(minutes * 60)) \(env.s(WorkoutLogStrings.seconds))")
                            .font(BadanFont.chip.monospacedDigit())
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
                HStack(spacing: BadanSpace.space3) {
                    // A Stepper alone needs up to 72 taps for a long session; a tap-to-edit
                    // numeric field gives a fast path for longer/precise durations (UIUX-145).
                    if isEditingMinutes {
                        TextField(env.s(WorkoutLogStrings.enterMinutes), text: $minutesText)
                            .keyboardType(.numberPad)
                            .font(BadanFont.numeralM)
                            .foregroundStyle(BadanColor.textPrimary)
                            .focused($focusedField, equals: .minutesEntry)
                            .frame(minWidth: 60)
                            .onSubmit { commitMinutesText() }
                    } else {
                        Button {
                            minutesText = String(minutes)
                            isEditingMinutes = true
                            focusedField = .minutesEntry
                        } label: {
                            Text(env.format.duration(seconds: Double(minutes) * 60, unit: "min"))
                                .font(BadanFont.numeralM)
                                .foregroundStyle(BadanColor.textPrimary)
                        }
                        .accessibilityHint(Text(env.s(WorkoutLogStrings.enterMinutes)))
                    }
                    Spacer(minLength: BadanSpace.space2)
                    Stepper("", value: $minutes, in: 1...360, step: 5)
                        .labelsHidden()
                        .accessibilityLabel(env.s(Loc.duration))
                }
                .frame(minHeight: BadanSpace.touchMin)
            }
        }
    }

    private func commitMinutesText() {
        guard isEditingMinutes else { return }
        // Arabic-digit aware (BUG-15) — a device set to Arabic can produce Eastern-Arabic
        // glyphs from this field's own `.numberPad` keyboard.
        if let value = DecimalParsing.parseInt(minutesText) {
            minutes = min(max(value, 1), 360)
        }
        isEditingMinutes = false
    }

    private var effortCard: some View {
        let value = Int(rpe.rounded())
        return BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.effort)) {
                    if power {
                        // Raw 0–10 value is a power-only affordance, matching
                        // SymptomLogView.severityCard's identical gate (UIUX-144).
                        Text("\(env.s(WorkoutLogStrings.rpe)) \(env.format.integer(value)) / \(env.format.integer(10))")
                            .font(BadanFont.chip.monospacedDigit())
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }
                // Effort is neutral — a single calm tint, never red/green.
                Slider(value: $rpe, in: 1...10, step: 1)
                    .tint(BadanColor.primary)
                    .accessibilityValue(effortAccessibilityValue(value))
                HStack {
                    Text(env.s(WorkoutLogStrings.effortLight))
                    Spacer(minLength: BadanSpace.space2)
                    Text(env.s(WorkoutLogStrings.effortHard))
                }
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            }
        }
    }

    /// VoiceOver should hear the same Light/Max-effort scale context sighted users see below
    /// the slider, not just a bare number (UIUX-152).
    private func effortAccessibilityValue(_ value: Int) -> String {
        let qualitative: LocalizedString
        switch value {
        case ..<4: qualitative = WorkoutLogStrings.effortLight
        case 4..<8: qualitative = Loc.moderate
        default: qualitative = WorkoutLogStrings.effortHard
        }
        return "\(env.s(qualitative)), \(env.format.integer(value)) \(env.s(WorkoutLogStrings.ofScale))"
    }

    private var optionalCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(WorkoutLogStrings.optionalDetails))
                numberField(icon: "flame", placeholder: env.s(Loc.calories),
                            text: $kcalText, unit: env.s(WorkoutLogStrings.kcal), field: .kcal)
                if let kcal = parseDecimal(kcalText), kcal > Self.kcalPlausibilityCeiling {
                    // Soft, non-blocking notice — never blocks the save, matches the house
                    // style used for far-backdated symptom entries (OPT-132).
                    Text(env.s(WorkoutLogStrings.highCalorieNotice))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.outOfBand)
                }
                themedDivider
                numberField(icon: "ruler", placeholder: env.s(WorkoutLogStrings.distance),
                            text: $distanceText, unit: env.s(WorkoutLogStrings.km), field: .distance)
                if let distance = parseDecimal(distanceText), distance > Self.distancePlausibilityCeilingKm {
                    Text(env.s(WorkoutLogStrings.highDistanceNotice))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.outOfBand)
                }
                if power {
                    Text(env.s(WorkoutLogStrings.savedManually))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }

    private static let kcalPlausibilityCeiling: Double = 3000
    private static let distancePlausibilityCeilingKm: Double = 200

    /// The app's themed separator rule, matching `SettingsScreen.settingsDivider` /
    /// `ExportCenterScreen.rowDivider` — a bare system `Divider()` doesn't pick up custom
    /// theming and looks visibly off, especially in dark mode (UIUX-151).
    private var themedDivider: some View {
        Rectangle()
            .fill(BadanColor.separator)
            .frame(height: 1)
            .padding(.vertical, BadanSpace.space1)
    }

    private func numberField(icon: String, placeholder: String,
                             text: Binding<String>, unit: String, field: Field) -> some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textPrimary)
                .focused($focusedField, equals: field)
            Text(unit)
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
        }
        .frame(minHeight: BadanSpace.touchMin)
    }

    private var whenCard: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "clock")
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
                Text(env.s(WorkoutLogStrings.when))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
                DatePicker("", selection: $loggedAt, in: ...maxDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
            .frame(minHeight: BadanSpace.touchMin)
        }
    }

    private var saveButton: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Button {
                saveTapped()
            } label: {
                Text(env.s(Loc.save))
                    .font(BadanFont.body.weight(.semibold))
                    .foregroundStyle(BadanColor.onPrimary) // (DS1)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: BadanSpace.touchMin)
                    .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    .opacity(isSaving ? 0.6 : 1)
            }
            // Guards against a fast double-tap inserting two near-identical entries
            // (EASE-056 / OPT-131 / UIUX-142).
            .disabled(isSaving)
            if let saveErrorText {
                errorRow(saveErrorText)
            }
        }
    }

    /// Wellness-safe, non-blocking notice — matches `SymptomLogView.errorRow`'s calm tone.
    /// Entered data is left untouched so the user can just tap Save again.
    private func errorRow(_ message: String) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(BadanColor.outOfBand)
                .accessibilityHidden(true)
            Text(message)
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
        }
    }

    private var savedToast: some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            Text(env.s(WorkoutLogStrings.savedConfirmation))
                .font(BadanFont.bodyCompact.weight(.medium))
                .foregroundStyle(BadanColor.textPrimary)
        }
        .padding(.horizontal, BadanSpace.space3)
        .frame(minHeight: BadanSpace.touchMin)
        .background(BadanColor.surfaceElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(BadanColor.separator, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func saveTapped() {
        guard !isSaving else { return }
        isSaving = true
        saveErrorText = nil

        let now = env.now()
        if maxDate < now { maxDate = now }
        let clampedLoggedAt = min(loggedAt, maxDate)

        do {
            try vm.save(activity: activity, minutes: minutes, rpe: Int(rpe.rounded()),
                        energyKcal: parseDecimal(kcalText),
                        distanceM: parseDecimal(distanceText).map { $0 * 1000 },
                        endAt: clampedLoggedAt, env: env)
        } catch {
            // Stay calm and non-destructive; keep the form intact so nothing entered is lost,
            // and tell the user so they know to retry (OPT-129).
            isSaving = false
            saveErrorText = env.s(WorkoutLogStrings.saveErrorTitle)
            Announce.failure(env.s(WorkoutLogStrings.saveErrorTitle)) // (A3)
            return
        }

        isSaving = false
        // `vm.save` bumps `dataGeneration`, which re-fires the `.task(id:)` above; this is the
        // belt-and-braces reload for the case where SwiftUI coalesces the two into one pass
        // before the write is visible. Idempotent — a second load just re-reads the same rows.
        Task { await vm.load(env) }
        // Keep the altitude and activity; clear the one-off measurements and backdate pick.
        kcalText = ""
        distanceText = ""
        loggedAt = env.now()
        maxDate = env.now()
        savedTick += 1 // light haptic confirmation (UIUX-143)
        Announce.status(env.s(WorkoutLogStrings.savedConfirmation)) // (A3) haptic + toast are both non-verbal
        showSavedToast = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            showSavedToast = false
        }
    }

    // MARK: - Quick-repeat

    /// Pre-fills the capture form from a past workout so a recurring routine doesn't need to be
    /// re-entered from scratch every session (FEAT-144).
    ///
    /// Works from an ingested row as well as a manual one now that the list carries both — but
    /// the activity only transfers when the stored string is one of the quick-add cases.
    /// Ingested rows carry `HKTypeMap` slugs (`running`, `traditional_strength`), which are
    /// deliberately NOT force-mapped onto the five-case picker: a wrong guess silently files the
    /// new entry under the wrong activity, and duration and effort — the fields people actually
    /// re-enter — transfer either way.
    private func prefill(from workout: UnifiedWorkoutList.Item) {
        if let matched = WorkoutActivity(rawValue: workout.activityType) {
            activity = matched
        }
        let minutesFromDuration = Int((workout.durationSeconds / 60).rounded())
        minutes = min(max(minutesFromDuration, 1), 360)
        if let effort = workout.perceivedEffort {
            rpe = Double(effort)
        }
    }

    // MARK: - Helpers

    private func parseDecimal(_ text: String) -> Double? {
        guard let value = DecimalParsing.parse(text), value > 0 else { return nil }
        return value
    }
}

// MARK: - Workout history (unified)

/// The read-only history below the capture form: ingested workouts and hand-logged entries in
/// one list (EPIC-03 task 5).
///
/// Extracted into its own view identity so RPE slider drags, activity picker taps, and text-field
/// edits in the capture form above don't force SwiftUI to re-diff this list on every keystroke
/// (PERF-078). Because chip/formatter work only re-runs when this view's own inputs
/// (`items`/`loggedToday`) actually change, this also addresses PERF-077's repeated per-row
/// formatting cost — which matters more now that a row can carry children.
private struct WorkoutHistorySection: View {
    @Environment(AppEnvironment.self) private var env
    let items: [UnifiedWorkoutList.Item]
    let loggedToday: Bool
    let onSelect: (UnifiedWorkoutList.Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(WorkoutLogStrings.history))
            if !loggedToday {
                recoveryCard
            }
            if items.isEmpty {
                // `loggedToday` is derived from the very same array this empties from, so it
                // can never be true here — the old `if loggedToday` guard around this text made
                // it permanently unreachable, silently hiding the empty state entirely for a
                // brand-new user (UIUX-147).
                Text(env.s(WorkoutLogStrings.noneYet))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            } else {
                if let summary = weeklySummary {
                    weekSummaryCard(summary)
                }
                ForEach(items) { item in
                    WorkoutHistoryRow(item: item, onSelect: onSelect)
                }
            }
        }
    }

    private var recoveryCard: some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "leaf")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(BadanColor.primary)
                    .frame(width: BadanSpace.touchMin, height: BadanSpace.touchMin)
                    .background(BadanColor.primary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(env.s(Loc.recoveryDay))
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(env.s(WorkoutLogStrings.recoverySub))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: BadanSpace.space2)
            }
        }
    }

    /// A light weekly training-load rollup (sessions + total time) above the raw list, so the
    /// screen carries a little compounding, non-alarming insight instead of only a flat history
    /// (FEAT-171).
    ///
    /// Counts unified items, so a workout recorded by a watch AND typed by hand contributes once
    /// rather than twice — which is the whole reason the suppressed twin hangs off its parent
    /// instead of sitting beside it.
    private var weeklySummary: (sessions: Int, minutes: Int)? {
        let now = env.now()
        let weekStart = now.addingTimeInterval(-7 * 86_400)
        let recentWeek = items.filter { $0.startAt >= weekStart }
        guard !recentWeek.isEmpty else { return nil }
        let totalMinutes = Int((recentWeek.reduce(0.0) { $0 + $1.durationSeconds } / 60).rounded())
        return (recentWeek.count, totalMinutes)
    }

    private func weekSummaryCard(_ summary: (sessions: Int, minutes: Int)) -> some View {
        BadanCard {
            HStack(spacing: BadanSpace.space3) {
                Image(systemName: "chart.bar")
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(env.s(WorkoutLogStrings.thisWeek))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    Text("\(env.format.integer(summary.sessions)) \(env.s(WorkoutLogStrings.sessions)) · \(env.format.duration(seconds: Double(summary.minutes) * 60, unit: "min")) \(env.s(WorkoutLogStrings.totalTime))")
                        .font(BadanFont.bodyCompact.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                }
                Spacer(minLength: BadanSpace.space2)
            }
        }
    }
}

// MARK: - One history row

/// One workout in the list, from either store.
///
/// The two origins behave differently on tap, and that difference is the point: an ingested row
/// opens `WorkoutDetailScreen` (it has a heart-rate trace, effort bands, possibly a route), while
/// a manual row re-fills the capture form above it (FEAT-144's quick-repeat), because a manual
/// entry has no detail beyond what this row already shows. The accessibility hint states which
/// one will happen rather than leaving both as an untyped tap.
private struct WorkoutHistoryRow: View {
    @Environment(AppEnvironment.self) private var env
    let item: UnifiedWorkoutList.Item
    let onSelect: (UnifiedWorkoutList.Item) -> Void

    private var power: Bool { env.depth.showsPowerDetail }

    private var isIngested: Bool {
        if case .ingested = item.origin { return true }
        return false
    }

    var body: some View {
        if case .ingested(let sessionId, _, _, _) = item.origin {
            NavigationLink {
                WorkoutDetailScreen(sessionId: sessionId)
            } label: {
                card
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(WorkoutLogStrings.openWorkoutHint, language: env.language))
        } else {
            Button { onSelect(item) } label: { card }
                .buttonStyle(.plain)
                .accessibilityHint(Text(WorkoutLogStrings.quickRepeatHint, language: env.language))
        }
    }

    private var card: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                HStack(spacing: BadanSpace.space3) {
                    Image(systemName: WorkoutActivity.symbol(forStored: item.activityType))
                        .foregroundStyle(BadanColor.primary)
                        .accessibilityHidden(true)
                    Text(env.s(WorkoutActivity.label(forStored: item.activityType)))
                        .font(BadanFont.body.weight(.medium))
                        .foregroundStyle(BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    Text(env.format.duration(seconds: item.durationSeconds, unit: "min"))
                        .font(BadanFont.bodyCompact.monospacedDigit())
                        .foregroundStyle(BadanColor.textSecondary)
                }

                let chips = detailChips
                if !chips.isEmpty {
                    // Wraps rather than clipping: an ingested ride can carry four chips, which
                    // do not fit on one line at larger Dynamic Type sizes.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: BadanSpace.space2)],
                              alignment: .leading, spacing: BadanSpace.space2) {
                        ForEach(chips.indices, id: \.self) { index in
                            chips[index]
                        }
                    }
                }

                HStack(spacing: BadanSpace.space2) {
                    Text(relativeDateText(item.startAt))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    Spacer(minLength: BadanSpace.space2)
                    // Origin is stated on every row, at every altitude. "Where did this come
                    // from" is the first question a mixed list provokes, and answering it only
                    // in power mode would leave casual users looking at two visually identical
                    // rows with different meanings.
                    PillLabel(env.s(isIngested ? WorkoutLogStrings.fromDevice : WorkoutLogStrings.savedManually),
                              systemImage: isIngested ? "applewatch" : "square.and.pencil",
                              tint: BadanColor.textSecondary, filled: false)
                    if case .ingested(_, _, _, let hasRoute) = item.origin, hasRoute {
                        PillLabel(env.s(WorkoutLogStrings.routeChip), systemImage: "map",
                                  tint: BadanColor.textSecondary, filled: false)
                    }
                }

                if power {
                    rawLine
                    ProvenanceRow(sourceName: env.s(isIngested ? WorkoutLogStrings.fromDevice
                                                              : WorkoutLogStrings.savedManually),
                                  ingestionPath: item.ingestionPath,
                                  timestamp: item.startAt,
                                  language: env.language)
                }

                ForEach(item.suppressedChildren) { child in
                    SuppressedChildRow(child: child)
                }
            }
        }
    }

    private var detailChips: [PillLabel] {
        var chips: [PillLabel] = []
        if let rpe = item.perceivedEffort {
            chips.append(PillLabel("\(env.s(WorkoutLogStrings.rpe)) \(env.format.integer(rpe))",
                                   systemImage: "gauge"))
        }
        if let kcal = item.energyKcal {
            chips.append(PillLabel("\(env.format.integer(Int(kcal.rounded()))) \(env.s(WorkoutLogStrings.kcal))",
                                   systemImage: "flame"))
        }
        if let distance = item.distanceMeters {
            chips.append(PillLabel("\(env.format.number(distance / 1000, fraction: 1)) \(env.s(WorkoutLogStrings.km))",
                                   systemImage: "ruler"))
        }
        if let avgHr = item.avgHeartRateBpm {
            chips.append(PillLabel("\(env.format.integer(Int(avgHr.rounded()))) \(env.s(WorkoutLogStrings.bpm))",
                                   systemImage: "heart"))
        }
        return chips
    }

    private var rawLine: some View {
        var parts: [String] = ["\(env.format.integer(Int(item.durationSeconds.rounded()))) \(env.s(WorkoutLogStrings.seconds))"]
        if let distance = item.distanceMeters {
            parts.append("\(env.format.integer(Int(distance.rounded()))) \(env.s(WorkoutLogStrings.meters))")
        }
        return Text(parts.joined(separator: " · "))
            .font(BadanFont.caption.monospacedDigit())
            .foregroundStyle(BadanColor.textSecondary)
    }

    // Cached once per type instead of allocating a fresh formatter per row per render
    // (PERF-076), and — matching `LogHubScreen.relativeTime` — expressed as relative phrasing
    // ("Today, 3:12 PM") rather than an always-absolute date, consistent with the app's other
    // "recent items" surface (UIUX-148).
    private static let cachedRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func relativeDateText(_ date: Date) -> String {
        Self.cachedRelativeFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.cachedRelativeFormatter.localizedString(for: date, relativeTo: env.now())
    }
}

// MARK: - Suppressed manual twin (I3)

/// A hand-logged entry the row above it currently stands in for.
///
/// **This row is the I3 guarantee made visible.** The pipeline never deletes or edits the manual
/// entry — it journals a reversible decision in `dedup_decisions` and leaves the row alone — but
/// a list that filtered it out would show the user exactly what a deletion looks like. So it is
/// rendered in place, indented under its twin, labelled "set aside" rather than "removed", with
/// a "Why?" disclosure carrying the overlap the rule actually measured.
///
/// Muted, not hidden, and deliberately NOT behind the power-mode gate: a casual user is the one
/// most likely to conclude their entry was thrown away.
private struct SuppressedChildRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let child: UnifiedWorkoutList.Child

    @State private var showsWhy = false

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Rectangle().fill(BadanColor.separator).frame(height: 1)
            HStack(spacing: BadanSpace.space2) {
                Image(systemName: "arrow.turn.down.right")
                    .imageScale(.small)
                    .foregroundStyle(BadanColor.textSecondary)
                    .accessibilityHidden(true)
                Text(env.s(WorkoutActivity.label(forStored: child.entry.activityType)))
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textSecondary)
                Text(env.format.duration(seconds: child.entry.durationSeconds, unit: "min"))
                    .font(BadanFont.caption.monospacedDigit())
                    .foregroundStyle(BadanColor.textSecondary)
                Spacer(minLength: BadanSpace.space2)
                PillLabel(env.s(WorkoutLogStrings.setAside), tint: BadanColor.textSecondary, filled: false)
            }

            Button {
                withAnimation(BadanMotion.easeInOut(BadanMotion.quick, reduceMotion: reduceMotion)) {
                    showsWhy.toggle()
                }
            } label: {
                Text(env.s(WorkoutLogStrings.whyLabel))
                    .font(BadanFont.link)
                    .foregroundStyle(BadanColor.primary)
                    .frame(minHeight: BadanSpace.touchMin, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(showsWhy ? .isSelected : [])

            if showsWhy {
                VStack(alignment: .leading, spacing: BadanSpace.space1) {
                    Text(env.s(WorkoutLogStrings.setAsideExplanation))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let percent = child.lineage.overlapPercent {
                        Text(env.s(WorkoutLogStrings.overlapDetail
                            .filling(["pct": env.format.number(percent, fraction: 0)])))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    LText(Loc.reversible)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    if env.depth.showsPowerDetail {
                        // The journaled rule id, styled as the technical identifier it is and
                        // pinned LTR in Arabic — matching how algorithm/rule strings are shown
                        // in `MetricAnatomySheet`.
                        Text("\(child.lineage.rule)@\(child.lineage.ruleVersion)")
                            .font(BadanFont.caption.monospaced())
                            .foregroundStyle(BadanColor.textSecondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
        }
        .padding(.leading, BadanSpace.space3)
    }
}

/// (BUG-12/13 pattern) The standardized `.task(id:)` identity — see `HomeLoadKey`
/// (`HomeScreen.swift`). Folding in `dataGeneration` is what makes the unified list self-correct
/// when a background sync ingests a workout that suppresses an entry already on screen.
private struct WorkoutLogLoadKey: Equatable {
    let profile: CustomizationProfile
    let generation: Int
}
