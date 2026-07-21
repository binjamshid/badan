import SwiftUI

/// The hydration Today card on the Log tab (plan §16.1): calm progress, one-tap favorites, and a few
/// recents — the ≤2-second / ≤2-action log surface. Deliberately compact; "See all" opens the full
/// module for editing, goals, favorites and the weekly card. The undo affordance for a log made here
/// is hosted by `LogHubScreen` (pinned to the screen bottom), reading this same view model.
struct HydrationTodayCard: View {
    @Environment(AppEnvironment.self) private var env

    var vm: HydrationViewModel
    /// Opens the custom amount/beverage/time sheet (hosted by the caller).
    var onCustom: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space3) {
            SectionHeader(env.s(HydrationStrings.moduleTitle)) {
                NavigationLink { HydrationScreen() } label: {
                    HStack(spacing: BadanSpace.space1) {
                        Text(env.s(HydrationStrings.seeAll))
                            .font(BadanFont.link)
                        Image(systemName: "chevron.forward")
                            .imageScale(.small)
                    }
                    .foregroundStyle(BadanColor.primary)
                }
                .buttonStyle(.plain)
            }

            BadanCard {
                VStack(spacing: BadanSpace.space4) {
                    HydrationProgressRing(
                        fraction: vm.progress.fraction,
                        centerValue: env.format.integer(Int(vm.todayTotalMl.rounded())),
                        centerUnit: env.s(HydrationStrings.ml),
                        caption: caption,
                        accessibilityText: accessibilityProgress)
                        .frame(maxWidth: .infinity)

                    HydrationFavoritesRow(
                        favorites: vm.favorites,
                        onTap: { vm.log(favorite: $0, env: env) },
                        onCustom: onCustom)

                    if !recents.isEmpty {
                        recentsRow
                    }
                }
            }
        }
    }

    // The three most recent drinks, as read-only reference chips (repeat/edit lives on the full screen).
    private var recents: [HydrationEntry] { Array(vm.todayEntries.prefix(3)) }

    private var recentsRow: some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            Text(env.s(HydrationStrings.recentDrinks))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BadanSpace.space2) {
                    ForEach(recents) { entry in
                        recentChip(entry)
                    }
                }
            }
        }
    }

    private func recentChip(_ entry: HydrationEntry) -> some View {
        let volume = HydrationStrings.volume(entry.volumeMl, formatter: env.format, language: env.language)
        let time = relativeTime(entry.occurredAt)
        return HStack(spacing: BadanSpace.space1) {
            Image(systemName: "drop.fill")
                .imageScale(.small)
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            Text(volume)
                .font(BadanFont.chip)
                .foregroundStyle(BadanColor.textPrimary)
            Text("· \(time)")
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
        }
        .padding(.horizontal, BadanSpace.space3)
        .frame(minHeight: BadanSpace.touchMin)
        .background(BadanColor.surfaceElevated, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volume), \(time)")
    }

    private var caption: String {
        if let target = vm.progress.goalTargetMl {
            return HydrationStrings.ofTarget(
                HydrationStrings.volume(target, formatter: env.format, language: env.language),
                language: env.language)
        }
        return env.s(HydrationStrings.loggedToday)
    }

    private var accessibilityProgress: String {
        let current = HydrationStrings.volume(vm.todayTotalMl, formatter: env.format, language: env.language)
        let target = vm.progress.goalTargetMl.map {
            HydrationStrings.volume($0, formatter: env.format, language: env.language)
        }
        return HydrationStrings.progressReadout(current: current, target: target, language: env.language)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func relativeTime(_ date: Date) -> String {
        Self.relativeFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.relativeFormatter.localizedString(for: date, relativeTo: env.now())
    }
}
