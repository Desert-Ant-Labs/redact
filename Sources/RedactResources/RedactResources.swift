import Foundation

/// Bundle accessor for the packaged model resources (Core ML model, ONNX
/// model, tokenizer, labels). Kept in its own target so the WebAssembly build,
/// which receives resources from the JS host instead, does not link
/// Foundation's Bundle (and with it ICU).
public enum RedactResourcesBundle {
    public static var bundle: Bundle { Bundle.module }
}
