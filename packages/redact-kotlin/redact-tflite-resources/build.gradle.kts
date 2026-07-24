// Optional bundled model for Redact on Android; the ai.desertant.model-resources
// convention plugin packages the LiteRT files staged by `mise run android-natives`.
plugins { id("ai.desertant.model-resources") }
version = "0.7.0"
desertAntResources { tfliteFiles = listOf("redact.tflite", "redact_tokenizer.bin", "labels.json") }
