package net.albayyan.badan.features.workouts

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.SectionHeader

/**
 * The GPS-route consent screen (EPIC-03; plan §4 rule 11, §9.2).
 *
 * This is the *only* place BADAN's route toggle can be changed, and that is a deliberate
 * constraint rather than an accident of where the switch happened to land. Routes are the one
 * category of data BADAN holds that can reveal where a person lives, works and worships, so
 * "when did I agree to this?" has to be answerable by pointing at one screen with one explanation
 * on it — not at a switch buried in a list of fourteen other switches whose copy the user scrolled
 * past. Nothing else in the app writes `AppEnvironment.isRouteCaptureEnabled`.
 *
 * Three things this screen is careful to keep separate, because merging any two of them would be a
 * lie of convenience:
 *  * **Collecting** (this toggle) versus **keeping** (the delete action below). Turning capture off
 *    stops new traces; it does not reach back and erase the ones already on the device, and saying
 *    it did would be false. The delete action is offered right here so the user who wanted both
 *    gets both, explicitly.
 *  * **BADAN's consent** versus **Health Connect's own**. Even with this on, connect-client 1.1.0
 *    returns `ExerciseRouteResult.ConsentRequired` for a route the user has not separately approved
 *    through the system, and BADAN treats that as "no route" rather than prompting mid-sync. A user
 *    who turns this on and sees no routes is not looking at a bug, and the copy says so.
 *  * **Storing** versus **exporting**. Routes are excluded from export bundles unless the export's
 *    own route switch is on. This screen states that; it does not control it.
 */

// MARK: - Strings

private val routeTitle = LocalizedString(en = "Workout routes", ar = "مسارات التمارين")

private val routeLead = LocalizedString(
    en = "Some workouts recorded by your watch or phone include the path you took. BADAN can read " +
        "those paths and draw them beside the workout.",
    ar = "تتضمّن بعض التمارين التي تسجّلها ساعتك أو هاتفك المسار الذي سلكته. يستطيع بدن قراءة هذه " +
        "المسارات ورسمها بجانب التمرين.",
)

private val routeToggleLabel = LocalizedString(en = "Read workout routes", ar = "قراءة مسارات التمارين")
private val routeToggleOnCaption = LocalizedString(
    en = "On — routes are read with each sync and stored on this device.",
    ar = "مُفعّل — تُقرأ المسارات مع كل مزامنة وتُخزَّن على هذا الجهاز.",
)
private val routeToggleOffCaption = LocalizedString(
    en = "Off — no location data is copied out of Health Connect.",
    ar = "متوقف — لا تُنسخ أي بيانات موقع من هيلث كونكت.",
)

private val whatThisMeansTitle = LocalizedString(en = "What this means", ar = "ماذا يعني هذا")

private val meansLocationTitle = LocalizedString(en = "This is location data", ar = "هذه بيانات موقع")
private val meansLocationBody = LocalizedString(
    en = "A route can show where you started and finished — often your home or your workplace. " +
        "That is why it is a separate choice from everything else BADAN reads.",
    ar = "قد يُظهر المسار مكان بدايتك ونهايتك — وغالباً ما يكون منزلك أو مكان عملك. لهذا فهو خيار " +
        "منفصل عن كل ما يقرأه بدن.",
)

private val meansDeviceTitle = LocalizedString(en = "It stays on this device", ar = "تبقى على هذا الجهاز")
private val meansDeviceBody = LocalizedString(
    en = "Routes are stored on your phone and drawn from your phone. BADAN has no server, and " +
        "drawing a route downloads nothing.",
    ar = "تُخزَّن المسارات على هاتفك وتُرسم منه. لا يملك بدن خادماً، ورسم المسار لا يُنزّل أي شيء.",
)

private val meansExportTitle = LocalizedString(en = "Exports leave them out", ar = "التصدير يستثنيها")
private val meansExportBody = LocalizedString(
    en = "Routes are never included in an export unless you switch them on for that export " +
        "specifically. Turning this on does not add them to anything you have already shared.",
    ar = "لا تُدرج المسارات في أي تصدير إلا إذا فعّلتها لذلك التصدير تحديداً. تفعيل هذا الخيار لا " +
        "يضيفها إلى أي شيء شاركته من قبل.",
)

