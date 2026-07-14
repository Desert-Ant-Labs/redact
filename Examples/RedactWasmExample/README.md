# Redact JavaScript Examples

Tiny Node and browser examples for trying Redact with the local WebAssembly runtime and ONNX Runtime.

## Run in Node

From the repository root, build the web package first:

```bash
mise run build-web
```

Then run:

```bash
cd Examples/RedactWasmExample
node main.mjs
```

Pass your own text as arguments:

```bash
node main.mjs "Email Anna at anna@example.com"
```

## Run in a browser

From the repository root, build the web package first:

```bash
mise run build-web
```

Then run the browser test helper:

```bash
cd Examples/RedactWasmExample
node browser-test.mjs
```

The first redaction downloads the pinned ONNX model to the local cache. Later runs use the cached model offline when the host cache is available.
