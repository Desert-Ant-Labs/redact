# Architecture

One Swift core, every platform. The same pipeline code (tokenizer, windowing,
BIOES decoding, deterministic recognizers, span post-processing) runs on
Apple platforms, Android, Linux, node, and browsers. Everything
platform-shaped (regex, JSON, downloads, inference runtimes, session
selection) comes from the reusable, model-agnostic `desert-ant-core` package;
this repo carries per-platform *data* (which artifact ships where, tensor
layouts per export) and the per-platform binding products, not platform code.

```
(dependency) desert-ant-core    reusable primitives, shared across models:
  Regex        stdlib-shaped matching, type `Pattern` (String.Index/Substring)
  JSON         Foundation.JSONDecoder-shaped Codable decoding
  FFIBuffer    length-prefixed typed C-ABI buffer (FFIWriter/ffiEmit/ffiFree)
  HostBridge   Android JNI harness: marshalling + installs CHostBridge callbacks
  CHostBridge  generic host-callback bridge HostBridge installs on Android
  ModelStore   verified downloads + platform-neutral StoredModel file access
  ModelResources  SwiftPM bundle file loading
  Inference    named-tensor sessions + the platform session factory
               (CoreMLSession | ORTSession | JSInferenceSession)
  PlatformSupport environment access, FFI/async bridge, LazyLoader
               (single-flight loading), MessageError

Sources/Redact/                 the shared core (imports Regex, JSON)
├─ Redact.swift                 public API (Redact, Redaction, Options)
├─ Label.swift                  the public label taxonomy
├─ Model.swift                  orchestration: windowing, decoding, merging
├─ Tokenizer.swift              XLM-R SentencePiece unigram (pure Swift port)
├─ Deterministic.swift          regex + checksum recognizers (v1.4)
├─ Pipeline.swift               span post-processing / hybrid resolution
├─ Span.swift                   Span + UTF-16 text view
└─ ModelLoading.swift           obtaining the model: file manifest, per-platform
                               artifact names (data), download/adopt/bundle
                               sources, ModelAssets (sidecars + a ready session)

Sources/RedactCoreMLResources/  Apple/Core ML resources (no ONNX)
Sources/RedactONNXResources/    ONNX resources for Linux (Android gets assets via FFI)
Sources/RedactAndroid/          Android JNI (harness in desert-ant-core):
                                CABI.swift (redact_* C ABI, payload schema on
                                FFIBuffer.FFIWriter), AndroidJNI.swift (@_cdecl
                                Java_... calling HostBridge's marshalling + install)
Sources/RedactWeb/              wasm entry point (JS bridge)
```

NFKC normalization, bundle loading, cached-file access, process environment,
the blocking async bridge used by FFI, and the inference runtimes themselves
(Core ML, ONNX Runtime with its vendored C header, the JS host session) are no
longer model platform code. They come from desert-ant-core's
`TextNormalization`, `ModelResources`, `ModelStore`, `PlatformSupport`, and
`Inference` modules. `CAndroidICU` still requires Android API 31+.

## Rules that keep it clean

1. **Model code imports nothing platform-shaped.** It may import
   desert-ant-core modules whose public APIs carry no platform detail, but no
   Foundation, no platform modules, and (almost) no `#if`. Platform variation
   is expressed as data (`RedactModel.artifact` per `ModelPlatform`, a
   `ModelLayout` per export) and resolved by core's `inferenceSession`
   factory, which picks Core ML, ONNX Runtime, or the JS host itself. The one
   `#if` left is `Redact(bundle:)`, whose signature uses the Foundation
   `Bundle` type. If a change needs a platform import, it belongs inside the
   `desert-ant-core` primitives instead.
2. **Binding targets are the edges.** `RedactAndroid` (C ABI + JNI) and
   `RedactWeb` (wasm entry point) are per-platform products by nature; they
   stay thin and call the same shared `Redact` API.
3. **Use native SDKs first.** These backends live in `desert-ant-core`'s
   `Regex`, `JSON`, and `TextNormalization` primitives, one per platform: Apple
   and Linux use Foundation (`NSRegularExpression`, `JSONDecoder`,
   `precomposedStringWithCompatibilityMapping`); wasm uses the host JavaScript
   SDK (`RegExp`, `JSON.parse`, `String.prototype.normalize`). Android is the
   exception: the native Swift library must not link Foundation because it would
   add tens of megabytes, so Android uses `java.util.regex.Pattern` through JNI
   callbacks for regex, Android platform ICU (`libicu`, API 31+) for NFKC, and
   the Kotlin host's native JSON to parse
   `labels.json`. Nothing hand-rolls JSON: the FFI returns results as a
   length-prefixed typed buffer (built with `desert-ant-core`'s `FFIWriter`,
   decoded by its `FfiReader`, a `java.nio.ByteBuffer` cursor). The JNI harness
   itself (byte marshalling, thread attach/detach, installing the
   `CHostBridge` callbacks) is `desert-ant-core`'s `HostBridge`; RedactAndroid
   keeps only the `redact_*` entry points and the redaction payload schema.
