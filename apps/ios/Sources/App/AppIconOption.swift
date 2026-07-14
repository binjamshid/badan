import Foundation
import Observation
import UIKit

/// The set of selectable app icons. `.noorRadiant` is the default (system) icon — it has no
/// alternate icon name because it ships as the primary `AppIcon` asset, not an alternate.
/// The rest map 1:1 to `.appiconset` names already added to `Assets.xcassets` and to
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in project.yml.
enum AppIconOption: String, CaseIterable, Identifiable {
    case noorRadiant
    case noorMono
    case noorQalam
    case mizan
    case hilal

    var id: String { rawValue }

    /// `nil` selects the primary app icon; any other value is passed to
    /// `UIApplication.setAlternateIconName(_:)` and must match an `.appiconset` name exactly.
    var alternateIconName: String? {
        switch self {
        case .noorRadiant: return nil
        case .noorMono: return "NoorMono"
        case .noorQalam: return "NoorQalam"
        case .mizan: return "Mizan"
        case .hilal: return "Hilal"
        }
    }

    /// The imageset used to preview this icon in the Settings picker.
    var previewAsset: String {
        switch self {
        case .noorRadiant: return "IconPreviewDefault"
        case .noorMono: return "IconPreviewMono"
        case .noorQalam: return "IconPreviewQalam"
        case .mizan: return "IconPreviewMizan"
        case .hilal: return "IconPreviewHilal"
        }
    }

    var title: LocalizedString {
        switch self {
        case .noorRadiant: return LocalizedString(en: "Noor", ar: "نور")
        case .noorMono: return LocalizedString(en: "Noor Line", ar: "نور · خط")
        case .noorQalam: return LocalizedString(en: "Noor Qalam", ar: "نور · قلم")
        case .mizan: return LocalizedString(en: "Mizan", ar: "ميزان")
        case .hilal: return LocalizedString(en: "Hilal", ar: "هلال")
        }
    }

    var subtitle: LocalizedString {
        switch self {
        case .noorRadiant: return LocalizedString(en: "Light — default", ar: "ضياء — الافتراضي")
        case .noorMono: return LocalizedString(en: "Clean monoline", ar: "خط بسيط")
        case .noorQalam: return LocalizedString(en: "Calligraphic", ar: "خط عربي")
        case .mizan: return LocalizedString(en: "Instrument", ar: "دقيق")
        case .hilal: return LocalizedString(en: "Crescent", ar: "هلال جوهري")
        }
    }

    /// Maps an alternate icon name reported by `UIApplication` back to an option.
    /// `nil` (or an unrecognised name) resolves to the default icon.
    fileprivate static func from(alternateIconName name: String?) -> AppIconOption {
        guard let name else { return .noorRadiant }
        return AppIconOption.allCases.first { $0.alternateIconName == name } ?? .noorRadiant
    }
}

/// Reads/drives the app's home-screen icon via `UIApplication`. iOS presents its own system
/// alert when the icon changes — that's expected and not suppressed here.
@Observable
@MainActor
final class AppIconController {
    private(set) var current: AppIconOption

    /// EDGE-16: whether this device/runtime can switch icons at all — some simulators and
    /// contexts report `false`. `SettingsScreen` uses this to disable the alternate-icon rows
    /// (with reduced opacity) instead of leaving them tappable no-ops.
    var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }

    init() {
        current = AppIconOption.from(alternateIconName: UIApplication.shared.alternateIconName)
    }

    /// Switches to `option`'s icon. Returns `true` on success — including the already-current
    /// no-op case, since nothing needed to change and nothing failed — and `false` if the
    /// platform doesn't support alternate icons or the underlying `setAlternateIconName` call
    /// itself failed.
    ///
    /// EDGE-16: every failure used to be swallowed silently, so a rejected icon switch (or a tap
    /// on a device that can't switch icons at all) looked identical to a successful one. An icon
    /// switch still can't crash the app — the failure is reported, not thrown — but the caller
    /// can now tell the difference and say so (see `SettingsScreen.showTransientNotice`).
    @discardableResult
    func select(_ option: AppIconOption) async -> Bool {
        guard UIApplication.shared.supportsAlternateIcons else { return false }
        guard option != current else { return true }
        do {
            try await UIApplication.shared.setAlternateIconName(option.alternateIconName)
            current = option
            return true
        } catch {
            return false
        }
    }
}
