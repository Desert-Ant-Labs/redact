# Redact Android Example

A tiny Android app for trying Redact with the Maven Central package `ai.desertant:redact`.

## Run

Connect a device or start an emulator, then run:

```bash
./gradlew :app:installDebug
```

The first redaction downloads the pinned ONNX model to the app cache. Later runs use the cached model offline.
