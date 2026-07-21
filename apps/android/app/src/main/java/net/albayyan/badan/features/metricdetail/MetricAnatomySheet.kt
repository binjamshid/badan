package net.albayyan.badan.features.metricdetail

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.ValueFormatter
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.ProvisionalBadge
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.designsystem.components.ContextCaveatNote

// MARK: - Strings local to the anatomy sheet

/**
 * Strings only the anatomy sheet needs — the calm, honest "why is it saying that" vocabulary.
 * Mirror of the iOS `AnatomyStrings`.
 */
private object AnatomyStrings {
    val baseline = LocalizedString(en = "Your baseline", ar = "خط الأساس")
    val center = LocalizedString(en = "Center", ar = "المركز")
    val daysUsed = LocalizedString(en = "Days used", ar = "الأيام المستخدمة")
    val dedupHeading = LocalizedString(en = "Duplicate handling", ar = "معالجة التكرار")
    val oneKept = LocalizedString(
        en = "One source kept, one suppressed.",
        ar = "مصدر واحد محتفظ به، وآخر مستبعد.",
    )
    val kept = LocalizedString(en = "Kept", ar = "المحتفظ به")
    val straightFromRecords = LocalizedString(
        en = "This reads straight from your records — no extra calculation.",
        ar = "تُقرأ هذه القيمة مباشرة من سجلاتك — دون أي حساب إضافي.",
    )
    val noBaselineYet = LocalizedString(
        en = "Not enough history yet to draw a typical range.",
        ar = "لا يوجد سجل كافٍ بعد لرسم نطاق معتاد.",
    )
    val contribution = LocalizedString(en = "What went into it", ar = "ما الذي دخل فيه")
    val contributionHint = LocalizedString(
        en = "Each signal's share of the score. The bars add up to the number above.",
        ar = "حصة كل إشارة من النتيجة. تتجمّع الأشرطة لتكوّن الرقم أعلاه.",
    )
    val points = LocalizedString(en = "pts", ar = "نقطة")
    val formulaHeading = LocalizedString(en = "The formula", ar = "المعادلة")
    val formulaPublishedNote = LocalizedString(
        en = "Computed on your device. This formula is published.",
        ar = "محسوبة على جهازك. هذه المعادلة منشورة.",
    )
    val confidence = LocalizedString(en = "Confidence", ar = "الثقة")

    /**
     * The one sentence that keeps the caveat from being read as "the number was adjusted". Sits under
     * the caveat in the confidence card, next to the confidence it explains.
     */
    val contextValueUnchanged = LocalizedString(
        en = "The value itself is unchanged — only how confidently it's read.",
        ar = "القيمة نفسها لم تتغيّر — ما تغيّر هو درجة الثقة في قراءتها فقط.",
    )
    // Reduced-input honesty (plan §18): a Readiness score computed without the HRV anchor is a
    // DISTINCT thing, labelled — never a full score silently passed off as complete.
    val reducedInputReadiness = LocalizedString(
        en = "Computed from fewer signals — heart-rate variability wasn't available this morning.",
        ar = "احتُسب من إشارات أقل — لم يتوفّر تغيّر معدل ضربات القلب هذا الصباح.",
    )
}

// MARK: - Sheet

/**
 * The "How this was worked out" sheet (VS-4). Rendered inside a modal bottom sheet, it shows the
 * personal baseline (center, band, days used, provisional honesty), the records that fed the
 * latest computed value, the frozen algorithm version, and — for sleep time-asleep — the
 * reversible dedup decision that kept one source and suppressed a duplicate sibling. Mirror of the
 * iOS `MetricAnatomySheet`.
 */
@Composable
fun MetricAnatomySheet(data: MetricDetailData, onClose: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s5),
    ) {
        // Pinned outside the scrollable content below so a user scrolled deep into a long
        // manifest never loses the title's orientation or the Close action at the same time
        // (EASE-273).
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = BadanSpace.s4)
                .padding(top = BadanSpace.s2),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = env.s(Loc.anatomyTitle),
                style = BadanType.sectionTitle,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onClose) {
                Text(text = env.s(Loc.close), style = BadanType.body, color = colors.primary)
            }
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = BadanSpace.s4)
                .padding(bottom = BadanSpace.s7),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s5),
        ) {
            BaselineCard(data)

            val manifest = data.manifest
            val weightedInputs = manifest?.inputs?.filter { it.weight != null }.orEmpty()
            // A weighted manifest on a 0–100 composite (Readiness) renders as contribution bars —
            // Σ(contributions) == the score by construction (see `ReadinessEngine`), so the bars
            // literally add up to the number. Everything else keeps the plain records list.
            val isScoreComposite = data.latestDerivedValue?.unit == "score_0_100"
            when {
                weightedInputs.isNotEmpty() && isScoreComposite -> ContributionCard(data, weightedInputs)
                manifest != null && manifest.inputs.isNotEmpty() -> RecordsCard(data, manifest.inputs)
                else -> StraightFromRecordsCard()
            }

            // The published formula for the value's algorithm — the in-app half of "every surfaced
            // score ships with a published formula" (audit finding #3). A method with no published
            // formula shows no card rather than a guess.
            methodStringOrNull(data)?.let { AnatomyFormulas.lookup(it) }?.let { FormulaCard(it) }

            ConfidenceCard(data)

            methodStringOrNull(data)?.let { MethodCard(it) }

            if (data.recentDedup.isNotEmpty()) {
                DedupCard(data)
            }
        }
    }
}

