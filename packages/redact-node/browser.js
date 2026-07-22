// On-device multilingual PII redaction for JavaScript. This is the universal
// entry: it resolves model assets, owns the LiteRT.js session, and exposes the
// public typed API (a `Redact` class with an async `load` factory). It runs in
// the browser and, via the platform seam below, server-side in Node (the
// Client-Component SSR pass frameworks render in Node), both on the same
// WebAssembly + @litertjs/core (LiteRT.js) pipeline: XNNPACK-accelerated CPU
// ("wasm") by default, with optional WebGPU in the browser.
//
// All node-only code lives behind the `#platform` import, which bundlers resolve
// at build time by condition (browser -> platform-browser.js, otherwise
// platform-node.js). That keeps this file free of `node:*` and of any static
// reference to node-only chunks, so a single import builds cleanly for every
// target of a multi-target bundler. For a prebuilt native server core (no
// @litertjs/core, best server throughput), import `@desert-ant-labs/redact/native`.
import { setupCore, defaultWasmDir, readModelSource, defaultCacheRoot } from "#platform";

// The wasm core instantiates at import time (top-level await); the model is
// only wired in load(). The build-time-selected platform seam owns whatever is
// node- or browser-specific about instantiation.
const core = await setupCore();

// @litertjs/core (LiteRT.js) is loaded once per process; its Wasm runtime files
// (node_modules/@litertjs/core/wasm/) initialize a single time. Callers can
// inject a module via `options.litert` (tests/custom builds) and override the
// Wasm directory via `options.litertWasmDir`.
async function loadLiteRtModule(options) {
  if (options.litert) return options.litert;
  try {
    return await import("@litertjs/core");
  } catch (cause) {
    // Only surface the install hint when @litertjs/core is genuinely absent;
    // rethrow anything else (a real error from inside LiteRT.js) unchanged.
    const missingLiteRt =
      cause?.code === "ERR_MODULE_NOT_FOUND" ||
      cause?.code === "MODULE_NOT_FOUND" ||
      String(cause?.message ?? "").includes("@litertjs/core");
    if (!missingLiteRt) throw cause;
    throw new Error(
      "@desert-ant-labs/redact browser runtime requires @litertjs/core. " +
        "Install it with: npm i @desert-ant-labs/redact @litertjs/core. " +
        "If you already bundle LiteRT.js yourself, pass it to Redact.load({ litert }). " +
        "(In Node, import the package normally to use the native server-side build instead.)",
      { cause },
    );
  }
}

async function resolveWasmDir(options) {
  if (options.litertWasmDir) return options.litertWasmDir;
  return defaultWasmDir();
}

// LiteRT.js loads its Wasm runtime through the DOM (a <script> tag) or a Web
// Worker (importScripts); it has no plain-Node loader. So the default (wasm)
// build can be imported during SSR but cannot run inference in Node. Detect that
// up front and redirect to the native server build instead of letting LiteRT.js
// fail deep inside with a cryptic `document is not defined`.
function assertRuntimeCanLoadLiteRt(options) {
  if (options.litert) return; // caller injected a working module; trust it
  const hasDom = typeof document !== "undefined";
  const hasWorker = typeof importScripts === "function";
  if (hasDom || hasWorker) return;
  throw new Error(
    "@desert-ant-labs/redact: the default import runs the browser WebAssembly " +
      "runtime (LiteRT.js), which needs a browser/Worker environment and can't " +
      "initialize in plain Node. For server-side inference import the native " +
      "build instead: import { Redact } from \"@desert-ant-labs/redact/native\". " +
      "(The default import is still safe to bundle for server-side rendering; " +
      "only calling Redact.load() in Node needs the native build.)",
  );
}

let liteRtReady;
async function ensureLiteRt(options, lrt) {
  liteRtReady ??= lrt.loadLiteRt(await resolveWasmDir(options));
  await liteRtReady;
}

/**
 * On-device multilingual PII redaction. Create one with `await Redact.load(...)`
 * and reuse it, mirroring the iOS/Swift SDK.
 *
 * ```js
 * const redact = await Redact.load();               // download on demand, cached
 * const r = await redact.redaction("Email Anna at anna@example.com.");
 * r.redactedText; r.items; r.restore(reply);
 * ```
 */
