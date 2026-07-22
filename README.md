# Redact

On-device multilingual PII redaction for Swift, Android, and JavaScript. Redact finds and masks personal data in text: names, addresses, emails, phone numbers, cards, IBANs, national IDs, VAT numbers, URLs, IP addresses, and more across all 24 official EU languages. Everything runs locally, so your text never leaves the device or browser.

Redaction is reversible. Mask PII before sending text to an LLM or another service, then restore the originals in the response on device. Keep the placeholder mapping and the result is pseudonymized; drop it and the masked copy is anonymized.

```text
Email Anna Kovács at anna@example.hu.
Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1].
```

- [Features](#features)
- [Swift](#swift)
  - [Install](#install)
  - [Usage](#usage)
  - [Example](#example)
- [Android](#android)
  - [Install](#install-1)
  - [Usage](#usage-1)
  - [Example](#example-1)
- [JavaScript and TypeScript](#javascript-and-typescript)
  - [Install](#install-2)
  - [Usage](#usage-2)
  - [Example](#example-2)
- [Reversible redaction for LLMs](#reversible-redaction-for-llms)
- [Categories](#categories)
- [Model and caching](#model-and-caching)
- [License](#license)

## Features

- Runs fully on device or in the local runtime. Text never leaves the machine.
- Detects 20 model categories plus deterministic IMEI: names, addresses, emails, phone numbers, credit cards, IBANs, routing numbers, IP addresses, URLs, government IDs, passports, driving licences, tax IDs, SSNs, and more.
- Supports all 24 official EU languages, including Latin, Greek, and Cyrillic scripts.
- Validates structured fields with dependency-free rules: Luhn cards, ISO-13616 IBANs, BIC, VIN, checksum-validated national IDs for all 24 EU countries, all 27 EU VAT numbers, IMEI, and per-country driving licences.
- Reversible redaction with unique numbered placeholders such as `[EMAIL_1]` and `[BANK_ACCOUNT_1]`.
- Small 4-bit model, downloaded on demand and cached by default, or bundled for offline apps.

## Swift

### Install

Requirements: iOS 16+, macOS 13+, tvOS 16+, visionOS 1+, and Swift 5.9+.

Add Redact with Swift Package Manager:

```swift
.package(url: "https://github.com/Desert-Ant-Labs/redact.git", from: "0.6.3")
```

Then add the `Redact` product to your app target.

To bundle the Core ML model for fully offline Apple apps, also add `RedactCoreMLResources` to your target.

### Usage

Create one `Redact` and reuse it. Construction is cheap and non-blocking. The model loads on first use, or earlier if you call `download`.

```swift
import Redact

let redact = Redact()
let result = try await redact.redaction(of: "Email Anna Kovács at anna@example.hu.")

print(result.redactedText)
// Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1].

for item in result.items {
    print(item.label.displayName, item.original, item.confidence)
}

let reply = try await myLLM.rewrite(result.redactedText)
let restored = result.restore(reply)
```

Filter by category:

```swift
let options = Options(labels: [.email, .phone, .creditCard, .bankAccount])
let contactOnly = try await redact.redaction(of: text, options: options)
```

Choose where the model comes from:

```swift
let redact = Redact()                       // managed cache, download on demand
let redact = Redact(directory: myModelDir)  // explicit model directory
let redact = Redact(bundle: myBundle)       // bundled model resources
```

Download ahead of time, for example from an onboarding screen:

```swift
let redact = Redact()
if !redact.isDownloaded() {
    try await redact.download { fraction in
        print("\(Int(fraction * 100))%")
    }
}
```

Bundle the model in an Apple app:

```swift
import Redact
import RedactCoreMLResources

let redact = Redact(bundle: RedactCoreMLResourcesBundle.bundle)
```

### Example

[SwiftUI example app](Examples/RedactSwiftExample)

## Android

### Install

Requirements: Android API 24+. The AAR contains prebuilt arm64-v8a and x86_64 native libraries.

Redact is published to Maven Central.

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

// build.gradle.kts
dependencies {
    implementation("ai.desertant:redact:0.6.3")
}
```

`ai.desertant:redact` bundles the LiteRT model by default, so normal installs work offline. To disable bundling, exclude the transitive resources artifact:

```kotlin
dependencies {
    implementation("ai.desertant:redact:0.6.3") {
        exclude(group = "ai.desertant", module = "redact-tflite-resources")
    }
}
```

With that exclusion, `Redact(context)` downloads on demand and caches the model. `Redact(context, directory = modelDir)` loads from or downloads into your chosen directory.

### Usage

```kotlin
import ai.desertant.redact.Options
import ai.desertant.redact.Redact

val redact = Redact(context)                 // bundled model by default
val result = redact.redaction("Email Anna at anna@example.com.")

println(result.redactedText)
// Email [GIVEN_NAME_1] at [EMAIL_1].

for (item in result.items) {
    println("${item.label} ${item.original} ${item.confidence} ${item.start}..${item.end}")
}

val reply = myLlm.rewrite(result.redactedText)
val restored = result.restore(reply)

redact.close()
```

Use `use` to close the native handle automatically:

```kotlin
Redact(context).use { redact ->
    val result = redact.redaction(text)
}
```

Filter by category:

```kotlin
val result = redact.redaction(
    text,
    Options(labels = setOf("EMAIL", "PHONE", "CREDIT_CARD", "BANK_ACCOUNT"))
)
```

Download before first use:

```kotlin
val redact = Redact(context)
if (!redact.isDownloaded()) {
    redact.download()
}
```

Use an explicit model directory or bundled resources:

```kotlin
val cached = Redact(context)                         // bundled model by default
val explicit = Redact(context, directory = modelDir) // explicit model directory
val offline = Redact.bundled()                       // explicit bundled constructor
```

### Example

[Android example app](Examples/RedactAndroidExample)

## JavaScript and TypeScript

### Install

Requirements: a browser (or browser-like) runtime with `@litertjs/core` (LiteRT.js). Inference runs in the browser (XNNPACK-accelerated CPU by default, optional WebGPU); in plain Node the pipeline loads but the model session is unavailable.

```bash
npm install @desert-ant-labs/redact @litertjs/core
```

`@litertjs/core` is an optional peer dependency.

### Usage

```js
import { Redact } from "@desert-ant-labs/redact";

const redact = await Redact.load();
const result = await redact.redaction("Email Anna at anna@example.com.");

console.log(result.redactedText);
// Email [GIVEN_NAME_1] at [EMAIL_1].

for (const item of result.items) {
  console.log(item.label, item.original, item.confidence, item.start, item.end);
}

const reply = await llm(result.redactedText);
const restored = result.restore(reply);
```

Filter by category:

```js
const result = await redact.redaction(text, {
  labels: ["EMAIL", "PHONE", "CREDIT_CARD", "BANK_ACCOUNT"],
});
```

Unlike the Swift and Android packages, the JavaScript package does not bundle the
model: `Redact.load()` downloads it from the Hugging Face Hub at the SDK's pinned
tag on first use and caches it (the OS cache dir in Node, the fetch cache in the
browser). To self-host or run offline, pass `directory` (Node) or `modelBaseUrl`
(browser):

```js
const redact = await Redact.load({
  directory: "/var/cache/redact",       // Node: adopt/download files here
  modelBaseUrl: "/assets/redact/",      // Browser: serve the files yourself
  onProgress: (fraction) => console.log(fraction),
});
```

Bring your own LiteRT.js module, useful for browser bundlers and React Native:

```js
import * as litert from "@litertjs/core";
import { Redact } from "@desert-ant-labs/redact";

const redact = await Redact.load({ litert, litertWasmDir: "/path/to/@litertjs/core/wasm/" });
```

### Example

[JavaScript examples](Examples/RedactWasmExample)

## Reversible redaction for LLMs

All platforms return the same redaction shape: masked text, ordered items, and a `restore` helper.

```text
Input:  Email anna@example.com and bob@example.com about IBAN DE89370400440532013000.
Masked: Email [EMAIL_1] and [EMAIL_2] about IBAN [BANK_ACCOUNT_1].
```

Placeholders are numbered per category, so two emails never collapse into one and restoration is order-independent. Tell your LLM to preserve `[LABEL_N]` tokens verbatim.

## Categories

`GIVEN_NAME`, `SURNAME`, `STREET_NAME`, `BUILDING_NUMBER`, `SECONDARY_ADDRESS`, `CITY`, `STATE`, `ZIP_CODE`, `EMAIL`, `PHONE`, `CREDIT_CARD`, `BANK_ACCOUNT`, `ROUTING_NUMBER`, `IP_ADDRESS`, `URL`, `GOVERNMENT_ID`, `PASSPORT`, `DRIVERS_LICENSE`, `TAX_ID`, `SSN`, and `IMEI`.

`IMEI` is deterministic-only. Structured recognizers report confidence `1.0`; neural detections use `minimumConfidence`, default `0.6`.

## Model and caching

The model artifacts are published at [`desert-ant-labs/redact`](https://huggingface.co/desert-ant-labs/redact) on Hugging Face. Each SDK pins the model revision to its own package version.

Default behavior:

- Swift: downloads the Core ML model on demand to a managed cache, or uses bundled `RedactCoreMLResources`.
- Android: bundles the LiteRT model by default through the normal `ai.desertant:redact` dependency. Excluding `redact-tflite-resources` switches to on-demand download into app cache.
- JavaScript: downloads the LiteRT model on `Redact.load()` to the managed cache in Node or browser cache storage when available.

Passing an explicit `directory` makes that directory the model home. Existing valid files are adopted for offline use; otherwise Redact downloads into that directory and reuses it later.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.ai/1.0). Free for most apps; a commercial license is required at scale. Full terms are at the link. Licensing: <licensing@desertant.ai>.

Third-party data and model attributions are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
