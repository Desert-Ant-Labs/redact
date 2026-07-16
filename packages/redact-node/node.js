// On-device multilingual PII redaction for JavaScript, server-side (Node). This
// is the `node` conditional-exports entry: it runs the same Redact pipeline as
// the browser build, but natively via the prebuilt Swift core (LiteRT under the
// hood) instead of WebAssembly + LiteRT.js. Consumers just `import { Redact }` —
// Node resolves this file, browsers resolve `browser.js`. No flags, no setup.

import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";

const require = createRequire(import.meta.url);
const koffi = require("koffi");
const HERE = path.dirname(fileURLToPath(import.meta.url));

// The prebuilt native for this host lives in native/<platform>-<arch>/ next to
// this file (built by `mise run node-natives`): the self-contained Swift core
// (libRedactNode) plus the LiteRT runtime it links (libLiteRt). The core's
// runpath is `$ORIGIN`, so the two sit side by side and resolve with no
// LD_LIBRARY_PATH.
function nativeDir() {
  const key = `${process.platform}-${process.arch}`;
  const dir = path.join(HERE, "native", key);
  if (!fs.existsSync(dir)) {
    throw new Error(
      `@desert-ant-labs/redact: no prebuilt native for ${key}. ` +
        `Supported server-side targets: linux-x64, linux-arm64, darwin-arm64. ` +
        `Use the Swift package or a browser on this platform.`);
  }
  return dir;
}

const RUNTIME = { linux: "libLiteRt.so", darwin: "libLiteRt.dylib", win32: "LiteRt.dll" };
const CORE = { linux: "libRedactNode.so", darwin: "libRedactNode.dylib", win32: "RedactNode.dll" };

let lib;
function loadLib() {
  if (lib) return lib;
  const dir = nativeDir();
  // Load the LiteRT runtime first so the core's DT_NEEDED resolves in-process.
  const runtime = RUNTIME[process.platform];
  if (runtime && fs.existsSync(path.join(dir, runtime))) koffi.load(path.join(dir, runtime));
  const core = koffi.load(path.join(dir, CORE[process.platform] || CORE.linux));
  lib = {
    create: core.func("void* redact_create(const char*, const char*)"),
    isDownloaded: core.func("int redact_is_downloaded(void*)"),
    download: core.func("int redact_download(void*)"),
    run: core.func("void* redact_run(void*, const char*, double, const char*)"),
    destroy: core.func("void redact_destroy(void*)"),
    stringFree: core.func("void redact_string_free(void*)"),
  };
  return lib;
}

// Run a blocking native function on a libuv worker thread (koffi async) so the
// Node event loop stays free during download and inference.
function callAsync(fn, ...args) {
  return new Promise((resolve, reject) => {
    fn.async(...args, (err, res) => (err ? reject(err) : resolve(res)));
  });
}

/** Decode the FFI buffer the core returns: a big-endian uint32 length prefix,
 *  then the payload (all big-endian; strings are u32 length + UTF-8, offsets are
 *  UTF-16, confidence is an IEEE-754 double). Mirrors `encodeRedaction` in
 *  Sources/RedactAndroid/CABI.swift and the Kotlin FfiReader. */
function decodeRedaction(ptr) {
  const head = Buffer.from(koffi.decode(ptr, koffi.array("uint8", 4)));
  const len = head.readUInt32BE(0);
  const payload = Buffer.from(koffi.decode(ptr, koffi.array("uint8", 4 + len))).subarray(4);
  let o = 0;
  const u32 = () => { const v = payload.readUInt32BE(o); o += 4; return v; };
  const f64 = () => { const v = payload.readDoubleBE(o); o += 8; return v; };
  const str = () => { const n = u32(); const s = payload.toString("utf8", o, o + n); o += n; return s; };
  const redactedText = str();
  const count = u32();
  const items = [];
  for (let i = 0; i < count; i++) {
    const label = str();
    const original = str();
    const placeholder = str();
    const confidence = f64();
    const start = u32();
    const end = u32();
    items.push({ label, original, placeholder, confidence, start, end });
  }
  return { redactedText, items };
}

/**
 * On-device multilingual PII redaction. Create one with `await Redact.load(...)`
 * and reuse it, mirroring the browser SDK and the iOS/Swift SDK.
 *
 * ```js
 * const redact = await Redact.load();                 // downloads the model on demand, cached
 * const r = await redact.redaction("Email Anna at anna@example.com.");
 * r.redactedText; r.items; r.restore(reply);
 * redact.dispose();                                   // free the native handle when done
 * ```
 */
export class Redact {
  #handle;
  constructor(handle) { this.#handle = handle; }

  /**
   * Load the model and return a ready redactor. Download, SHA-256 verification,
   * and caching are handled by the native core; the repo and revision are
   * pinned to the SDK.
   */
  static async load(options = {}) {
    const l = loadLib();
    // Managed nested cache under ~/.cache by default (matches the browser host);
    // an explicit `directory` is adopted if it holds the files, else downloaded.
    const cacheRoot = options.cacheRoot ?? path.join(os.homedir(), ".cache");
    const directory = options.directory ?? null;
    const handle = l.create(cacheRoot, directory);
    if (!handle) throw new Error("@desert-ant-labs/redact: failed to create redactor");
    const redact = new Redact(handle);
    // Ready the model now so the first redaction is instant and load() surfaces
    // any download error, matching the browser's eager `load()`.
    const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
    if (l.isDownloaded(handle) === 0) {
      onProgress?.(0);
      const rc = await callAsync(l.download, handle);
      if (rc !== 0) { redact.dispose(); throw new Error("@desert-ant-labs/redact: model download failed"); }
    }
    onProgress?.(1);
    return redact;
  }

  /**
   * Detect and redact the PII in `text`. Each entity is replaced by a unique,
   * numbered placeholder (`[EMAIL_1]`, ...), safe to hand to an LLM and restore
   * afterwards via `Redaction.restore`.
   */
  async redaction(text, options = {}) {
    if (!this.#handle) throw new Error("@desert-ant-labs/redact: redactor disposed");
    const l = loadLib();
    const minimumConfidence = options.minimumConfidence ?? 0.6;
    const labelsCSV = options.labels ? Array.from(options.labels).join(",") : null;
    const ptr = await callAsync(l.run, this.#handle, text, minimumConfidence, labelsCSV);
    if (!ptr) throw new Error("@desert-ant-labs/redact: redaction failed");
    try {
      const raw = decodeRedaction(ptr);
      const items = raw.items.map((i) => ({ ...i }));
      return {
        redactedText: raw.redactedText,
        items,
        restore(processed) {
          let out = processed;
          for (const item of items) out = out.replaceAll(item.placeholder, item.original);
          return out;
        },
      };
    } finally {
      l.stringFree(ptr);
    }
  }

  /** Free the native handle. Call when you are done with the redactor. */
  dispose() {
    if (this.#handle) { loadLib().destroy(this.#handle); this.#handle = null; }
  }
}