// MARK: - Baseline

@Composable
private fun BaselineCard(data: MetricDetailData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val b = data.baseline
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(
                title = env.s(AnatomyStrings.baseline),
                trailing = if (b?.provisional ?: true) {
                    { ProvisionalBadge(env.language) }
                } else {
                    null
                },
            )
            if (b != null) {
                InfoRow(
                    label = env.s(AnatomyStrings.center),
                    value = env.format.full(data.def.metricId, b.center),
                )
                InfoRow(label = env.s(Loc.personalRange), value = bandText(env.format, data.def.metricId, b))
                InfoRow(label = env.s(AnatomyStrings.daysUsed), value = env.format.integer(b.nPoints))
            } else {
                Text(
                    text = env.s(AnatomyStrings.noBaselineYet),
                    style = BadanType.body,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

// MARK: - Contributing records

@Composable
private fun RecordsCard(data: MetricDetailData, inputs: List<net.albayyan.badan.domain.InputManifest.Input>) {
    val env = LocalAppEnvironment.current
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(env.s(Loc.contributingRecords))
            inputs.forEach { input ->
                val inputDef = env.registry.definitionOrFallback(input.metricId)
                InfoRow(
                    label = inputDef.label(env.depth, env.language),
                    value = env.format.full(input.metricId, input.value),
                )
            }
        }
    }
}

@Composable
private fun StraightFromRecordsCard() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Text(
            text = env.s(AnatomyStrings.straightFromRecords),
            style = BadanType.body,
            color = colors.textSecondary,
        )
    }
}

// MARK: - Contribution bars (composite scores)

/**
 * Contribution bars for a weighted composite (Readiness). Each input's bar length is its share of the
 * largest contribution, its trailing value is its additive points, and the caption names the record's
 * raw reading. Together they make "why is it this number" a visible arithmetic, not a promise — the
 * bars add up to the score by construction. A Readiness score that dropped the HRV anchor is labelled
 * distinctly here (reduced-input honesty), never presented as a full score.
 */
@Composable
private fun ContributionCard(data: MetricDetailData, inputs: List<InputManifest.Input>) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val rows = remember(inputs) { contributionRows(inputs) }
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(env.s(AnatomyStrings.contribution))
            Text(
                text = env.s(AnatomyStrings.contributionHint),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
            if (data.def.metricId == MetricId.readinessScore && isReducedInputReadiness(inputs)) {
                Text(
                    text = env.s(AnatomyStrings.reducedInputReadiness),
                    style = BadanType.bodyCompact,
                    color = colors.outOfBand,
                )
            }
            rows.forEach { row ->
                val inputDef = env.registry.definitionOrFallback(row.metricId)
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        Text(
                            text = inputDef.label(env.depth, env.language),
                            style = BadanType.bodyCompact,
                            color = colors.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            text = "${env.format.number(row.contribution, 0)} ${env.s(AnatomyStrings.points)}",
                            style = BadanType.monospaceDigits(BadanType.bodyCompact),
                            color = colors.textSecondary,
                        )
                    }
                    // The bar: share of the largest contribution, so the leading signal fills the row.
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(8.dp)
                            .clip(RoundedCornerShape(BadanRadius.chip))
                            .background(colors.surfaceElevated),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(row.fractionOfMax)
                                .height(8.dp)
                                .clip(RoundedCornerShape(BadanRadius.chip))
                                .background(colors.primary.copy(alpha = 0.7f)),
                        )
                    }
                    // The record's raw reading, so the bar is traceable to a real measurement (I1).
                    Text(
                        text = env.format.full(row.metricId, row.measuredValue),
                        style = BadanType.monospaceDigits(BadanType.caption),
                        color = colors.textSecondary,
                    )
                }
            }
        }
    }
}

// MARK: - Confidence

/**
 * The derived value's confidence as a plain word (casual) plus the exact figure (power). BADAN never
 * shows a bare percentage as if it were precision — the word carries the meaning, the number is the
 * power-user's footnote. Renders nothing when the value carries no confidence (e.g. a straight-read
 * metric), so a card never appears empty.
 */
