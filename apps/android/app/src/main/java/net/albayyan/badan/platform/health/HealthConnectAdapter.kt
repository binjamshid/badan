package net.albayyan.badan.platform.health

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import net.albayyan.badan.domain.SourceType

/**
 * Real Health Connect integration boundary. It compiles and stays safe without a Health Connect
 * provider installed: availability is honest, permissions are declared but never assumed, and the
 * read methods are intentionally empty for this MVP (FakeHealthStore is the dev data source).
 * This file exists to nail the real seam down without risky record-mapping code.
 */
class HealthConnectAdapter(private val context: Context) : HealthStorePort {

    override fun availability(): HealthAvailability =
        when (HealthConnectClient.getSdkStatus(context)) {
            HealthConnectClient.SDK_AVAILABLE -> HealthAvailability.available
            HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> HealthAvailability.notInstalled
            else -> HealthAvailability.unsupported
        }

    override fun sourceDescriptors(): List<SourceDescriptor> = listOf(
        SourceDescriptor(
            id = "healthConnect", displayName = "Health Connect", type = SourceType.HEALTH_CONNECT,
            bundleId = "com.google.android.apps.healthdata", priority = 80,
        ),
    )

    /**
     * Whether every MVP read permission has been granted. The UI reflects granted / denied /
     * partial as first-class state rather than treating a missing grant as an error.
     */
    suspend fun hasAllPermissions(client: HealthConnectClient): Boolean {
        val granted = client.permissionController.getGrantedPermissions()
        return granted.containsAll(permissions)
    }

    // The Activity/Fragment requests these by registering
    // PermissionController.createRequestPermissionResultContract() and launching it with `permissions`.
    @Suppress("unused")
    private fun requestContract() = PermissionController.createRequestPermissionResultContract()

    override fun readSamples(range: HealthDateRange): List<SampleDto> =
        emptyList() // TODO map Health Connect records to DTOs (post-MVP)

    override fun readIntervals(range: HealthDateRange): List<IntervalDto> =
        emptyList() // TODO map Health Connect records to DTOs (post-MVP)

    override fun readSessions(range: HealthDateRange): List<SessionDto> =
        emptyList() // TODO map Health Connect records to DTOs (post-MVP)

    companion object {
        /** READ permissions for the MVP record types (I: raw data is not paywalled). */
        val permissions: Set<String> = setOf(
            HealthPermission.getReadPermission(StepsRecord::class),
            HealthPermission.getReadPermission(HeartRateRecord::class),
            HealthPermission.getReadPermission(RestingHeartRateRecord::class),
            HealthPermission.getReadPermission(SleepSessionRecord::class),
        )
    }
}
