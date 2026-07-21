package net.albayyan.badan.export

import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.text.Layout
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.domain.reports.ReportModel
import net.albayyan.badan.domain.reports.ReportPresentation
import net.albayyan.badan.domain.reports.ReportSectionKind
import java.io.ByteArrayOutputStream

/**
 * Renders a [ReportModel] to a shareable PDF (EPIC-31), in two stages that keep the offline guarantee
 * intact and the RTL-correctness testable. Mirror of iOS `ReportRenderer.swift`.
 *
 * 1. [document] / [renderHtml] — the **pure** stage. [document] resolves the model's numbers into the
 *    ordered, already-localized blocks a report says, and [renderHtml] serializes exactly those blocks
 *    into a self-contained HTML document (all CSS inline; NO `<img>`, `<link>`, `<script>`, or any
 *    external reference), so generation touches nothing on the network. This is also the stage that
 *    decides direction: an Arabic document is `isRtl`, emitted `<html lang="ar" dir="rtl">` with
 *    `direction: rtl` styling, and drawn right-to-left below — asserted by `ReportRendererTest` on the
 *    document/markup level.
 * 2. [renderPdf] — the thin `android.graphics` stage that lays those same blocks onto A4 pages with
 *    [PdfDocument]. Arabic paragraphs are measured and drawn through [StaticLayout] with
 *    [TextDirectionHeuristics.RTL], which is what performs the bidi reordering and Arabic shaping;
 *    `ALIGN_NORMAL` under an RTL paragraph direction is what puts the text against the right margin.
 *    No networking import, so this file keeps `export/`'s zero-network lint green (ADR D-8 / plan
 *    §8.3): a report is an export artifact GENERATED offline, and its only network-touching act would
 *    be *delivery*, which belongs to `export/destinations/` — not here.
 *
 * Because [renderPdf] draws the blocks [renderHtml] serializes, the PDF and the HTML cannot say
 * different things, and the wording of both comes entirely from [ReportPresentation] — the same copy
 * the on-screen surface uses. What the unit tests can reach is the pure stage: this module has no
 * Robolectric and no `androidTest` source set, so nothing here rasterizes a page on the JVM. The
 * tests therefore assert the document's direction, order and content (including every evidence ref),
 * not glyph positions.
 */
object ReportRenderer {

    // MARK: - Document (pure)

    /** One line of a rendered report. Ordered; every string is already localized. */
    sealed interface Block {
        data class Title(val text: String) : Block
        data class Period(val text: String) : Block
        data class Heading(val text: String) : Block
        data class Narrative(val text: String) : Block
        data class Stat(val label: String, val value: String) : Block
        /** The transparency line: a human count plus the ids the claim above it rests on. */
        data class Evidence(val phrase: String, val ids: List<String>) : Block
        data class Empty(val text: String) : Block
        data class Disclaimer(val text: String) : Block
    }

    /** A report resolved into the exact blocks it says, in order, plus its writing direction. */
    data class Document(
        val language: AppLanguage,
        val isRtl: Boolean,
        val blocks: List<Block>,
    )