private val hcCaveatTitle = LocalizedString(
    en = "Health Connect asks separately",
    ar = "هيلث كونكت يسأل بشكل منفصل",
)
private val hcCaveatBody = LocalizedString(
    en = "Android treats each route as its own permission. Even with this on, BADAN only sees the " +
        "routes Health Connect has released to it — so you may turn this on and still see none. " +
        "That is Android's rule, not a fault in BADAN.",
    ar = "يعامل أندرويد كل مسار كإذن مستقل. حتى مع تفعيل هذا الخيار، لا يرى بدن سوى المسارات التي " +
        "أتاحها هيلث كونكت له — لذا قد تُفعّله ولا ترى أي مسار. هذه قاعدة أندرويد، وليست خللاً في بدن.",
)

private val storedTitle = LocalizedString(en = "Routes on this device", ar = "المسارات على هذا الجهاز")
private fun storedCount(routes: Int) = LocalizedString(
    en = "$routes stored",
    ar = "$routes مسار مخزّن",
)
private val storedNone = LocalizedString(en = "None stored yet.", ar = "لا توجد مسارات مخزّنة بعد.")
private val deleteRoutes = LocalizedString(en = "Delete stored routes", ar = "حذف المسارات المخزّنة")
private val deleteRoutesConfirm = LocalizedString(
    en = "Delete them? This removes every route and every point from this device for good. Your " +
        "workouts themselves are not touched.",
    ar = "هل تريد حذفها؟ سيؤدي هذا إلى إزالة كل مسار وكل نقطة من هذا الجهاز نهائياً. أما تمارينك " +
        "نفسها فلن تُمسّ.",
)
private val deleteRoutesConfirmAction = LocalizedString(en = "Yes, delete", ar = "نعم، احذف")
private val deleteRoutesDone = LocalizedString(
    en = "Stored routes deleted from this device.",
    ar = "تم حذف المسارات المخزّنة من هذا الجهاز.",
)

/**
 * The one piece of copy on this screen that is about the *irreversibility* of a delete, and it is
 * deliberately not softened. Routes are the single place in the measurement layer where BADAN does
 * a real DELETE rather than an I3 suppression (see `RouteRepository.purgeAll`) — precisely so this
 * button means what it appears to mean — so the warning has to match.
 */
private val deleteRoutesIrreversible = LocalizedString(
    en = "This cannot be undone. Routes can be read again from Health Connect if they are still there.",
    ar = "لا يمكن التراجع عن هذا. يمكن قراءة المسارات مجدداً من هيلث كونكت إن كانت لا تزال موجودة.",
)

