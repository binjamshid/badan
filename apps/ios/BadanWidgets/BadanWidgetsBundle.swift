import WidgetKit
import SwiftUI
import UIKit
import Foundation

/// EPIC-33 wave 1 (Phase 3D): ring_single, one_true_sentence, meds_due, sleep_last_night. Replaces
/// the placeholder that previously verified the extension target/entitlements/app-group wiring —
/// that placeholder widget is deleted entirely, not kept alongside these.
@main
struct BadanWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RingSingleWidget()
        SentenceWidget()
        MedsDueWidget()
        SleepCardWidget()
        EffortRingWidget()
    }
}

// MARK: - Small shared helpers, deliberately duplicated across the app/extension boundary
//
// This target cannot import `apps/ios/Sources/DesignSystem/Tokens.swift`,
// `apps/ios/Sources/Core/Localization/AppLanguage.swift`, or
// `apps/ios/Sources/Platform/Notifications/NotificationDecisionEngine.swift` — see
// `AmbientSnapshotDto.swift`'s header comment for why. The helpers below are small, hand-picked
// mirrors of pieces of each (plus `WidgetLanguage`, which has no main-app equivalent to mirror —
// it exists purely to stop the four widgets' own fallback logic from drifting), kept intentionally
// minimal (only what these four widgets actually need), living here since this file is every
// widget's shared entry point.

/// A hand-picked mirror of `BadanColor`'s brand teal + text/surface tokens
/// (`Sources/DesignSystem/Tokens.swift`), used only by the two Home Screen families
/// (`.systemSmall`/`.systemMedium`). Deliberately NOT applied on the accessory (Lock Screen/
/// StandBy) families below — WidgetKit renders those in a single system-chosen tint colour and
/// ignores any custom `Color` a widget applies there, so accessory bodies in this target draw with
/// the default foreground only and let the system tint it.
enum WidgetColor {
    static let primary = Color(light: "#157A6E", dark: "#5BC5BA")
    static let textPrimary = Color(light: "#17191C", dark: "#F2F3F5")
    static let textSecondary = Color(light: "#5C636D", dark: "#9AA1AB")
    static let surface = Color(light: "#FFFFFF", dark: "#16191E")
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255.0
        let g = Double((value & 0x00FF00) >> 8) / 255.0
        let b = Double(value & 0x0000FF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// Same light/dark trait-resolution approach as `Sources/DesignSystem/Tokens.swift`'s
    /// `Color.init(light:dark:)`, reimplemented here rather than imported.
    init(light: String, dark: String) {
        let lightColor = UIColor(Color(hex: light))
        let darkColor = UIColor(Color(hex: dark))
        self.init(UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
    }
}

/// A tiny bilingual-string helper local to this target — deliberately NOT the main app's
/// `LocalizedString` (`Sources/Core/Localization/AppLanguage.swift`), which this target cannot
/// import. `AmbientSnapshotDto.language` ("en"/"ar") is the only signal any widget here has for
/// which half to read; there is no live app setting to consult from this process.
struct WidgetCopy {
    let en: String
    let ar: String
    func resolved(isArabic: Bool) -> String { isArabic ? ar : en }
}

/// The one place all four widgets in this wave decide Arabic vs. English/LTR — extracted here
/// (rather than each view repeating `entry.snapshot?.language == "ar"` inline) specifically so the
/// fallback rule below can't drift out of sync across the four copies again.
///
/// `snapshot.language` is authoritative whenever a snapshot exists: it mirrors the user's in-app
/// language CHOICE (`AppLanguage.rawValue` on the main-app side), which the DTO carries explicitly
/// because this process has no live app-language setting to read, and that in-app choice can
/// differ from the device's system locale.
///
/// Only when NO snapshot has ever been written — e.g. an Arabic-locale user adds a BADAN widget
/// from the Home Screen before ever launching the app once — do we fall back to the SYSTEM locale,
/// this target's only remaining signal of the user's likely language. Hardcoding English/LTR for
/// that gap (the previous behavior) silently mis-renders for exactly the users this fallback
/// exists to help.
enum WidgetLanguage {
    static func isArabic(
        for snapshot: AmbientSnapshotDto?,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Bool {
        if let language = snapshot?.language {
            return language == "ar"
        }
        // `preferredLanguages` entries look like "en-US" / "ar-SA" / "ar" — compare only the
        // leading language subtag (split on "-") so a code like "arn" (Mapudungun) never
        // false-matches the way a bare `hasPrefix("ar")` would.
        guard let topLanguage = preferredLanguages.first else { return false }
        let languageCode = topLanguage.split(separator: "-").first.map(String.init) ?? topLanguage
        return languageCode == "ar"
    }
}

/// A minimal, local mirror of the raw-value tokens this wave's widgets need from the main app's
/// `NotificationDeepLink` (`Sources/Platform/Notifications/NotificationDecisionEngine.swift`) —
/// this target cannot import that type, but a tap on any of these widgets MUST encode the SAME
/// raw string ("readiness", "sleep", "meds") so that whichever main-app URL handler eventually
/// parses a `badan://deeplink/<token>` URL constructs a real, existing `NotificationDeepLink`
/// case rather than a token that enum has never heard of. Only the three tokens actually used
/// below are mirrored; add another only alongside the matching real case, in the same change.
/// `WidgetDeepLinkTests.swift` (`apps/ios/Tests/`) is the one place both sides are checked against
/// each other, since that test target links the real `BADAN` module and this one cannot.
///
/// KNOWN GAP, stated plainly rather than hidden: as of this wave, `BADAN` registers no
/// `CFBundleURLTypes` scheme and no `.onOpenURL` handler anywhere (`AppEnvironment.openDeepLink`
/// is today fed only from `UNUserNotificationCenterDelegate`'s `userInfo` — see
/// `BADANApp.swift`'s `notificationDelegate.onOpen`). Tapping one of these widgets opens BADAN
/// today but does not yet route anywhere inside it. Wiring a `badan://` URL scheme into the main
/// app's `Info.plist`/`project.yml` plus a `.onOpenURL` that turns the token back into a
/// `NotificationDeepLink` and calls `AppEnvironment.openDeepLink(_:)` is main-app work
/// (`apps/ios/App/`, `apps/ios/Sources/App/`) — out of `apps/ios/BadanWidgets/`'s scope for this
/// slice. These tokens are shaped so that wiring, whenever it lands, needs no change on this side.
enum WidgetDeepLinkToken: String {
    case readiness
    case sleep
    case meds

    var url: URL { URL(string: "badan://deeplink/\(rawValue)")! }
}
