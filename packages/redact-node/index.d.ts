/** The 20 model labels plus the deterministic-only `IMEI` label. */
export type RedactLabel =
  | "GIVEN_NAME" | "SURNAME" | "STREET_NAME" | "BUILDING_NUMBER" | "SECONDARY_ADDRESS"
  | "CITY" | "STATE" | "ZIP_CODE" | "EMAIL" | "PHONE" | "CREDIT_CARD" | "BANK_ACCOUNT"
  | "ROUTING_NUMBER" | "IP_ADDRESS" | "URL" | "GOVERNMENT_ID" | "PASSPORT"
  | "DRIVERS_LICENSE" | "TAX_ID" | "SSN" | "IMEI";

/** A single redacted entity, with its placeholder and original value. */
export interface RedactionItem {
  /** PII category, e.g. `"EMAIL"`. */
  label: string;
  /** The matched sensitive text. */
  original: string;
  /** Numbered placeholder, e.g. `"[EMAIL_1]"`. */
  placeholder: string;
  /** Confidence in `0..1` (deterministic recognizers report `1`). */
  confidence: number;
  /** Character offsets of `original` in the source text. */
  start: number;
  end: number;
}

/** The result of a redaction: masked text, the detections, and a restore helper. */
export interface Redaction {
  /** The input with every detection replaced by a `[LABEL_N]` placeholder. */
  redactedText: string;
  /** Every detection, in document order. */
  items: RedactionItem[];
  /** Fill original values back into text that still contains the placeholders. */
  restore(processed: string): string;
}

/** Detection options. */
export interface Options {
  /** Neural confidence threshold, `0..1`. Default `0.6`. Deterministic recognizers always apply. */
  minimumConfidence?: number;
  /** Restrict detection to these labels. Omit to detect every category. */
  labels?: Iterable<string>;
}

/** How the model is loaded. The repo and revision are pinned to the SDK. */
export interface LoadOptions {
  /**
   * An explicit directory that is this model's home (node): if it already holds
   * the files they are used offline, otherwise the model is downloaded into it.
   * Omit to use the managed cache (`~/.cache/desert-ant-models/...`).
   */
  directory?: string;
  /** Download progress in `[0, 1]`, called during {@link Redact.load}. */
  onProgress?: (fraction: number) => void;
  /** Bring-your-own ONNX Runtime module (onnxruntime-web or -node). */
  ort?: unknown;
}

/**
 * On-device multilingual PII redaction (shared Swift core compiled to
 * WebAssembly; inference via ONNX Runtime). Mirrors the iOS/Swift SDK: create
 * one with `await Redact.load(...)` and reuse it.
 *
 * ```ts
 * const redact = await Redact.load();
 * const r = await redact.redaction("Email Anna at anna@example.com.");
 * r.redactedText; r.items; r.restore(reply);
 * ```
 */
export declare class Redact {
  /** Load the model (Hugging Face Hub, cached, or a `directory`) and return a ready redactor. */
  static load(options?: LoadOptions): Promise<Redact>;
  /**
   * Detect and redact the PII in `text`. Each entity is replaced by a unique,
   * numbered placeholder (`[EMAIL_1]`, `[GIVEN_NAME_1]`, ...) so the result is
   * safe to hand to an LLM and restore afterwards via {@link Redaction.restore}.
   */
  redaction(text: string, options?: Options): Promise<Redaction>;
}