4. **Regex patterns are written in the common ICU/JS subset** (no inline
   `(?i)` flags, no possessive quantifiers; `\p{...}` is fine). The pipeline
   is a direct port of the JS/Python reference and is kept in parity with the
   shared span corpus; keyword recognizers use the reference's two-step
   (case-insensitive keyword, case-sensitive value) shape so one code path
   serves both engines.
5. **Spans are UTF-16 offsets** everywhere, matching the reference pipeline's
   indexing exactly.

## How each platform gets its assets

The model is **downloaded on demand by default**. `Redact(directory:)` is where
the model lives (adopted if present, downloaded there if not; `nil` uses a
managed cache), and `Redact(bundle:)` uses an opt-in resources target.
desert-ant-core's
`ModelDistribution` owns the current platform's file list plus download,
verification, caching, and local-directory validation; each `Platform` seam
turns the resolved files (or a bundle) into `ModelAssets` (tokenizer bytes,
labels JSON, model path). `ModelLoading.swift` is the only place that names the
per-platform file lists.

- **Apple / Linux (SwiftPM):** download on demand by default. To bundle instead,
  add a resources product and pass its bundle to `Redact(bundle:)`: Apple uses
  `RedactCoreMLResources` (`redact.mlmodelc`, no ONNX); Linux/Windows use
  `RedactONNXResources` (`redact.onnx`, no Core ML). The core `Redact` library
  no longer depends on or ships the model.
- **Android (AAR):** an instance API mirroring iOS. The base `redact` AAR ships
  no model and downloads on demand (`redact_create(directory)` through JNI, a
  handle per redactor). Bundling is opt-in via the separate
  `:redact-onnx-resources` artifact, whose bytes Kotlin injects with
  `redact_create_bundled` (`packages/redact-kotlin`).
- **Web (wasm):** the shared `ModelStore` downloads and verifies all files; the
  wasm `Platform` seam then hands the model path (node) or bytes (browser) to
  `__RedactHost.createSession` once, and inference runs on the JS side
  (`packages/redact-node`).

## The desert-ant-core primitives (Regex, JSON, FFIBuffer, HostBridge)

The `Regex` and `JSON` modules live in the reusable `desert-ant-core` package
(model-agnostic, shared across models) with public APIs shaped like the
standard library, so they feel native:

- `let re = try Pattern(pattern); text.firstMatch(of: re)` / `text.matches(of: re)`
  return a `Match` whose captures are `Range<String.Index>` + `Substring`
  (index 0 is the whole match), mirroring stdlib `Regex`. The type is `Pattern`
  (not `Regex`, which would clash with the standard library); `rx(_:)` /
  `regex(_:)` are free-function conveniences. It intentionally does not conform
  to `RegexComponent` (that would force the stdlib engine).
- `try JSONDecoder().decode(T.self, from: json)` decodes any `Decodable` with
  the same shape as `Foundation.JSONDecoder` (input is `String`/`[UInt8]`, since
  `Data` is Foundation-only). the core also exposes UTF-16 offset matches for cross-language pipelines;
  `Redact/RegexOffsets.swift` only adds concise pipeline aliases.

Each has one backend file per platform behind that same public API:

- **Apple and Linux:** Foundation (`NSRegularExpression`, `JSONDecoder`).
- **Android:** the host's `java.util.regex` and JSON parser, reached through
  `CHostBridge`. The callbacks are installed by `desert-ant-core`'s `HostBridge`
  (`installHostBridge`), the reusable JNI harness `RedactAndroid` calls; it also owns
  the byte marshalling and thread attach/detach. No regex engine, JSON parser,
  or Foundation is linked into the native library; it does require Android API
  31+ for `libicu` (used for NFKC).

`FFIBuffer` and `HostBridge` are the extracted Android FFI/JNI harness: any
model SDK returns C-ABI results with `FFIWriter` (decoded by the Kotlin
`FfiReader`) and gets JNI marshalling + host-callback install from `HostBridge`,
keeping only its own `@_cdecl("Java_...")` entry points and payload schema. The
Kotlin host (`regexMatches`/`jsonParseTree` + `FfiReader`) is vendored from
`desert-ant-core/kotlin/HostBridge.kt` until a core Android artifact is published.
- **wasm:** the host engine's `RegExp` and `JSON.parse`, zero binary cost and
  byte-compatible with the reference JS implementation.

Why three backends and not one: the deterministic layer needs lookbehind and
`\p{...}`, which Swift Regex does not fully support yet, and a pure-Swift JSON
parser would be one more thing to maintain. Both are verified identical on the
1354-case deterministic corpus plus a multilingual end-to-end battery on every
backend. Patterns are written in the common ICU/JS/Java subset (no inline
`(?i)` flags, no possessive quantifiers; `\p{...}` is fine).