    fun document(model: ReportModel, language: AppLanguage, arabicDigits: Boolean): Document {
        val blocks = mutableListOf<Block>()
        blocks += Block.Title(ReportPresentation.title(model.periodKind).resolved(language))
        blocks += Block.Period(ReportPresentation.periodLabel(model, language, arabicDigits))

        if (!model.hasSufficientData) {
            blocks += Block.Empty(ReportPresentation.emptyMessage(model.periodKind).resolved(language))
        }

        for (section in model.sections) {
            blocks += Block.Heading(ReportPresentation.sectionTitle(section.kind).resolved(language))
            when (section.kind) {
                ReportSectionKind.SLEEP, ReportSectionKind.EFFORT, ReportSectionKind.READINESS ->
                    for (m in section.metrics) {
                        blocks += Block.Narrative(
                            ReportPresentation.metricNarrative(m, model.periodKind, language, arabicDigits),
                        )
                        val mean = ReportPresentation.number(m.mean ?: 0.0, language, arabicDigits)
                        val lo = ReportPresentation.number(m.min ?: 0.0, language, arabicDigits)
                        val hi = ReportPresentation.number(m.max ?: 0.0, language, arabicDigits)
                        val latest = ReportPresentation.number(m.latest ?: 0.0, language, arabicDigits)
                        blocks += Block.Stat(ReportPresentation.averageLabel.resolved(language), mean)
                        blocks += Block.Stat(ReportPresentation.rangeLabel.resolved(language), "$lo–$hi")
                        blocks += Block.Stat(ReportPresentation.latestLabel.resolved(language), latest)
                        blocks += Block.Evidence(
                            ReportPresentation.evidenceCountPhrase(m.count, language, arabicDigits),
                            m.evidence.map { it.id },
                        )
                    }
                ReportSectionKind.CHANGES ->
                    for (c in section.changes) {
                        blocks += Block.Narrative(
                            ReportPresentation.changeNarrative(c, model.periodKind, language, arabicDigits),
                        )
                        blocks += Block.Evidence(
                            ReportPresentation.evidenceCountPhrase(c.evidence.size, language, arabicDigits),
                            c.evidence.map { it.id },
                        )
                    }
                ReportSectionKind.ADHERENCE ->
                    section.adherence?.let { a ->
                        blocks += Block.Narrative(
                            ReportPresentation.adherenceNarrative(a, model.periodKind, language, arabicDigits),
                        )
                        blocks += Block.Evidence(
                            ReportPresentation.evidenceCountPhrase(a.logged, language, arabicDigits),
                            a.evidence.map { it.id },
                        )
                    }
            }
        }

        blocks += Block.Disclaimer(ReportPresentation.disclaimer.resolved(language))
        return Document(language = language, isRtl = language.isRtl, blocks = blocks)
    }

    // MARK: - HTML (pure, offline)

    fun renderHtml(model: ReportModel, language: AppLanguage, arabicDigits: Boolean): String =
        renderHtml(document(model, language, arabicDigits))

    fun renderHtml(doc: Document): String {
        val dir = if (doc.isRtl) "rtl" else "ltr"
        val align = if (doc.isRtl) "right" else "left"
        val body = StringBuilder()
        var openSection = false
        var openTable = false

        fun closeTable() {
            if (openTable) { body.append("</table>"); openTable = false }
        }

        for (block in doc.blocks) {
            when (block) {
                is Block.Title -> body.append("<h1>${esc(block.text)}</h1>")
                is Block.Period -> body.append("<p class=\"period\">${esc(block.text)}</p>")
                is Block.Empty -> body.append("<p class=\"empty\">${esc(block.text)}</p>")
                is Block.Heading -> {
                    closeTable()
                    if (openSection) body.append("</section>")
                    body.append("<section><h2>${esc(block.text)}</h2>")
                    openSection = true
                }
                is Block.Narrative -> {
                    closeTable()
                    body.append("<p class=\"narrative\">${esc(block.text)}</p>")
                }
                is Block.Stat -> {
                    if (!openTable) { body.append("<table>"); openTable = true }
                    body.append("<tr><td class=\"label\">${esc(block.label)}</td><td>${esc(block.value)}</td></tr>")
                }
                is Block.Evidence -> {
                    closeTable()
                    val ids = block.ids.joinToString(",")
                    body.append("<p class=\"evidence\" data-evidence=\"${esc(ids)}\">${esc(block.phrase)}</p>")
                }
                is Block.Disclaimer -> {
                    closeTable()
                    if (openSection) { body.append("</section>"); openSection = false }
                    body.append("<footer class=\"disclaimer\">${esc(block.text)}</footer>")
                }
            }
        }
        closeTable()
        if (openSection) body.append("</section>")

        return """
            <!DOCTYPE html>
            <html lang="${doc.language.code}" dir="$dir">
            <head>
            <meta charset="utf-8">
            <style>
            body { font-family: sans-serif; color: #1a1a1a; direction: $dir; text-align: $align; margin: 0; }
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
            $body
            </body>
            </html>
        """.trimIndent()
    }

