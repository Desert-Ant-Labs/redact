// Node harness for the Swift-compiled-to-wasm redact pipeline.
// The wasm module owns all logic (tokenizer, windowing, decoding,
// deterministic recognizers, post-processing); this host only provides the
// ONNX inference (onnxruntime-node here, onnxruntime-web in a browser) and
// the two resource files.
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as ort from "onnxruntime-node";
import { instantiate } from "../../.build/wasm-release/instantiate.js";
import { defaultNodeSetup } from "../../.build/wasm-release/platforms/node.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const resources = path.join(here, "../../Sources/RedactResources/Resources");

// 1. Inject the tokenizer + label map (in a browser these would be fetched).
globalThis.__redactResources = {
  tokenizer: new Uint8Array(await readFile(path.join(resources, "redact_tokenizer.bin"))),
  labels: await readFile(path.join(resources, "labels.json"), "utf8"),
};

// 2. Provide the platform inference runtime.
const session = await ort.InferenceSession.create(path.join(resources, "redact.onnx"));
globalThis.__redactRunModel = async (idsInt32Array) => {
  const n = idsInt32Array.length;
  const ids = BigInt64Array.from(idsInt32Array, (v) => BigInt(v));
  const mask = new BigInt64Array(n).fill(1n);
  const out = await session.run({
    input_ids: new ort.Tensor("int64", ids, [1, n]),
    attention_mask: new ort.Tensor("int64", mask, [1, n]),
  });
  const logits = out.logits;
  return {
    logits: Float32Array.from(logits.data),
    numLabels: Number(logits.dims[2]),
  };
};

// 3. Boot the Swift wasm module and call it.
await instantiate(await defaultNodeSetup({}));
const redact = globalThis.__redactSwift;

const text = process.argv.slice(2).join(" ") ||
  "Hi, I'm Anna Kowalska. Email me at anna.k@example.com or call +1 (555) 010-4477. " +
  "I live at 123 Any Street, Apt 4B, Seattle, WA 98109. Card: 4539 1488 0343 6467.";

const start = Date.now();
const result = await redact(text, 0.6);
console.log("input:    " + text);
console.log("redacted: " + result.redactedText);
for (const item of result.items) {
  console.log(`  ${item.placeholder}  <-  "${item.original}"  (${item.label}, ${item.confidence.toFixed(2)})`);
}
console.log(`(${Date.now() - start} ms)`);
