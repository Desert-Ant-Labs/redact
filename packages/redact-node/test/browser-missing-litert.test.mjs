// Proves the browser entry (browser.js) throws an actionable install message
// when the optional `@litertjs/core` peer dependency is absent. We run a child
// Node process with a module-resolution hook that makes `@litertjs/core`
// unresolvable, import browser.js there, and assert `Redact.load` rejects with the
// "npm i ... @litertjs/core" guidance.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const pkgDir = path.resolve(here, "..");
const browserUrl = new URL("../browser.js", import.meta.url).href;

// A loader that fails to resolve @litertjs/core, simulating a consumer who
// installed the SDK but forgot the optional browser peer dependency.
const loaderSrc = `
export async function resolve(spec, ctx, next) {
  if (spec === "@litertjs/core") throw new Error("simulated missing @litertjs/core");
  return next(spec, ctx);
}`;
const loaderUrl = "data:text/javascript," + encodeURIComponent(loaderSrc);

const child = `
import { register } from "node:module";
register(${JSON.stringify(loaderUrl)});
const { Redact } = await import(${JSON.stringify(browserUrl)});
try {
  await Redact.load({});
  console.log("NO_ERROR");
} catch (e) {
  console.log("ERR:" + e.message);
}`;

test("browser.js gives an actionable error when @litertjs/core is missing", () => {
  const res = spawnSync(process.execPath, ["--input-type=module", "-e", child],
    { cwd: pkgDir, encoding: "utf8", timeout: 120000 });
  const out = (res.stdout || "") + (res.stderr || "");
  assert.ok(out.includes("ERR:"), `expected a thrown error, got:\n${out}`);
  assert.ok(/@litertjs\/core/.test(out) && /npm i/.test(out),
    `expected an actionable install message, got:\n${out}`);
});
