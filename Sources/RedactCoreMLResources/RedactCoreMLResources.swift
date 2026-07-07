import Foundation

/// Bundle accessor for Apple/Core ML resources only. This target deliberately
/// excludes `redact.onnx` so iOS/macOS apps do not ship an unused ONNX model.
public enum RedactCoreMLResourcesBundle {
    public static var bundle: Bundle { Bundle.module }
}