@Composable
private fun ConfidenceCard(data: MetricDetailData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val confidence = data.latestDerivedValue?.confidence ?: return
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = BadanSpace.touchMin),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Text(text = env.s(AnatomyStrings.confidence), style = BadanType.body, color = colors.textPrimary)
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    text = env.s(confidenceWord(confidence)),
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
                )
                if (env.depth.showsPowerDetail) {
                    Text(
                        text = "${env.format.number(confidence * 100, 0)}%",
                        style = BadanType.monospaceDigits(BadanType.bodyCompact),
                        color = colors.textSecondary,
                    )
                }
            }
            // EPIC-29 (plan §18). Placed directly under the confidence row because that is the number
            // a declared period actually moved: the engine capped this row's confidence and left its
            // value untouched. Saying so where the capped number is shown is the difference between
            // an unexplained "Lower" and an honest one.
            if (data.contextCaveats.isNotEmpty()) {
                ContextCaveatNote(caveats = data.contextCaveats, language = env.language)
                Text(
                    text = env.s(AnatomyStrings.contextValueUnchanged),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

// MARK: - Formula (published, with TalkBack alt-text)

/**
 * The published formula for the value's algorithm. The math notation is shown for sighted users;
 * TalkBack reads the plain-language [AnatomyFormula.altText] instead (a screen reader announcing
 * "Sigma" is noise). The "computed on your device, formula published" note is the trust line this
 * surface carries. Mirror of the iOS `formulaCard`.
 */
@Composable
private fun FormulaCard(formula: AnatomyFormula) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val altText = env.s(formula.altText)
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            SectionHeader(env.s(AnatomyStrings.formulaHeading))
            Text(
                text = env.s(formula.formula),
                style = BadanType.monospaceDigits(BadanType.bodyCompact),
                color = colors.textPrimary,
                // TalkBack reads the plain-language reading, not the math notation.
                modifier = Modifier.clearAndSetSemantics { contentDescription = altText },
            )
            Text(
                text = env.s(AnatomyStrings.formulaPublishedNote),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

// MARK: - Method

@Composable
private fun MethodCard(method: String) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            SectionHeader(env.s(Loc.algorithm))
            Text(
                text = method,
                style = BadanType.monospaceDigits(BadanType.bodyCompact),
                color = colors.textPrimary,
            )
        }
    }
}

// MARK: - Dedup (sleep time-asleep only)

@Composable
private fun DedupCard(data: MetricDetailData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(env.s(AnatomyStrings.dedupHeading))
            Text(
                text = env.s(AnatomyStrings.oneKept),
                style = BadanType.body,
                color = colors.textPrimary,
            )
            data.recentDedup.take(3).forEach { decision ->
                // The dedup detail journal carries the winning/losing source ids (DedupLite) —
                // naming them on the pills is the one piece of "how this was worked out" a
                // curious power user with two wearables most wants to know (UIUX-286).
                val winnerSource = decision.detail["winner_source"]?.let { data.sourceNames[it] ?: it }
                val loserSource = decision.detail["loser_source"]?.let { data.sourceNames[it] ?: it }
                val keptLabel = winnerSource?.let { "${env.s(AnatomyStrings.kept)} · $it" }
                    ?: env.s(AnatomyStrings.kept)
                val suppressedLabel = loserSource?.let { "${env.s(Loc.suppressedDuplicate)} · $it" }
                    ?: env.s(Loc.suppressedDuplicate)
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                        PillLabel(
                            text = keptLabel,
                            icon = Icons.Filled.Check,
                            tint = colors.inBand,
                        )
                        PillLabel(
                            text = suppressedLabel,
                            icon = Icons.AutoMirrored.Filled.Undo,
                            tint = colors.textSecondary,
                        )
                    }
                    if (decision.reversible) {
                        Text(
                            text = env.s(Loc.reversible),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                    }
                    Text(
                        text = "${decision.rule} · ${decision.ruleVersion}",
                        style = BadanType.monospaceDigits(BadanType.caption),
                        color = colors.textSecondary,
                    )
                }
            }
        }
    }
}

// MARK: - Helpers

@Composable
private fun InfoRow(label: String, value: String) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(text = label, style = BadanType.bodyCompact, color = colors.textSecondary)
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = value,
            style = BadanType.monospaceDigits(BadanType.bodyCompact),
            color = colors.textPrimary,
            textAlign = TextAlign.End,
        )
    }
}

private fun methodStringOrNull(data: MetricDetailData): String? {
    data.latestDerivedValue?.let { return "${it.algorithmId}@${it.algorithmVersion}" }
    return data.baseline?.algorithmVersion
}

private fun bandText(format: ValueFormatter, metricId: String, b: Baseline): String {
    val low = format.heroValue(metricId, b.bandLow)
    val high = format.heroValue(metricId, b.bandHigh)
    val unit = format.unitLabel(metricId)
    return if (unit != null) "$low – $high $unit" else "$low – $high"
}

// The pure contribution/confidence helpers (`contributionRows`, `isReducedInputReadiness`,
// `confidenceWord`) live in `AnatomyModel.kt` so a JVM unit test asserts them without loading this
// Compose file.