export class Redact {
  /**
   * Load the model and return a ready redactor. By default the runtime downloads
   * the model from the Hugging Face Hub at the SDK's pinned tag (fetched + cached
   * by the browser) and this host owns the LiteRT.js session behind the generic
   * tensor contract (createSession + run). Pass `modelBaseUrl` (a base URL you
   * serve the files from) to self-host / run without the Hub. The repo and
   * revision are pinned to the SDK.
   */
  static async load(options = {}) {
    const resolved = options;
    assertRuntimeCanLoadLiteRt(resolved);
    const lrt = await loadLiteRtModule(resolved);
    await ensureLiteRt(resolved, lrt);
    const { loadAndCompile, Tensor } = lrt;
    const accelerator = resolved.accelerator ?? "wasm";
    let model;

    // Generic tensor I/O with the WebAssembly runtime (JSInferenceSession): both
    // sides exchange { name: { data: Uint8Array, dims: number[], type: "int32"|... } }.
    // The redact tflite takes int32 input_ids + attention_mask and returns a
    // float32 logits tensor; LiteRT.js infers each dtype from the typed array.
    const typedArray = (t) => {
      const bytes = t.data.slice();  // own, aligned buffer
      switch (t.type) {
        case "int32": return new Int32Array(bytes.buffer);
        case "float32": return new Float32Array(bytes.buffer);
        case "uint8": return new Uint8Array(bytes.buffer);
        default: throw new Error(`unsupported tensor type: ${t.type}`);
      }
    };
    globalThis.__RedactHost = {
      // modelSource is the cached file path (node) or the model bytes (browser).
      createSession: async (modelSource) => {
        const modelData = await readModelSource(modelSource);
        model = await loadAndCompile(modelData, { accelerator });
      },
      run: async (inputs) => {
        const feeds = {};
        const made = [];
        for (const [name, t] of Object.entries(inputs)) {
          const tensor = new Tensor(typedArray(t), Array.from(t.dims));
          feeds[name] = tensor;
          made.push(tensor);
        }
        // LiteRT.js uses manual memory management: results and any GPU->wasm
        // copies must be deleted, along with the input tensors we made.
        const results = await model.run(feeds);
        const outputs = {};
        const toDelete = [...made];
        for (const [name, out] of Object.entries(results)) {
          const host = accelerator === "wasm" ? out : await out.moveTo("wasm");
          const arr = host.toTypedArray();
          outputs[name] = {
            data: new Uint8Array(arr.buffer.slice(arr.byteOffset, arr.byteOffset + arr.byteLength)),
            dims: Array.from(host.type.layout.dimensions),
            type: host.type.dtype,
          };
          toDelete.push(out);
          if (host !== out) toDelete.push(host);
        }
        for (const t of toDelete) t.delete();
        return outputs;
      },
    };

    const onProgress = typeof resolved.onProgress === "function" ? resolved.onProgress : undefined;
    if (resolved.modelBaseUrl != null) {
      // Self-hosted files (offline / no runtime CDN): fetch the model + sidecars
      // from the given base URL, compile the model here, and hand the labels +
      // tokenizer to the wasm core, no Hub download. This is the browser opt-out,
      // e.g. an app that serves the model from its own origin.
      const { labelsJSON, tokenizerBytes, modelBytes } = await fetchModelFrom(resolved.modelBaseUrl);
      model = await loadAndCompile(modelBytes, { accelerator });
      await core.loadBundled(labelsJSON, tokenizerBytes);
      onProgress?.(1);
    } else {
      // Default: the runtime downloads this platform's files from the HF Hub at
      // the pinned tag (SHA-256 verified), fetched + cached by the JS host, and
      // wires the session through createSession above. `directory` (node) adopts
      // a self-hosted folder. Base for the managed nested cache (node): ~/.cache;
      // empty (in-memory) in the browser.
      const cacheRoot = await defaultCacheRoot();
      await core.load(cacheRoot, resolved.directory ?? "", onProgress);
    }
    return new Redact();
  }

  /**
   * Detect and redact the PII in `text`. Each entity is replaced by a unique,
   * numbered placeholder (`[EMAIL_1]`, ...), safe to hand to an LLM and restore
   * afterwards via `Redaction.restore`.
   */
  async redaction(text, options = {}) {
    const raw = await core.redaction(
      text, options.minimumConfidence ?? 0.6,
      options.labels ? Array.from(options.labels) : undefined);
    const items = Array.from(raw.items).map((i) => ({ ...i }));
    return {
      redactedText: raw.redactedText,
      items,
      restore(processed) {
        let out = processed;
        for (const item of items) out = out.replaceAll(item.placeholder, item.original);
        return out;
      },
    };
  }

  /**
   * Free native resources. No-op in the WebAssembly runtime; present so the same
   * code works against the native server build (`@desert-ant-labs/redact/native`).
   */
  dispose() {}
}

// Fetch self-hosted model files from a base URL (the `modelBaseUrl` opt-out).
// Accepts absolute URLs and root-relative paths (e.g. "/assets/redact/").
async function fetchModelFrom(baseUrl) {
  const base = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
  const [labels, tokenizer, model] = await Promise.all([
    fetch(`${base}labels.json`).then((r) => r.text()),
    fetch(`${base}redact_tokenizer.bin`).then((r) => r.arrayBuffer()),
    fetch(`${base}redact.tflite`).then((r) => r.arrayBuffer()),
  ]);
  return {
    labelsJSON: labels,
    tokenizerBytes: new Uint8Array(tokenizer),
    modelBytes: new Uint8Array(model),
  };
}
