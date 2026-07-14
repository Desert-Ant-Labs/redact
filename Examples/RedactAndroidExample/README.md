# Redact Android Example

A tiny Android app demonstrating on-device PII redaction with the Maven Central package `ai.desertant:redact`.

```bash
./gradlew :app:installDebug
```

The first redaction downloads the pinned ONNX model and tokenizer to the app cache. Later runs use the cached model offline.
