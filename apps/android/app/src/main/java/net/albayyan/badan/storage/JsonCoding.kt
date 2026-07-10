package net.albayyan.badan.storage

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Shared JSON coding for @Serializable entities and JSON columns (Provenance, SessionDetail,
 * scope, manifest, input manifests). Mirror of the iOS `JSONCoding`. Timestamps are plain Long
 * epoch-millis, so no custom date handling is needed.
 */
object JsonCoding {
    val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    inline fun <reified T> encode(value: T): String = json.encodeToString(value)

    inline fun <reified T> decodeOrNull(text: String?): T? =
        if (text == null) null else runCatching { json.decodeFromString<T>(text) }.getOrNull()
}
