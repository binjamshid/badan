import Foundation
import UIKit

/// Renders a `ReportModel` to a shareable PDF (EPIC-31), in two stages that keep the offline
/// guarantee intact and the RTL-correctness testable:
///
/// 1. `renderHTML` — a **pure**, self-contained HTML document (all CSS inline; NO `<img>`, `<link>`,
///    `<script>`, or any external reference), so generation touches nothing on the network. This is
///    the stage that decides Arabic RTL: the Arabic document is emitted `<html lang="ar" dir="rtl">`
///    with `direction: rtl` styling, which `UIMarkupTextPrintFormatter` honours — asserted by
///    `ReportRendererTests` both at the markup level and on the produced page, which is read back
///    with PDFKit to check the Arabic title is laid against the RIGHT margin.
/// 2. `renderPDF` — the thin UIKit stage that lays that markup onto A4 pages. UIKit only; no
///    networking import, so this file keeps `Sources/Export/`'s zero-network lint green (D-8 / plan
///    §8.3): a report is an export artifact GENERATED offline, and its only network-touching act
///    would be *delivery*, which belongs to `Sources/Export/Destinations/` — not here.
///
/// The wording comes entirely from `ReportPresentation`, the same copy the on-screen surface uses,
/// so the PDF and the in-app view can never drift.
enum ReportRenderer {

    // MARK: - HTML (pure, offline)

