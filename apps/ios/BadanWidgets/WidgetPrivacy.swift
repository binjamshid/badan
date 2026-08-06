import WidgetKit
import SwiftUI

/// W-11 (EPIC-44 wave 1) — the extension's half of the ambient privacy model.
///
/// The main app already does the load-bearing work: in `.off` it assembles no personal content at
/// all, so there is nothing here to hide, and `MedsDueWidget` structurally cannot render on a Lock
/// Screen because it registers no accessory family (see its own header, and the ratchet test that
/// keeps it that way). This type covers the remaining case — `.discreet`, where the content IS
/// present because a ring still has to draw its arc, but no number or sentence may be shown.
///
/// Two independent mechanisms, deliberately. A user-facing setting must never be the only thing
/// standing between sensitive content and a stranger holding the phone, so the rule that matters
/// most is enforced by what the app writes and by which families a widget registers — neither of
/// which this file can weaken.
///
/// A third, OS-level one sits underneath both and is not expressed here at all (S-5): every
/// value-bearing view in the Lock-Screen-capable widgets is marked `.privacySensitive()`, so iOS
/// itself redacts those values while the device is locked, in EVERY mode including `.standard`.
/// The flags below are about who may see a value when the owner is looking at the screen;
/// `.privacySensitive()` is about who may see it when they are not. iOS does not apply that
/// redaction to accessory families on its own — the modifier has to be written at each value, and
/// `AmbientPrivacyTests` fails if a widget registers an accessory family without one.
enum WidgetPrivacy {
    /// Whether this widget may draw numbers and sentences.
    ///
    /// `family` decides which flag applies: an accessory family only ever renders on the Lock
    /// Screen or in the Smart Stack, where `lockScreenValuesAllowed` governs. A snapshot that
    /// predates W-11 decodes to `.standard`, so an older file behaves exactly as it did.
    static func allowsValues(_ snapshot: AmbientSnapshotDto?, family: WidgetFamily) -> Bool {
        guard let privacy = snapshot?.privacy else { return true }
        return isAccessory(family) ? privacy.lockScreenValuesAllowed : privacy.valuesAllowed
    }

    /// Whether any personal content may be drawn at all.
    static func allowsContent(_ snapshot: AmbientSnapshotDto?) -> Bool {
        snapshot?.privacy.contentAllowed ?? true
    }

    static func isAccessory(_ family: WidgetFamily) -> Bool {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: return true
        default: return false
        }
    }

    /// What a widget shows instead of a value when values are withheld. Not "—" or a blank: a
    /// placeholder that reads as missing data would send someone into the app to investigate a
    /// problem that does not exist. This says the data is here and deliberately not being shown.
    static let hiddenPlaceholder = WidgetCopy(en: "Hidden", ar: "مخفي")
    static let hiddenHint = WidgetCopy(en: "Open BADAN to see", ar: "افتح بدن للاطلاع")
}
