import Foundation

/// Bundle accessor for ONNX Runtime resources only. Used by Linux, Android,
/// and Windows builds; Apple platforms use `RedactCoreMLResources` instead.
public enum RedactONNXResourcesBundle {
    public static var bundle: Bundle { Bundle.module }
}
