# @desert-ant-labs/redact

On-device multilingual PII redaction for JavaScript that runs **the same code in
the browser and server-side in Node**. Finds names, addresses, emails, phone
numbers, cards, IBANs, national IDs and more across the 24 official EU languages,
fully locally.

One import, resolved automatically by conditional exports:

- **Browser** (bundlers, `import` in a web app): a local WebAssembly pipeline
  with [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference
  (XNNPACK-accelerated CPU by default, optional WebGPU).
- **Node** (server-side): a prebuilt native core (LiteRT on Linux, Core ML on
  macOS). No build tools, no flags.

```bash
# Browser builds:
npm i @desert-ant-labs/redact @litertjs/core

# Node only:
npm i @desert-ant-labs/redact
```

```js
import { Redact } from "@desert-ant-labs/redact";

const redact = await Redact.load();            // downloads the model from HF at the pinned tag, cached
const r = await redact.redaction("Email Anna at anna@example.com.");

r.redactedText;      // "Email [GIVEN_NAME_1] at [EMAIL_1]."
r.items;             // detections: label, original, placeholder, confidence, offsets
const reply = await llm(r.redactedText);       // the LLM sees only placeholders
r.restore(reply);    // originals filled back in

redact.dispose();    // (Node) free the native handle when done; no-op in the browser
```

`Redact.load()` accepts:

- `directory` (Node): an explicit model directory to self-host / run offline;
  files already there are used without a download, otherwise the model is
  downloaded into it. Omit for the managed cache
  (`~/.cache/desert-ant-models/...`).
- `modelBaseUrl` (Browser): a base URL you serve the model files from (e.g.
  `"/assets/redact/"`), loaded instead of the Hub for self-host / offline setups.
- `cacheRoot` (Node): base directory for the managed cache (default `~/.cache`).
- `onProgress`: download progress callback, fraction in `[0, 1]`.
- `litert` (browser): bring-your-own LiteRT.js module (the `@litertjs/core`
  namespace, e.g. a bundler-managed import).
- `litertWasmDir` (browser): URL/path to the LiteRT.js Wasm files (defaults to
  the installed package, or the jsDelivr CDN in the browser).
- `accelerator` (browser): `"wasm"` (XNNPACK CPU, default), `"webgpu"`, or
  `"webnn"`.

By default the model is **downloaded from the Hugging Face Hub on first use** (at
the revision pinned to this package version), SHA-256 verified, and cached for
later runs, so nothing model-sized ships in the npm tarball. In Node the cache is
the OS cache dir; in the browser it is the fetch cache. Use `directory` (Node) or
`modelBaseUrl` (browser) to self-host / run fully offline. `@litertjs/core` is an
optional peer dependency (browser builds only).

The same model ships as a Swift package (iOS/macOS) and an Android AAR from the
same repository: https://github.com/Desert-Ant-Labs/redact

## License

[Desert Ant Labs Source-Available License 1.0](./LICENSE.md): free below
100,000 monthly active devices per platform; above that a commercial license is
required (licensing@desertant.ai). Full terms: https://license.desertant.ai/1.0
