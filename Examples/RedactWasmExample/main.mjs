// Node example for packages/redact-node with local WebAssembly and
// onnxruntime-node inference.
import { Redact } from "../../packages/redact-node/index.js";

// Redact downloads, verifies (SHA-256), and caches the model from the Hub;
// onnxruntime-node runs inference. First run fetches; later runs are cached.
const redact = await Redact.load({});

const text = process.argv.slice(2).join(" ") ||
  "Hi, I'm Anna Kowalska. Email me at anna.k@example.com or call +1 (555) 010-4477. " +
  "I live at 123 Any Street, Apt 4B, Seattle, WA 98109. Card: 4539 1488 0343 6467.";

const start = Date.now();
const r = await redact.redaction(text);
console.log("input:    " + text);
console.log("redacted: " + r.redactedText);
for (const item of r.items) {
  console.log(`  ${item.placeholder}  <-  "${item.original}"  (${item.label}, ${item.confidence.toFixed(2)})`);
}
console.log("restored: " + r.restore(r.redactedText));
console.log(`(${Date.now() - start} ms)`);
