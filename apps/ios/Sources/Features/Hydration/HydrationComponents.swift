import SwiftUI

/// A horizontal row of one-tap favorites — the ≤2-action log surface. Each button logs immediately;
/// its accessibility label always names the exact volume (and the favorite's name when it has one),
/// so a VoiceOver user hears what a tap will log before committing it. An optional trailing "Custom"
/// button opens the full amount/beverage/time sheet.
struct HydrationFavoritesRow: View {
    @Environment(AppEnvironment.self) private var env

    var favorites: [HydrationFavorite]
    var onTap: (HydrationFavorite) -> Void
    var onCustom: (() -> Void)?
    /// When provided, a saved favorite (not a built-in default) offers Delete in its context menu.
    var onDelete: ((HydrationFavorite) -> Void)?
    var disabled: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BadanSpace.space2) {
                ForEach(favorites) { favorite in
                    Button { onTap(favorite) } label: { label(for: favorite) }
                        .buttonStyle(.plain)
                        .disabled(disabled)
                        .accessibilityLabel(accessibilityLabel(for: favorite))
                        .contextMenu { deleteMenu(for: favorite) }
                }
                if let onCustom {
                    Button { onCustom() } label: { customLabel }
                        .buttonStyle(.plain)
                        .disabled(disabled)
                        .accessibilityLabel(env.s(HydrationStrings.addDrink))
                }
            }
            .padding(.vertical, BadanSpace.space1)
        }
    }

    @ViewBuilder
    private func deleteMenu(for favorite: HydrationFavorite) -> some View {
        if let onDelete, !favorite.isDefault {
            Button(role: .destructive) { onDelete(favorite) } label: {
                Label(env.s(HydrationStrings.deleteFavorite), systemImage: "trash")
            }
        }
    }

    private func label(for favorite: HydrationFavorite) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            HStack(spacing: BadanSpace.space1) {
                Image(systemName: "drop.fill")
                    .imageScale(.small)
                    .foregroundStyle(BadanColor.primary)
                    .accessibilityHidden(true)
                Text(volumeText(favorite.volumeMl))
                    .font(BadanFont.body.weight(.semibold))
                    .foregroundStyle(BadanColor.textPrimary)
                    .lineLimit(1)
            }
            if let name = favorite.name {
                Text(env.s(name))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, BadanSpace.space3)
        .frame(minHeight: BadanSpace.touchMin)
        .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                .strokeBorder(BadanColor.separator, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
        .accessibilityElement(children: .ignore)
    }

    private var customLabel: some View {
        HStack(spacing: BadanSpace.space1) {
            Image(systemName: "plus")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(env.s(HydrationStrings.custom))
                .font(BadanFont.body.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(BadanColor.primary)
        .padding(.horizontal, BadanSpace.space3)
        .frame(minHeight: BadanSpace.touchMin)
        .background(BadanColor.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
    }

    private func volumeText(_ ml: Double) -> String {
        HydrationStrings.volume(ml, formatter: env.format, language: env.language)
    }

    private func accessibilityLabel(for favorite: HydrationFavorite) -> String {
        HydrationStrings.logAction(volume: volumeText(favorite.volumeMl),
                                   favoriteName: favorite.name.map { env.s($0) },
                                   language: env.language)
    }
}

/// One logged drink, for the full screen's "Today's drinks" list. Names the drink, its volume and the
/// time; an "Edited" badge is honest that a row was revised (the append-first chain is not hidden).
/// Read as one VoiceOver phrase that leads with the volume.
struct HydrationDrinkRow: View {
    @Environment(AppEnvironment.self) private var env

    var entry: HydrationEntry
    var beverageName: LocalizedString

    var body: some View {
        HStack(spacing: BadanSpace.space3) {
            Image(systemName: "drop.fill")
                .foregroundStyle(BadanColor.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                HStack(spacing: BadanSpace.space2) {
                    Text(volumeText)
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.textPrimary)
                    if entry.isRevised {
                        PillLabel(env.s(HydrationStrings.editedBadge), tint: BadanColor.textSecondary)
                    }
                }
                Text(env.s(beverageName))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Spacer(minLength: BadanSpace.space2)
            Text(timeText)
                .font(BadanFont.caption.monospacedDigit())
                .foregroundStyle(BadanColor.textSecondary)
        }
        .padding(.horizontal, BadanSpace.space4)
        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin, alignment: .leading)
        .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                .strokeBorder(BadanColor.separator, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volumeText), \(env.s(beverageName)), \(timeText)")
    }

    private var volumeText: String {
        HydrationStrings.volume(entry.volumeMl, formatter: env.format, language: env.language)
    }

    private static let timeFormatter = DateFormatter()

    private var timeText: String {
        let formatter = Self.timeFormatter
        formatter.locale = Locale(identifier: env.language.localeIdentifier)
        formatter.timeStyle = .short
        return formatter.string(from: entry.occurredAt)
    }
}
