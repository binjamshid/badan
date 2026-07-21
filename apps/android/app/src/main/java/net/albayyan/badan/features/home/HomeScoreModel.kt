package net.albayyan.badan.features.home

import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.DerivedValue

/**
 * Compose-free presentation helpers for the Home score cards, so `HomeScorePresentationTest` can
 * assert the copy without loading the Compose runtime (the pure/UI split the engines use).
 */

/**
 * The Effort guidance sentence, tied to Readiness (a soft link, EPIC-26). Wellness-safe and never
 * prescriptive: "a gentler range may suit today", never "don't train". Absent Readiness, it simply
 * frames the day's effort so far rather than advising against a number it doesn't have.
 */
internal fun effortGuidance(readiness: DerivedValue?): LocalizedString = when {
    readiness == null ->
        LocalizedString(en = "Your effort so far today.", ar = "جهدك حتى الآن اليوم.")
    readiness.value >= 66 ->
        LocalizedString(en = "There's room for a fuller effort today.", ar = "هناك متسع لجهد أكبر اليوم.")
    readiness.value >= 45 ->
        LocalizedString(en = "A steady, moderate effort suits today.", ar = "جهد معتدل وثابت يناسب اليوم.")
    else ->
        LocalizedString(en = "A gentler range may suit you today.", ar = "قد تناسبك وتيرة ألطف اليوم.")
}
