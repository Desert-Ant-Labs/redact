// On-device multilingual PII redaction for JavaScript. All detection logic
// lives in the shared Swift core (dist/RedactWeb.wasm); this file resolves
// model assets, owns the ONNX Runtime session, and exposes the public typed API
// (a `Redact` class with an async `load` factory, mirroring the iOS SDK).
//
// Works in node (onnxruntime-node or -web) and browsers (onnxruntime-web).

const IS_NODE = typeof process !== "undefined" && !!process.versions?.node;

// The wasm core instantiates at import time (top-level await) so the
// deterministic exports are synchronous; the model is only wired in load().
async function instantiateCore() {
  globalThis.__RedactHost ??= {};
  const { instantiate } = await import("./dist/instantiate.js");
  if (IS_NODE) {
    // Give the Swift ModelStore node's fs as a platform seam (no `require`
    // under the WASI shim); the download/verify/cache logic stays in Swift.
    const fsmod = await import("node:fs");
    globalThis.__DalNodeFS = {
      existsSync: fsmod.existsSync, statSync: fsmod.statSync,
      // Copy into an exact-length Uint8Array: node returns pooled Buffers for
      // small files whose .buffer is the whole shared pool, which JavaScriptKit
      // would over-read when marshalling into wasm memory.
      readFileSync: (p) => new Uint8Array(fsmod.readFileSync(p)),
      writeFileSync: fsmod.writeFileSync,
      mkdirSync: fsmod.mkdirSync, renameSync: fsmod.renameSync, unlinkSync: fsmod.unlinkSync,
    };
    const { defaultNodeSetup } = await import("./dist/platforms/node.js");
    await instantiate(await defaultNodeSetup({}));
  } else {
    const { init } = await import("./dist/index.js");
    await init({});
  }
  return globalThis.__RedactExports;
}
const core = await instantiateCore();

async function loadOrt(options) {
  if (options.ort) return options.ort;
  return IS_NODE ? await import("onnxruntime-node") : await import("onnxruntime-web");
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
   * Load the model and return a ready redactor. Download, SHA-256 verification,
   * and caching happen in the shared Swift core (dist/RedactWeb.wasm) via the
   * same ModelStore used on iOS and Android; this host only owns the ONNX
   * session behind the generic tensor contract (createSession + run). The repo
   * and revision are pinned to the SDK.
   */
  static async load(options = {}) {
    const resolved = options;
    const ort = await loadOrt(resolved);
    let session;

    // Generic tensor I/O with the Swift core (JSInferenceSession): both sides
    // exchange { name: { data: Uint8Array, dims: number[], type: "int64"|... } }.
    const typedArray = (t) => {
      const bytes = t.data.slice();  // own, aligned buffer
      switch (t.type) {
        case "int32": return new Int32Array(bytes.buffer);
        case "int64": return new BigInt64Array(bytes.buffer);
        case "float32": return new Float32Array(bytes.buffer);
        default: throw new Error(`unsupported tensor type: ${t.type}`);
      }
    };
    globalThis.__RedactHost = {
      // modelSource is the cached file path (node) or the model bytes (browser).
      createSession: async (modelSource) => {
        session = await ort.InferenceSession.create(modelSource);
      },
      run: async (inputs) => {
        const feeds = {};
        for (const [name, t] of Object.entries(inputs)) {
          feeds[name] = new ort.Tensor(t.type, typedArray(t), Array.from(t.dims));
        }
        const results = await session.run(feeds);
        const outputs = {};
        for (const [name, t] of Object.entries(results)) {
          outputs[name] = {
            data: new Uint8Array(t.data.buffer, t.data.byteOffset, t.data.byteLength),
            dims: t.dims,
            type: t.type,
          };
        }
        return outputs;
      },
    };

    // Base for the managed nested cache (node): ~/.cache. In the browser there
    // is no persistent filesystem, so it stays empty (in-memory).
    let cacheRoot = "";
    if (IS_NODE) {
      const os = await import("node:os");
      const path = await import("node:path");
      cacheRoot = path.join(os.homedir(), ".cache");
    }
    const onProgress = typeof resolved.onProgress === "function" ? resolved.onProgress : undefined;
    await core.load(cacheRoot, resolved.directory ?? "", onProgress);
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
}
