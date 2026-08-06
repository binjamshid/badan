package net.albayyan.badan.smoke

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The first instrumented test this module has ever had.
 *
 * `app/src/androidTest` did not exist before B1-1, even though
 * `testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"` had been declared in
 * `app/build.gradle.kts` since the module was created — dead config pointing at a source set with
 * nothing in it. This test exists to make the source set real: if it compiles and runs, the whole
 * instrumented lane (test APK, runner, orchestration, install) is wired, and every later task that
 * genuinely needs a device — Health Connect permission flows, Glance widget hosts, Quick Settings
 * tiles, SQLCipher's native library, ML Kit's on-device models — has somewhere to put its tests.
 *
 * It asserts the `applicationId`, not the `namespace`. Those two are deliberately different in
 * this module (`net.binjamshid.badan` vs `net.albayyan.badan`), and the instrumented context's
 * package name is the former — so this assertion would actually catch an accidental
 * `applicationId` change, which is the only thing worth asserting at this level.
 */
@RunWith(AndroidJUnit4::class)
class AppContextInstrumentedTest {

    @Test
    fun appContextHasTheExpectedPackageName() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        assertEquals("net.binjamshid.badan", context.packageName)
    }
}
