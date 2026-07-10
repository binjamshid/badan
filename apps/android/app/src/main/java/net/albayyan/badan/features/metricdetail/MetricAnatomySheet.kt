package net.albayyan.badan.features.metricdetail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.ValueFormatter
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.ProvisionalBadge
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.Baseline

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
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BadanSpace.s4)
            .padding(bottom = BadanSpace.s7),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s5),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
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

        BaselineCard(data)

        val manifest = data.manifest
        if (manifest != null && manifest.inputs.isNotEmpty()) {
            RecordsCard(data, manifest.inputs)
        } else {
            StraightFromRecordsCard()
        }

        methodStringOrNull(data)?.let { MethodCard(it) }

        if (data.recentDedup.isNotEmpty()) {
            DedupCard(data)
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
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                        PillLabel(
                            text = env.s(AnatomyStrings.kept),
                            icon = Icons.Filled.Check,
                            tint = colors.inBand,
                        )
                        PillLabel(
                            text = env.s(Loc.suppressedDuplicate),
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
