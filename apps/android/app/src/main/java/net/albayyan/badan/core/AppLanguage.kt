package net.albayyan.badan.core

import kotlinx.serialization.Serializable
import java.text.NumberFormat
import java.util.Locale

/**
 * Language as a structural, in-app concern (mirror of iOS `AppLanguage`). Arabic/RTL is
 * demonstrable at runtime and every shipped string carries both languages. `isRtl` is mapped to
 * a Compose `LayoutDirection` at the presentation edge (kept out of core to avoid a UI import).
 */
@Serializable
enum class AppLanguage(val code: String) {
    EN("en"),
    AR("ar");

    val displayName: String get() = when (this) {
        EN -> "English"
        AR -> "العربية"
    }

    val isRtl: Boolean get() = this == AR

    val localeTag: String get() = when (this) {
        EN -> "en-US"
        AR -> "ar"
    }

    companion object {
        fun fromCode(code: String?): AppLanguage = entries.firstOrNull { it.code == code } ?: EN
    }
}

/**
 * A string that always carries both languages (mirror of iOS `LocalizedString`). A screen
 * cannot ship English-only because a `LocalizedString` cannot be constructed without both.
 */
@Serializable
data class LocalizedString(val en: String, val ar: String) {
    fun resolved(language: AppLanguage): String = when (language) {
        AppLanguage.EN -> en
        AppLanguage.AR -> ar
    }

    /** Interpolate `{name}` placeholders in both languages simultaneously. */
    fun filling(values: Map<String, String>): LocalizedString {
        fun apply(template: String): String {
            var out = template
            for ((k, v) in values) out = out.replace("{$k}", v)
            return out
        }
        return LocalizedString(apply(en), apply(ar))
    }
}

/** Number formatting honouring language + the Arabic-digit preference. */
object Numerals {
    fun format(value: Double, language: AppLanguage, arabicDigits: Boolean, fractionDigits: Int = 0): String {
        val locale = if (language == AppLanguage.AR && arabicDigits) Locale("ar") else Locale("en", "US")
        val nf = NumberFormat.getNumberInstance(locale)
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = fractionDigits
        return nf.format(value)
    }

    fun format(value: Int, language: AppLanguage, arabicDigits: Boolean): String =
        format(value.toDouble(), language, arabicDigits, 0)
}