// MARK: - Screen

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RouteConsentScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()

    var enabled by remember { mutableStateOf(env.isRouteCaptureEnabled) }
    var routeCount by remember { mutableIntStateOf(0) }
    var confirmingDelete by remember { mutableStateOf(false) }
    var deletedNotice by remember { mutableStateOf(false) }

    suspend fun refreshCount() {
        routeCount = withContext(Dispatchers.IO) {
            runCatching { env.routes.routeCount() }.getOrDefault(0)
        }
    }
    LaunchedEffect(Unit) { refreshCount() }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(routeTitle),
                        style = BadanType.sectionTitle,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = { nav.pop() }) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = env.s(Loc.back),
                            tint = colors.textPrimary,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colors.background,
                    titleContentColor = colors.textPrimary,
                    navigationIconContentColor = colors.textPrimary,
                ),
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(BadanSpace.s4),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
        ) {
            Text(
                text = env.s(routeLead),
                style = BadanType.body,
                color = colors.textSecondary,
            )

            // The toggle sits above the explanation rather than after it. Burying the control below
            // four paragraphs is a pattern that reliably produces consent-by-scroll-fatigue; the
            // explanation is still on screen either way, and a user who already knows what a route
            // is should not have to read it again to reach the switch.
            BadanCard {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = BadanSpace.touchMin),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
                ) {
                    Icon(
                        imageVector = Icons.Filled.Map,
                        contentDescription = null,
                        tint = if (enabled) colors.primary else colors.textSecondary,
                        modifier = Modifier.size(24.dp),
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                    ) {
                        Text(
                            text = env.s(routeToggleLabel),
                            style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                            color = colors.textPrimary,
                        )
                        Text(
                            text = env.s(if (enabled) routeToggleOnCaption else routeToggleOffCaption),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                    }
                    Switch(
                        checked = enabled,
                        onCheckedChange = { value ->
                            enabled = value
                            env.isRouteCaptureEnabled = value
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = colors.onPrimary,
                            checkedTrackColor = colors.primary,
                            uncheckedThumbColor = colors.textSecondary,
                            uncheckedTrackColor = colors.surfaceElevated,
                            uncheckedBorderColor = colors.separator,
                        ),
                    )
                }
            }

            SectionHeader(title = env.s(whatThisMeansTitle))

            ConsentPoint(
                icon = Icons.Filled.Warning,
                tint = colors.outOfBand,
                title = env.s(meansLocationTitle),
                body = env.s(meansLocationBody),
            )
            ConsentPoint(
                icon = Icons.Filled.CloudOff,
                tint = colors.primary,
                title = env.s(meansDeviceTitle),
                body = env.s(meansDeviceBody),
            )
            ConsentPoint(
                icon = Icons.Filled.Shield,
                tint = colors.info,
                title = env.s(meansExportTitle),
                body = env.s(meansExportBody),
            )
            ConsentPoint(
                icon = Icons.Filled.Info,
                tint = colors.info,
                title = env.s(hcCaveatTitle),
                body = env.s(hcCaveatBody),
            )

            // Stored-route housekeeping. Rendered unconditionally, including at zero, so that "how
            // much location data does BADAN actually hold about me" is a question with a visible
            // answer rather than one that only appears once the answer is uncomfortable.
            SectionHeader(title = env.s(storedTitle))
            BadanCard {
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    Text(
                        text = if (routeCount > 0) {
                            env.s(storedCount(routeCount))
                        } else {
                            env.s(storedNone)
                        },
                        style = BadanType.body,
                        color = colors.textPrimary,
                    )
                    if (deletedNotice) {
                        Text(
                            text = env.s(deleteRoutesDone),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                    }
                    if (routeCount > 0) {
                        if (!confirmingDelete) {
                            DestructiveButton(
                                label = env.s(deleteRoutes),
                                icon = Icons.Filled.DeleteSweep,
                                onClick = { confirmingDelete = true },
                            )
                        } else {
                            Text(
                                text = env.s(deleteRoutesConfirm),
                                style = BadanType.bodyCompact,
                                color = colors.textPrimary,
                            )
                            Text(
                                text = env.s(deleteRoutesIrreversible),
                                style = BadanType.caption,
                                color = colors.outOfBand,
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                                DestructiveButton(
                                    label = env.s(deleteRoutesConfirmAction),
                                    icon = Icons.Filled.DeleteSweep,
                                    modifier = Modifier.weight(1f),
                                    onClick = {
                                        confirmingDelete = false
                                        scope.launch {
                                            withContext(Dispatchers.IO) {
                                                runCatching { env.routes.purgeAll() }
                                            }
                                            deletedNotice = true
                                            refreshCount()
                                        }
                                    },
                                )
                                QuietButton(
                                    label = env.s(Loc.cancel),
                                    modifier = Modifier.weight(1f),
                                    onClick = { confirmingDelete = false },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

@Composable
private fun ConsentPoint(icon: ImageVector, tint: androidx.compose.ui.graphics.Color, title: String, body: String) {
    val colors = BadanTheme.colors
    BadanCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(20.dp),
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
            ) {
                Text(
                    text = title,
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Text(
                    text = body,
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

/**
 * A destructive action styled with [BadanColors.critical] — the one colour the design system
 * reserves for "this cannot be undone", and therefore the one place in the app it is correct to
 * use. (Status colours never moralize; a delete is not a status.)
 */
@Composable
private fun DestructiveButton(
    label: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = BadanSpace.touchMin)
            .background(colors.critical.copy(alpha = 0.12f), shape)
            .border(width = 1.dp, color = colors.critical.copy(alpha = 0.5f), shape = shape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2, Alignment.CenterHorizontally),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = colors.critical,
            modifier = Modifier.size(18.dp),
        )
        Text(
            text = label,
            style = BadanType.body.copy(fontWeight = FontWeight.Medium),
            color = colors.critical,
            maxLines = 1,
        )
    }
}

@Composable
private fun QuietButton(label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = BadanSpace.touchMin)
            .background(colors.surfaceElevated, shape)
            .border(width = 1.dp, color = colors.separator, shape = shape)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = BadanType.body.copy(fontWeight = FontWeight.Medium),
            color = colors.textPrimary,
            maxLines = 1,
        )
    }
}
