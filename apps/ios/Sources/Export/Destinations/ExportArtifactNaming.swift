import Foundation

/// EPIC-14 — the folder scheme and file-naming convention, in one place on each platform.
///
/// `BADAN/Exports/<year>/<month>/` and `BADAN_<template-or-bundle>_<YYYYMMDD>-<YYYYMMDD>[_partN].<ext>`
/// are a published contract, not a formatting preference: a user who has been dropping exports into
/// an iCloud folder for a year has a directory their own scripts glob over, and a "tidier" name in a
/// later release silently splits their archive in two. The Android mirror
/// (`ExportArtifactNaming.kt`) is byte-identical by construction and `ExportDestinationsTests`
/// pins the exact strings on both platforms so a change here fails a fixture rather than a user's
/// folder.
enum ExportArtifactNaming {

    /// The fixed root every BADAN export lives under, regardless of where the user pointed us.
    static let rootFolder = "BADAN"
    static let exportsFolder = "Exports"

    /// Fallback slug when a template name sanitizes to nothing (see `slug`).
    static let bundleLabel = "bundle"

    /// Longest slug we will put in a filename. The rest of the name is bounded (`BADAN_` + two
    /// 8-digit dates + a separator + `_partNN` + extension ≈ 45 characters), so 60 keeps the whole
    /// filename inside the 255-byte limit every file provider imposes, with room for a provider
    /// that appends its own " 2" on a name collision.
    static let maxSlugLength = 60

    // MARK: - Folder scheme

    /// `["BADAN", "Exports", "2026", "07"]` — the components, not a joined path, because SAF on
    /// Android walks them one `createDocument` at a time and a joined string would just have to be
    /// split again.
    ///
    /// Bucketed by the **run** instant, not by the data's date range. A "last 30 days" export run on
    /// 2 August covers July, and filing it under `2026/07` would put this month's export in last
    /// month's folder — the folder answers "when did BADAN write this", the filename answers "what
    /// is inside it", and conflating the two makes the directory listing lie about both.
    static func folderComponents(runDate: Date, timeZone: TimeZone) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: runDate)
        // Gregorian year/month regardless of the user's calendar preference, and ASCII digits
        // regardless of their numeral preference — see `dateStamp` for why display formatting has
        // no business here.
        let year = String(format: "%04d", parts.year ?? 1970)
        let month = String(format: "%02d", parts.month ?? 1)
        return [rootFolder, exportsFolder, year, month]
    }

    /// The same components as a display/logging path (`BADAN/Exports/2026/07`). Always
    /// forward-slashed and always relative to the destination root: an absolute path would carry
    /// the app container UUID or the user's file-provider layout into `ExportDeliveryReceipt`, and
    /// from there into an Export Health screenshot.
    static func folderPath(runDate: Date, timeZone: TimeZone) -> String {
        folderComponents(runDate: runDate, timeZone: timeZone).joined(separator: "/")
    }

    // MARK: - File naming

    /// `BADAN_weekly-vitals_20260701-20260707.csv`, or `…_part2.csv` when the export was split.
    ///
    /// - Parameters:
    ///   - label: the template name, or `nil` for an ad-hoc builder export (which has no template —
    ///     see `ExportRun.templateId`) and therefore files under `bundle`.
    ///   - part: `nil` for a single-file export. 1-based when present, so a reader who sees
    ///     `_part2` knows to look for `_part1` — a 0-based `_part0` reads as a bug report.
    static func fileName(label: String?, start: Date, end: Date, part: Int? = nil,
                         fileExtension: String, timeZone: TimeZone) -> String {
        let stampedStart = dateStamp(start, timeZone: timeZone)
        let stampedEnd = dateStamp(end, timeZone: timeZone)
        var name = "\(rootFolder)_\(slug(label))_\(stampedStart)-\(stampedEnd)"
        if let part, part >= 1 { name += "_part\(part)" }
        return "\(name).\(fileExtension)"
    }

    /// `YYYYMMDD` in the given zone, with **ASCII digits, always**.
    ///
    /// This is the one place in the codebase where the Arabic-numeral preference must not reach.
    /// `ValueFormatter` renders Arabic-Indic digits (٢٠٢٦٠٧٠١) for display and that is correct
    /// everywhere a human reads a number — but a filename is storage identity: an Arabic-digit
    /// filename does not sort next to its English-digit siblings in the same folder, does not match
    /// a user's `BADAN_*_2026*` glob, and changes if the user switches language. Hence
    /// `String(format:)` over a `DateFormatter` carrying a locale at all.
    static func dateStamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Turn a user-chosen template name into a filename-safe slug.
    ///
    /// Deliberately **keeps non-Latin letters**. Transliterating or stripping Arabic would mean a
    /// user whose templates are named in Arabic gets a folder full of files called
    /// `BADAN_bundle_…` that they cannot tell apart — the exact "Arabic is a second-class locale"
    /// failure VS-5 exists to prevent. Both APFS and every SAF provider handle Unicode filenames.
    ///
    /// What it does remove:
    ///  - Bidi control characters (U+200E/F, U+202A–U+202E, U+2066–U+2069). These are invisible,
    ///    they survive a copy/paste, and an embedded RLO can make `…_part1.csv` *render* as
    ///    `…vsc.1trap_` — a filename that looks like one type and opens as another. A mixed
    ///    Arabic/ASCII name still lays out right-to-left without them; the app just never writes
    ///    an explicit override into storage identity. `CharacterSet.controlCharacters` is Unicode
    ///    categories Cc and Cf, and every bidi control listed above is Cf, so it covers them all.
    ///  - Path separators and the Windows-reserved set, so a slug cannot escape its directory or
    ///    become unwritable on an exFAT drive the user syncs the folder to.
    ///  - Leading dots, which would hide the file on every Unix-derived filesystem.
    static func slug(_ label: String?) -> String {
        guard let label else { return bundleLabel }

        let reserved: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "_"]

        var out = ""
        var pendingSeparator = false
        for character in label {
            // Cc (control) and Cf (format, which is where every bidi control lives) — dropped.
            let isControl = character.unicodeScalars.allSatisfy {
                CharacterSet.controlCharacters.contains($0)
            }
            if isControl { continue }

            // `_` joins me to the reserved set even though filesystems accept it: it is this
            // convention's own field separator, so a template named "weekly_vitals" would
            // otherwise produce a name with five underscore-delimited fields where a parser
            // expects three or four.
            if character.isWhitespace || reserved.contains(character) || character == "-" {
                pendingSeparator = !out.isEmpty
                continue
            }
            if pendingSeparator {
                out.append("-")
                pendingSeparator = false
            }
            out.append(character)
            if out.count >= maxSlugLength { break }
        }

        // A name made entirely of separators and control characters leaves nothing to file under.
        // `bundle` is the honest answer — it is what an export with no template is already called,
        // and it never collides with the date range that follows it.
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return trimmed.isEmpty ? bundleLabel : trimmed
    }
}
