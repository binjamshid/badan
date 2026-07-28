import SwiftUI

/// "Sync now" — the manual override for `SyncDebounce`.
///
/// Automatic foreground syncs are debounced to five minutes, which is correct for the common case
/// (glancing at a notification and coming back should not re-query HealthKit) but is exactly what
/// makes the app feel stuck: you open it wanting fresh numbers, `syncIfStale` returns silently,
/// nothing changes, and there is no way to insist. This is the way to insist.
///
/// Deliberately shows the last attempt time rather than only a spinner. "Nothing happened" and
/// "something happened and there was nothing new" look identical otherwise, and the second is by
/// far the more common outcome — a sync that finds no new samples is a success, not a failure, and
/// the timestamp is the only thing that says so.
struct SyncNowRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Button {
                    env.forceSync()
                    Announce.status(env.s(SyncNowCopy.started))
                } label: {
                    HStack(spacing: BadanSpace.space3) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .imageScale(.medium)
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SyncNowCopy.title, language: env.language)
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                            Text(subtitle, language: env.language)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                        Spacer(minLength: BadanSpace.space2)
                        if env.isSyncInFlight {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Disabled rather than hidden when a sync is already running: a button that
                // vanishes mid-tap is worse than one that visibly waits.
                .disabled(env.isSyncInFlight || !env.isHealthKitConnected)
            }
        }
    }

    private var subtitle: LocalizedString {
        guard env.isHealthKitConnected else { return SyncNowCopy.notConnected }
        if env.isSyncInFlight { return SyncNowCopy.running }
        guard let last = env.lastSyncAt else { return SyncNowCopy.never }
        return SyncNowCopy.lastAttempt(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))
    }
}

enum SyncNowCopy {
    static let title = LocalizedString(en: "Sync now", ar: "مزامنة الآن")
    static let started = LocalizedString(en: "Syncing", ar: "جارٍ المزامنة")
    static let running = LocalizedString(en: "Checking Health for new readings…",
                                         ar: "جارٍ البحث عن قراءات جديدة في «الصحة»…")
    static let never = LocalizedString(en: "Not synced yet this session",
                                       ar: "لم تتم المزامنة بعد في هذه الجلسة")
    static let notConnected = LocalizedString(en: "Connect Apple Health first",
                                              ar: "اربط «صحة Apple» أولاً")
    /// Says "attempted", not "updated": the sync may legitimately have found nothing new, and
    /// claiming an update that did not happen is the kind of small lie this codebase avoids.
    static func lastAttempt(_ relative: String) -> LocalizedString {
        LocalizedString(en: "Last checked \(relative)", ar: "آخر فحص \(relative)")
    }
}
