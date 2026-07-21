package net.albayyan.badan

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.AdherenceKind
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.reports.ReportBuilder
import net.albayyan.badan.domain.reports.ReportModel
import net.albayyan.badan.domain.reports.ReportPeriod
import net.albayyan.badan.domain.reports.ReportSectionKind
import net.albayyan.badan.storage.JsonCoding
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * EPIC-31 — the encoded [ReportModel] conforms to the shared contract,
 * `packages/contracts/report_model.schema.json`. Mirror of iOS `ReportModelSchemaTests`, driven by the
 * same file, which is what makes "one shared shape, two platforms" checkable rather than asserted.
 *
 * Deliberately not a general JSON Schema engine — it validates the subset this contract uses
 * (`required`, `additionalProperties: false`, `pattern`, `enum`, `$ref`), so a drift in the model's
 * FIELD NAMES or enum cases fails here rather than silently making the contract fiction.
 */
class ReportModelSchemaTest {

    private val schema: JsonObject = Json.parseToJsonElement(
        File("../../../packages/contracts/report_model.schema.json").readText(),
    ).jsonObject
    private val definitions: JsonObject = schema["definitions"]?.jsonObject ?: JsonObject(emptyMap())

    private val tz = "UTC"
    private val now = 1_784_000_000_000L // 2026-07-14 03:33 UTC, ISO 2026-W29

    // MARK: - Sample models

