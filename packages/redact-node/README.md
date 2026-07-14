# @desert-ant-labs/redact

On-device multilingual PII redaction for JavaScript (node and browsers). Finds
names, addresses, emails, phone numbers, cards, IBANs, national IDs and more
across the 24 official EU languages, fully locally: the package runs through a
local WebAssembly runtime with inference via ONNX Runtime.

```bash
npm install @desert-ant-labs/redact onnxruntime-node   # or onnxruntime-web in browsers
```

```js
import { Redact } from "@desert-ant-labs/redact";

const redact = await Redact.load();            // downloads the model on demand, cached
const r = await redact.redaction("Email Anna at anna@example.com.");

r.redactedText;      // "Email [GIVEN_NAME_1] at [EMAIL_1]."
r.items;             // detections: label, original, placeholder, confidence, offsets
const reply = await llm(r.redactedText);       // the LLM sees only placeholders
r.restore(reply);    // originals filled back in
```

`Redact.load()` accepts:

- `directory` (node): an explicit model directory; files already there are used
  offline, otherwise the model is downloaded into it. Omit for the managed
  cache (`~/.cache/desert-ant-models/...`).
- `onProgress`: download progress callback, fraction in `[0, 1]`.
- `ort`: bring-your-own ONNX Runtime module (e.g. a bundler-managed
  `onnxruntime-web` import).

The model repo and revision are pinned to the package version. onnxruntime-node
/ onnxruntime-web are optional peer dependencies; the package picks whichever
matches the environment.

The same model ships as a Swift package (iOS/macOS) and an Android AAR from the
same repository: https://github.com/Desert-Ant-Labs/redact

## License

[Desert Ant Labs Source-Available License 1.0](./LICENSE.md): free below
100,000 monthly active devices per platform; above that a commercial license is
required (licensing@desertant.ai). Full terms: https://license.desertant.ai/1.0
