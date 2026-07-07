# Experiment: the Swift pipeline on the web (node + browser) via WebAssembly

Continuation of the ANDROID.md experiment: instead of maintaining the parallel
TypeScript port (redact-js), compile the Swift package to WebAssembly and run
it in node and the browser. All shared logic (tokenizer, windowing, BIOES
decoding, deterministic recognizers, post-processing) is the same Swift code
that ships on Apple platforms and runs on Android; only inference is provided
by the JS host:

- node: onnxruntime-node
- browser: onnxruntime-web (wasm backend; webgpu would also work)

The seam is the same `InferenceEngine` protocol. For the web it is `JSEngine`
(`Sources/Redact/JSEngine.swift`, WASI-only): the host sets two globals before
the wasm module starts, and the module exposes the redactor back:

```js
globalThis.__redactResources = { tokenizer: Uint8Array, labels: string };
globalThis.__redactRunModel = async (idsInt32Array) =>
    ({ logits: Float32Array, numLabels: number });
// after init:
const result = await globalThis.__redactSwift(text, 0.6);
// { redactedText, items: [{ label, original, placeholder, confidence }] }
```

Resources are injected (rather than `Bundle.module`) because the browser has
no filesystem; the JS host fetches/caches the three model files exactly like
redact-js does today.

The protocol became `async` for this (ORT-web returns Promises and wasm is
single-threaded, so blocking is not an option); the CoreML/ORT backends
satisfy it synchronously and are otherwise unchanged.

Status: works in both node (~70-100 ms per short text) and headless Chromium
(~190 ms), with output identical to the native Linux/CoreML/Android builds on
the test inputs (verified on a 16-sample multilingual battery covering the
deterministic recognizers). `Sources/RedactWasm/main.swift` is the wasm entry
point; `Examples/RedactWasmExample/` has the node harness (`main.mjs`) and the
browser harness (`browser.html` + `browser-test.mjs`, Playwright).

## Size

The release wasm is **4.8 MB raw / 1.7 MB gzipped** (comparable to
onnxruntime-web's own ~11 MB wasm, and much smaller than the ~14 MB ONNX model
that dominates first load either way). A naive build was 62 MB; the wins, in
order:

1. **Regex via the host's `RegExp`** (`RegexEngine.swift`): the deterministic
   layer's ~60 patterns run on `NSRegularExpression` natively but on JS
   `RegExp` under WASI, which is exactly the engine the reference redact-js
   uses, costs zero binary size, and drops corelibs Foundation + its ~40 MB of
   ICU data from the link. The keyword recognizers were restructured to the
   same two-step (keyword, then case-sensitive value) shape as deterministic.ts
   on all platforms, so one code path serves both engines.
2. **NFKC via `String.prototype.normalize`** on WASI (tokenizer), dropping
   FoundationInternationalization.
3. **Pure-Swift UTF-16 view** on WASI (`UTF16Text` is `NSString`-backed
   natively, `[UInt16]`-backed on wasm).
4. **Resources moved to a `RedactResources` target** that is not linked on
   WASI, keeping Foundation's `Bundle` out and the 26 MB resource bundle out
   of the JS package (the host injects tokenizer/labels instead).
5. **No FoundationEssentials at all**: the tokenizer takes `[UInt8]` and the
   label map is parsed by the host's `JSON.parse`, so the wasm links only the
   Swift stdlib, concurrency runtime, and JavaScriptKit.
6. **`-Osize` + `wasm-opt -Oz` + section stripping** (install binaryen so the
   PackageToJS plugin finds `wasm-opt`; a final `-Oz` pass plus
   `--strip-debug` takes it from ~13 MB to 4.8 MB).

Remaining weight is essentially the Swift stdlib (~2.3 MB of code) and the
Swift/wasm runtime; going meaningfully below this would require Embedded
Swift, which is too restrictive for this code today.

Native parity was re-verified after the regex refactor: the linux test suite
passes, the CLI output is unchanged, and native-vs-wasm output is identical on
the full sample battery.

## Build

One-time: install the official Swift SDK for WebAssembly matching the toolchain:

```bash
swift sdk install https://download.swift.org/swift-6.3.2-release/wasm-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_wasm.artifactbundle.tar.gz
```

Build the JS package with JavaScriptKit's PackageToJS plugin (the explicit SDK
id avoids the ambiguity with the bundled embedded variant):

```bash
swift package --swift-sdk swift-6.3.2-RELEASE_wasm js --product RedactWasm            # debug
swift package -Xswiftc -Osize --swift-sdk swift-6.3.2-RELEASE_wasm js \
  --product RedactWasm -c release --output .build/wasm-release
# with binaryen's wasm-opt on PATH, then squeeze further:
wasm-opt -Oz --enable-bulk-memory --enable-nontrapping-float-to-int \
  --enable-sign-ext --enable-reference-types --strip-debug --strip-producers \
  .build/wasm-release/RedactWasm.wasm -o .build/wasm-release/RedactWasm.wasm
```

Output is an npm-style package (`index.js`, `instantiate.js`,
`platforms/{browser,node}.js`, `RedactWasm.wasm`).

## Run

```bash
cd Examples/RedactWasmExample
npm install                       # onnxruntime-node/-web, wasi shim, playwright
node main.mjs "some text"         # node
node browser-test.mjs             # headless Chromium
```

(The generated package imports `@bjorn3/browser_wasi_shim`; the node harness
symlinks its node_modules into the output dir, the browser harness uses an
import map.)

## Caveats / next steps

- Interface: the global-based bridge is experiment-grade. A real package would
  wrap init/inference/resources in a small typed JS facade (or JavaScriptKit's
  BridgeJS exports) and publish the PackageToJS output to npm.
- wasm is single-threaded here; fine for this workload since inference (the
  heavy part) runs in ORT's own threaded wasm/native code on the JS side.
- The `redact-cli` and `RedactWasm` targets coexist; `redact-cli` is compiled
  out on WASI (DispatchSemaphore is unavailable there).