    /** A model exercising every section kind, so every `$ref` in the contract is walked. */
    private fun fullModel(): ReportModel {
        val period = ReportPeriod.week(now, tz)
        val prior = ReportPeriod.prior(period, tz)
        fun dv(metric: String, day: String, v: Double) = DerivedValue(
            id = Ulid.newId(), metricId = metric, value = v, unit = "score_0_100",
            periodKey = "day:$day", algorithmId = "t", algorithmVersion = "1", computedAt = now,
            updatedAt = now, originDeviceId = "d",
        )
        return ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = prior,
                currentByMetric = mapOf(
                    MetricId.readinessScore to period.dayKeys.take(4).map { dv(MetricId.readinessScore, it, 80.0) },
                    MetricId.sleepPerformance to period.dayKeys.take(3).map { dv(MetricId.sleepPerformance, it, 70.0) },
                    MetricId.effortDay to period.dayKeys.take(3).map { dv(MetricId.effortDay, it, 55.0) },
                ),
                priorByMetric = mapOf(
                    MetricId.readinessScore to prior.dayKeys.take(4).map { dv(MetricId.readinessScore, it, 60.0) },
                ),
                adherence = listOf(
                    AdherenceEvent(
                        id = Ulid.newId(), regimenId = "r", kind = AdherenceKind.TAKEN,
                        occurredAt = period.start, tzId = tz, updatedAt = now, originDeviceId = "d",
                    ),
                ),
                generatedAt = now,
            ),
        )
    }

    private fun emptyModel(): ReportModel {
        val period = ReportPeriod.week(now, tz)
        return ReportBuilder.build(
            ReportBuilder.Inputs(
                period = period, prior = ReportPeriod.prior(period, tz),
                currentByMetric = emptyMap(), priorByMetric = emptyMap(),
                adherence = emptyList(), generatedAt = now,
            ),
        )
    }

    private fun encoded(model: ReportModel): JsonObject =
        Json.parseToJsonElement(JsonCoding.encode(model)).jsonObject

    // MARK: - Conformance

    @Test fun fullModelConformsToTheContract() {
        val model = fullModel()
        // The sample must actually exercise every section kind, or "walks every $ref" is a lie.
        assertEquals(
            "the schema sample must cover every section kind",
            ReportSectionKind.entries.map { it.code }.toSet(),
            model.sectionsIncluded.toSet(),
        )
        validate(encoded(model), schema, "<root>")
    }

    @Test fun emptyModelConformsToTheContract() {
        val model = emptyModel()
        val obj = encoded(model)
        assertEquals(false, obj["hasSufficientData"]!!.jsonPrimitive.boolean)
        assertEquals(0, obj["sections"]!!.jsonArray.size)
        validate(obj, schema, "<root>")
    }

    /** The version the model stamps and the version the contract declares are one fact in two files. */
    @Test fun schemaVersionAgreesWithTheContract() {
        val declared = schema["properties"]!!.jsonObject["schemaVersion"]!!
            .jsonObject["const"]!!.jsonPrimitive.content
        assertEquals(
            "ReportModel.SCHEMA_VERSION must equal the contract's schemaVersion const",
            declared, ReportModel.SCHEMA_VERSION,
        )
    }

    /**
     * Instants are epoch millis in the contract; a date encoded any other way would still "validate"
     * as a number, so the magnitude of the value is what is actually asserted.
     */
    @Test fun instantsAreEpochMillis() {
        val obj = encoded(fullModel())
        for (key in listOf("periodStart", "periodEnd", "generatedAt")) {
            val value = obj[key]!!.jsonPrimitive.double
            assertTrue("$key must be millis, not seconds", value > 1_000_000_000_000.0)
        }
    }

    // MARK: - Tiny validator (the subset this contract uses)

    private fun validate(value: JsonElement, node0: JsonObject, path: String) {
        var node = node0
        (node["\$ref"] as? JsonPrimitive)?.contentOrNull?.let { node = resolve(it) }

        // `oneOf` is used only for "this object or null" (the optional adherence summary).
        (node["oneOf"] as? JsonArray)?.let { options ->
            if (value is JsonNull) return
            val obj = options.map { it.jsonObject }
                .firstOrNull { it["type"]?.jsonPrimitive?.contentOrNull != "null" } ?: return
            validate(value, obj, path)
            return
        }

        when (node["type"]?.let { (it as? JsonPrimitive)?.contentOrNull }) {
            "object" -> {
                assertTrue("$path: expected an object", value is JsonObject)
                val obj = value.jsonObject
                val properties = node["properties"]?.jsonObject ?: JsonObject(emptyMap())
                node["required"]?.jsonArray?.forEach { req ->
                    val key = req.jsonPrimitive.content
                    assertNotNull("$path: contract requires `$key`, model omitted it", obj[key])
                }
                if (node["additionalProperties"]?.jsonPrimitive?.contentOrNull == "false") {
                    for (key in obj.keys) {
                        assertNotNull(
                            "$path: model emitted `$key`, which the contract does not declare",
                            properties[key],
                        )
                    }
                }
                for ((key, child) in obj) {
                    val childSchema = properties[key]?.jsonObject ?: continue
                    validate(child, childSchema, "$path.$key")
                }
            }
            "array" -> {
                assertTrue("$path: expected an array", value is JsonArray)
                val items = node["items"]?.jsonObject
                if (items != null) {
                    value.jsonArray.forEachIndexed { i, element -> validate(element, items, "$path[$i]") }
                }
            }
            "string" -> {
                val s = value.jsonPrimitive.contentOrNull
                assertNotNull("$path: expected a string", s)
                node["const"]?.jsonPrimitive?.contentOrNull?.let {
                    assertEquals("$path: must be the contract's const", it, s)
                }
                node["enum"]?.jsonArray?.let { allowed ->
                    val values = allowed.map { it.jsonPrimitive.content }
                    assertTrue("$path: `$s` is not in the contract's enum $values", values.contains(s))
                }
                node["pattern"]?.jsonPrimitive?.contentOrNull?.let { pattern ->
                    assertTrue(
                        "$path: `$s` does not match the contract's pattern $pattern",
                        Regex(pattern).containsMatchIn(s!!),
                    )
                }
            }
            "integer", "number" -> assertTrue("$path: expected a number", value is JsonPrimitive)
            "boolean" -> assertTrue("$path: expected a boolean", value is JsonPrimitive)
            else -> Unit // ["number", "null"] unions and untyped nodes: nothing further to assert.
        }
    }

    private fun resolve(ref: String): JsonObject {
        val name = ref.removePrefix("#/definitions/")
        val node = definitions[name]?.jsonObject
        assertNotNull("unresolvable \$ref $ref", node)
        return node!!
    }
}
