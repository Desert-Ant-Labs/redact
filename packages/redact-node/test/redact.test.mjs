// The redact-node test suite. Runs through the WebAssembly runtime with model
// files loaded from the local ONNX resources instead of the Hugging Face Hub.
import assert from "node:assert/strict";
import { test } from "node:test";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Redact } from "../index.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const directory = path.join(here, "../../../Sources/RedactONNXResources/Resources");

let redact;
let loadError;
try {
  redact = await Redact.load({ directory });
} catch (e) {
  loadError = e;
}
const modelOpts = redact ? {} : { skip: `model unavailable: ${String(loadError).slice(0, 80)}` };

test("redaction masks names, email, IBAN", modelOpts, async () => {
  const r = await redact.redaction("Email Anna Kovács at anna@example.hu, IBAN DE89370400440532013000.");
  assert.match(r.redactedText, /\[GIVEN_NAME_1\]/);
  assert.match(r.redactedText, /\[EMAIL_1\]/);
  assert.match(r.redactedText, /\[BANK_ACCOUNT_1\]/);
  assert.equal(r.items.find((i) => i.label === "EMAIL")?.original, "anna@example.hu");
});

test("addresses, VAT, IMEI redacted", modelOpts, async () => {
  const r = await redact.redaction("Ship to 123 Main Street, Apt 4B. VAT DE129273398, IMEI 490154203237518.");
  const got = new Set(r.items.map((i) => i.label));
  for (const l of ["BUILDING_NUMBER", "STREET_NAME", "SECONDARY_ADDRESS", "TAX_ID", "IMEI"]) {
    assert.ok(got.has(l), `expected ${l}`);
  }
});

test("restore round-trips exactly", modelOpts, async () => {
  const text = "Call Dr. Alice Grant on +49 30 1234567.";
  const r = await redact.redaction(text);
  assert.equal(r.restore(r.redactedText), text);
});

test("label filter", modelOpts, async () => {
  const r = await redact.redaction("Anna at anna@x.com, IBAN DE89370400440532013000.", { labels: ["EMAIL"] });
  assert.deepEqual(new Set(r.items.map((i) => i.label)), new Set(["EMAIL"]));
});