    static func renderHTML(_ model: ReportModel, language: AppLanguage, arabicDigits: Bool) -> String {
        let dir = language.isRTL ? "rtl" : "ltr"
        let align = language.isRTL ? "right" : "left"
        var body = ""

        body += "<h1>\(esc(ReportPresentation.title(model.periodKind).resolved(language)))</h1>"
        body += "<p class=\"period\">\(esc(ReportPresentation.periodLabel(model, language: language, arabicDigits: arabicDigits)))</p>"

        if !model.hasSufficientData {
            body += "<p class=\"empty\">\(esc(ReportPresentation.emptyMessage(model.periodKind).resolved(language)))</p>"
        }

        for section in model.sections {
            body += "<section>"
            body += "<h2>\(esc(ReportPresentation.sectionTitle(section.kind).resolved(language)))</h2>"
            switch section.kind {
            case .sleep, .effort, .readiness:
                for m in section.metrics { body += metricBlock(m, model: model, language: language, arabicDigits: arabicDigits) }
            case .changes:
                for c in section.changes { body += changeBlock(c, model: model, language: language, arabicDigits: arabicDigits) }
            case .adherence:
                if let a = section.adherence { body += adherenceBlock(a, model: model, language: language, arabicDigits: arabicDigits) }
            }
            body += "</section>"
        }

        body += "<footer class=\"disclaimer\">\(esc(ReportPresentation.disclaimer.resolved(language)))</footer>"

        return """
        <!DOCTYPE html>
        <html lang="\(language.rawValue)" dir="\(dir)">
        <head>
        <meta charset="utf-8">
        <style>
        body { font-family: -apple-system, sans-serif; color: #1a1a1a; direction: \(dir); text-align: \(align); margin: 0; }
        h1 { font-size: 22px; margin: 0 0 4px; }
        h2 { font-size: 16px; margin: 20px 0 8px; border-bottom: 1px solid #ddd; padding-bottom: 4px; }
        p { font-size: 13px; line-height: 1.5; margin: 6px 0; }
        p.period { color: #666; margin-top: 0; }
        p.empty { color: #666; font-style: italic; }
        p.narrative { margin: 4px 0; }
        p.evidence { color: #888; font-size: 11px; margin: 2px 0 12px; }
        table { border-collapse: collapse; font-size: 12px; margin: 4px 0 8px; }
        td { padding: 2px 12px 2px 0; }
        td.label { color: #666; }
        footer.disclaimer { margin-top: 28px; color: #666; font-size: 11px; border-top: 1px solid #ddd; padding-top: 8px; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func metricBlock(_ m: MetricSummary, model: ReportModel, language: AppLanguage, arabicDigits: Bool) -> String {
        let mean = ReportPresentation.number(m.mean ?? 0, language, arabicDigits, fractionDigits: 0)
        let lo = ReportPresentation.number(m.min ?? 0, language, arabicDigits, fractionDigits: 0)
        let hi = ReportPresentation.number(m.max ?? 0, language, arabicDigits, fractionDigits: 0)
        let latest = ReportPresentation.number(m.latest ?? 0, language, arabicDigits, fractionDigits: 0)
        var out = "<p class=\"narrative\">\(esc(ReportPresentation.metricNarrative(m, kind: model.periodKind, language: language, arabicDigits: arabicDigits)))</p>"
        out += "<table>"
        out += row(ReportPresentation.averageLabel.resolved(language), mean)
        out += row(ReportPresentation.rangeLabel.resolved(language), "\(lo)–\(hi)")
        out += row(ReportPresentation.latestLabel.resolved(language), latest)
        out += "</table>"
        out += evidenceLine(m.evidence, count: m.count, language: language, arabicDigits: arabicDigits)
        return out
    }

    private static func changeBlock(_ c: ChangeItem, model: ReportModel, language: AppLanguage, arabicDigits: Bool) -> String {
        var out = "<p class=\"narrative\">\(esc(ReportPresentation.changeNarrative(c, kind: model.periodKind, language: language, arabicDigits: arabicDigits)))</p>"
        out += evidenceLine(c.evidence, count: c.evidence.count, language: language, arabicDigits: arabicDigits)
        return out
    }

    private static func adherenceBlock(_ a: AdherenceSummary, model: ReportModel, language: AppLanguage, arabicDigits: Bool) -> String {
        var out = "<p class=\"narrative\">\(esc(ReportPresentation.adherenceNarrative(a, kind: model.periodKind, language: language, arabicDigits: arabicDigits)))</p>"
        out += evidenceLine(a.evidence, count: a.logged, language: language, arabicDigits: arabicDigits)
        return out
    }

    /// The transparency line: a human "Based on N records" plus every evidence id carried in a
    /// `data-evidence` attribute, so a claim's evidence is present in the artifact itself (and
    /// assertable in tests) rather than only in the model.
    private static func evidenceLine(_ refs: [EvidenceRef], count: Int, language: AppLanguage, arabicDigits: Bool) -> String {
        let ids = refs.map { $0.id }.joined(separator: ",")
        let phrase = ReportPresentation.evidenceCountPhrase(count, language: language, arabicDigits: arabicDigits)
        return "<p class=\"evidence\" data-evidence=\"\(esc(ids))\">\(esc(phrase))</p>"
    }

    private static func row(_ label: String, _ value: String) -> String {
        "<tr><td class=\"label\">\(esc(label))</td><td>\(esc(value))</td></tr>"
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - PDF (UIKit, offline)

    /// Convenience: model → PDF data in one call.
    @MainActor
    static func renderPDF(_ model: ReportModel, language: AppLanguage, arabicDigits: Bool) -> Data {
        renderPDF(html: renderHTML(model, language: language, arabicDigits: arabicDigits))
    }

    /// Lay self-contained HTML onto A4 pages via `UIMarkupTextPrintFormatter`. `@MainActor` because
    /// UIKit's print/graphics stack expects the main thread; the background weekly trigger persists
    /// only the model + metadata and defers rendering to when the user opens or shares a report.
    @MainActor
    static func renderPDF(html: String) -> Data {
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        // A4 in points, with a 0.5in margin.
        let pageSize = CGSize(width: 595.2, height: 841.8)
        let margin: CGFloat = 36
        let paperRect = CGRect(origin: .zero, size: pageSize)
        let printableRect = paperRect.insetBy(dx: margin, dy: margin)
        // `numberOfPages` is only correct once the page geometry is set, and `UIPrintPageRenderer`
        // exposes these only through KVC — the long-standing idiom for driving it outside a print job.
        renderer.setValue(paperRect, forKey: "paperRect")
        renderer.setValue(printableRect, forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paperRect, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        let bounds = UIGraphicsGetPDFContextBounds()
        for page in 0..<max(1, renderer.numberOfPages) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: bounds)
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
}
