package net.albayyan.badan.storage.sqlite

import android.database.Cursor

/**
 * A materialized result row with typed, name-based accessors — parity of the iOS `SQLiteRow`.
 * Timestamps are epoch-millis `Long`.
 */
class Row(private val values: Map<String, Any?>) {

    fun getString(column: String): String? = values[column] as? String
    fun requireString(column: String): String = getString(column) ?: ""

    fun getLong(column: String): Long? = when (val v = values[column]) {
        is Long -> v
        is Int -> v.toLong()
        is Double -> v.toLong()
        else -> null
    }

    fun getInt(column: String): Int? = getLong(column)?.toInt()

    fun getDouble(column: String): Double? = when (val v = values[column]) {
        is Double -> v
        is Long -> v.toDouble()
        is Int -> v.toDouble()
        else -> null
    }

    fun requireDouble(column: String): Double = getDouble(column) ?: 0.0

    fun getBool(column: String): Boolean = (getLong(column) ?: 0L) != 0L

    /** Instants are epoch millis. */
    fun getDate(column: String): Long? = getLong(column)
    fun requireDate(column: String): Long = getLong(column) ?: 0L

    fun getBlob(column: String): ByteArray? = values[column] as? ByteArray

    companion object {
        fun from(c: Cursor, cols: Array<String>): Row {
            val m = HashMap<String, Any?>(cols.size)
            for (i in cols.indices) {
                m[cols[i]] = when (c.getType(i)) {
                    Cursor.FIELD_TYPE_INTEGER -> c.getLong(i)
                    Cursor.FIELD_TYPE_FLOAT -> c.getDouble(i)
                    Cursor.FIELD_TYPE_STRING -> c.getString(i)
                    Cursor.FIELD_TYPE_BLOB -> c.getBlob(i)
                    else -> null
                }
            }
            return Row(m)
        }
    }
}
