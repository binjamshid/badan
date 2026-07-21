package net.albayyan.badan.designsystem.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Accessibility
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bloodtype
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.BreakfastDining
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Cookie
import androidx.compose.material.icons.filled.DinnerDining
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.DirectionsWalk
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Healing
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.LocalCafe
import androidx.compose.material.icons.filled.LocalDrink
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.LunchDining
import androidx.compose.material.icons.filled.Medication
import androidx.compose.material.icons.filled.MonitorWeight
import androidx.compose.material.icons.filled.Mood
import androidx.compose.material.icons.filled.Nightlight
import androidx.compose.material.icons.filled.Notes
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.SelfImprovement
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Maps the domain `symbolName` keys (Material-style icon names carried by `MetricFamily`,
 * `MealType`, `TimelineEventType`, log item types, …) to concrete [ImageVector]s from
 * material-icons-extended. Kept in the design system so every screen resolves the same key to
 * the same glyph. Unknown keys fall back to a visibly-neutral "help" glyph — distinct from any
 * mapped icon (e.g. the ring-device glyph in `SourcesScreen.kt`) — so a mapping gap is
 * diagnosable rather than silently masquerading as valid content (UIUX-261).
 */
fun iconForKey(key: String): ImageVector = when (key) {
    // MetricFamily. `MetricFamilyParityTest.everyFamilyIconKeyIsMapped` asserts every family's
    // `symbolName` lands on a real branch here — an unmapped key falls to the help glyph, which is
    // diagnosable but is still a wrong icon shipped on a real screen.
    // `directions_run` (WORKOUT) and `water_drop` (HYDRATION) are mapped under the sections below;
    // the families reuse those keys deliberately rather than duplicating a branch.
    "bedtime" -> Icons.Filled.Bedtime
    "bolt" -> Icons.Filled.Bolt
    "favorite" -> Icons.Filled.Favorite
    "directions_walk" -> Icons.Filled.DirectionsWalk
    "local_fire_department" -> Icons.Filled.LocalFireDepartment
    "accessibility" -> Icons.Filled.Accessibility
    "air" -> Icons.Filled.Air
    "restaurant" -> Icons.Filled.Restaurant
    "mood" -> Icons.Filled.Mood
    "edit_note" -> Icons.Filled.EditNote
    "psychology" -> Icons.Filled.Psychology
    "calendar_month" -> Icons.Filled.CalendarMonth
    "healing" -> Icons.Filled.Healing
    "science" -> Icons.Filled.Science
    "medication" -> Icons.Filled.Medication
    "grid_view" -> Icons.Filled.GridView

    // MealType
    "breakfast_dining" -> Icons.Filled.BreakfastDining
    "lunch_dining" -> Icons.Filled.LunchDining
    "dinner_dining" -> Icons.Filled.DinnerDining
    "cookie" -> Icons.Filled.Cookie
    "local_cafe" -> Icons.Filled.LocalCafe

    // TimelineEventType
    "directions_run" -> Icons.Filled.DirectionsRun
    "straighten" -> Icons.Filled.Straighten
    "notes" -> Icons.Filled.Notes
    "auto_awesome" -> Icons.Filled.AutoAwesome

    // Common log / metric keys
    "water_drop" -> Icons.Filled.WaterDrop
    "local_drink" -> Icons.Filled.LocalDrink
    "monitor_weight" -> Icons.Filled.MonitorWeight
    "fitness_center" -> Icons.Filled.FitnessCenter
    "self_improvement" -> Icons.Filled.SelfImprovement
    "nightlight" -> Icons.Filled.Nightlight
    "bloodtype" -> Icons.Filled.Bloodtype

    else -> Icons.Filled.HelpOutline
}