    private fun esc(s: String): String = s
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")

    // MARK: - PDF (android.graphics, offline)

    // A4 at 72dpi, matching the iOS page geometry, with a 0.5in margin.
    private const val PAGE_WIDTH = 595
    private const val PAGE_HEIGHT = 842
    private const val MARGIN = 36f

    /** Model → PDF bytes in one call. */
    fun renderPdf(model: ReportModel, language: AppLanguage, arabicDigits: Boolean): ByteArray =
        renderPdf(document(model, language, arabicDigits))

    /**
     * Lay a [Document]'s blocks onto A4 pages. Every paragraph is measured and drawn by a
     * [StaticLayout] built with the document's text direction, which is what performs Arabic shaping
     * and bidi reordering; under [TextDirectionHeuristics.RTL], `ALIGN_NORMAL` puts the line against
     * the right margin, so an Arabic report reads right-to-left without any manual mirroring here.
     */
    fun renderPdf(doc: Document): ByteArray {
        val pdf = PdfDocument()
        val width = (PAGE_WIDTH - 2 * MARGIN).toInt()
        val heuristic = if (doc.isRtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR

        var page = pdf.startPage(PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, 1).create())
        var pageNumber = 1
        var y = MARGIN

        fun newPage() {
            pdf.finishPage(page)
            pageNumber += 1
            page = pdf.startPage(PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, pageNumber).create())
            y = MARGIN
        }

        for (block in doc.blocks) {
            val (text, paint, spaceBefore) = when (block) {
                is Block.Title -> Triple(block.text, paint(22f, Typeface.BOLD, 0xFF1A1A1A.toInt()), 0f)
                is Block.Period -> Triple(block.text, paint(13f, Typeface.NORMAL, 0xFF666666.toInt()), 2f)
                is Block.Heading -> Triple(block.text, paint(16f, Typeface.BOLD, 0xFF1A1A1A.toInt()), 16f)
                is Block.Narrative -> Triple(block.text, paint(13f, Typeface.NORMAL, 0xFF1A1A1A.toInt()), 6f)
                is Block.Stat -> Triple(
                    "${block.label}: ${block.value}", paint(12f, Typeface.NORMAL, 0xFF444444.toInt()), 2f,
                )
                is Block.Evidence -> Triple(block.phrase, paint(11f, Typeface.NORMAL, 0xFF888888.toInt()), 2f)
                is Block.Empty -> Triple(block.text, paint(13f, Typeface.ITALIC, 0xFF666666.toInt()), 8f)
                is Block.Disclaimer -> Triple(block.text, paint(11f, Typeface.NORMAL, 0xFF666666.toInt()), 20f)
            }
            val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, width)
                .setAlignment(Layout.Alignment.ALIGN_NORMAL)
                .setTextDirection(heuristic)
                .setIncludePad(false)
                .build()
            if (y + spaceBefore + layout.height > PAGE_HEIGHT - MARGIN) newPage() else y += spaceBefore

            val canvas = page.canvas
            canvas.save()
            canvas.translate(MARGIN, y)
            layout.draw(canvas)
            canvas.restore()
            y += layout.height
        }

        pdf.finishPage(page)
        val out = ByteArrayOutputStream()
        pdf.writeTo(out)
        pdf.close()
        return out.toByteArray()
    }

    private fun paint(size: Float, style: Int, color: Int): TextPaint {
        val p = TextPaint()
        p.isAntiAlias = true
        p.textSize = size
        p.color = color
        p.typeface = Typeface.create(Typeface.SANS_SERIF, style)
        return p
    }
}
