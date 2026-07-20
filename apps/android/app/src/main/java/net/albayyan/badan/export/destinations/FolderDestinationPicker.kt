package net.albayyan.badan.export.destinations

import android.net.Uri
import androidx.activity.compose.ManagedActivityResultLauncher
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable

/**
 * EPIC-14 — the `ACTION_OPEN_DOCUMENT_TREE` folder picker, as a Compose launcher.
 *
 * The mirror of iOS `FolderDestinationPicker` (a `UIDocumentPickerViewController` folder pick). The
 * built-in [ActivityResultContracts.OpenDocumentTree] does the picking; this wrapper exists for one
 * reason worth stating — to funnel the result straight into [FolderDestinationEnrollment.enroll],
 * which is where the persistable grant is *taken*. The picker's own grant is process-scoped and gone
 * by the next launch; skipping enrollment would leave a folder that works once and reports
 * `unreachable` forever after, the exact silent failure §12 EPIC-14 is written against.
 *
 * Not yet called from any screen. The Export Center surface that offers "choose a folder" is not this
 * stage's to build; this is the launcher it will use.
 */
@Composable
fun rememberFolderDestinationPicker(
    /**
     * Called with the picked tree URI, or null if the user backed out. A null is not a failure — the
     * caller should leave any existing destination alone rather than report a problem the user did
     * not have.
     */
    onPicked: (Uri?) -> Unit,
): ManagedActivityResultLauncher<Uri?, Uri?> =
    rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree(), onPicked)
