package ai.desertant.redact

import ai.desertant.core.FfiReader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** A single detected entity and the placeholder that stands in for it. */
data class RedactionItem(
    /** PII category, e.g. `"EMAIL"`. */
    val label: String,
    /** The original (sensitive) text that was matched. */
    val original: String,
    /** The unique, restorable placeholder, e.g. `"[EMAIL_1]"`. */
    val placeholder: String,
    /** Confidence in `0.0..1.0` (deterministic recognizers report `1.0`). */
    val confidence: Double,
    /** Start offset of [original] in the source text (UTF-16). */
    val start: Int,
    /** End offset (exclusive). */
    val end: Int,
)

/**
 * A redaction: text with unique placeholders, the detections, and the mapping
 * needed to restore the originals after out-of-band processing (e.g. an LLM).
 */
data class Redaction(
    /** The input with each entity replaced by its `[LABEL_N]` placeholder. */
    val redactedText: String,
    /** Every detected entity, in document order. */
    val items: List<RedactionItem>,
) {
    /** Fill the originals back into [processed] by substituting each placeholder. */
    fun restore(processed: String): String {
        var out = processed
        for (item in items) out = out.replace(item.placeholder, item.original)
        return out
    }
}

/** Options controlling detection and redaction. */
data class Options(
    /** Minimum confidence for neural detections. Structured recognizers always
     * apply. Default `0.6`. */
    val minimumConfidence: Double = 0.6,
    /** If set, only these categories are detected/redacted; otherwise all are. */
    val labels: Set<String>? = null,
)

/** Thrown when the model cannot be created, loaded, or run. */
class RedactException(message: String) : Exception(message)

/**
 * On-device, multilingual PII redaction. Mirrors the iOS/Swift SDK: create one
 * `Redact` and reuse it; the model loads lazily on the first [redaction] (or
 * eagerly via [download]).
 *
 * ```kotlin
 * val redact = Redact(context)                 // download on demand, cached
 * val r = redact.redaction("Email Anna at anna@example.com.")
 * r.redactedText            // "Email [GIVEN_NAME_1] at [EMAIL_1]."
 * redact.close()
 * ```
 */
class Redact private constructor(private val handle: Long) : AutoCloseable {
    /**
     * A redactor that downloads the model on demand (cached under the app's
     * cacheDir), or, when [directory] is given, treats that directory as the
     * model's home (adopt files there, else download into it). Construction is
     * cheap; the model loads on the first [redaction] (or eagerly via [download]).
     */
    constructor(context: android.content.Context, directory: String? = null)
        : this(createHandle(context.cacheDir.absolutePath, directory))

    companion object {
        /**
         * A redactor using the model bundled in your app via the
         * `ai.desertant:redact-onnx-resources` dependency (no network).
         */
        fun bundled(): Redact {
            RedactNative.ensureLoaded()
            val handle = RedactNative.createBundled(
                resource("redact_tokenizer.bin"), resource("labels.json"), resource("redact.onnx"))
            if (handle == 0L) throw RedactException(
                "bundled model unavailable; add the `ai.desertant:redact-onnx-resources` dependency")
            return Redact(handle)
        }

        private fun createHandle(cacheRoot: String, directory: String?): Long {
            RedactNative.ensureLoaded()
            val handle = RedactNative.create(
                cacheRoot.toByteArray(Charsets.UTF_8), directory?.toByteArray(Charsets.UTF_8))
            if (handle == 0L) throw RedactException("failed to create Redact")
            return handle
        }

        private fun resource(name: String): ByteArray =
            (Redact::class.java.getResourceAsStream("/$name")
                ?: throw RedactException(
                    "bundled model resource not found: $name. Add the " +
                        "`ai.desertant:redact-onnx-resources` dependency, or use Redact(context)."))
                .use { it.readBytes() }
    }

    /** Whether the model is available for this redactor with no network. */
    fun isDownloaded(): Boolean = RedactNative.isDownloaded(handle) != 0

    /**
     * Download the model ahead of time so the first [redaction] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download(): Unit = withContext(Dispatchers.IO) {
        if (RedactNative.download(handle) != 0) throw RedactException("model download failed")
    }

    /**
     * Detect and redact the PII in [text]. Each entity is replaced by a unique,
     * numbered placeholder (`[EMAIL_1]`, `[GIVEN_NAME_1]`, ...), safe to hand to
     * an LLM and restore afterwards via [Redaction.restore]. Loads the model
     * lazily on first call.
     */
    suspend fun redaction(text: String, options: Options = Options()): Redaction =
        withContext(Dispatchers.Default) {
            val bytes = RedactNative.run(
                handle, text.toByteArray(Charsets.UTF_8), options.minimumConfidence, csv(options.labels))
                ?: throw RedactException("redaction failed")
            val buf = FfiReader(bytes)  // matches the native FFIWriter encoding
            val redactedText = buf.string()
            val n = buf.int()
            val items = ArrayList<RedactionItem>(n)
            repeat(n) {
                items.add(
                    RedactionItem(
                        label = buf.string(),
                        original = buf.string(),
                        placeholder = buf.string(),
                        confidence = buf.double(),
                        start = buf.int(),
                        end = buf.int(),
                    )
                )
            }
            Redaction(redactedText = redactedText, items = items)
        }

    /** Release the native model. The redactor is unusable afterwards. */
    override fun close() = RedactNative.destroy(handle)

    private fun csv(labels: Set<String>?): ByteArray? =
        labels?.joinToString(",")?.toByteArray(Charsets.UTF_8)
}
