#if os(Android)
import Android
import HostBridge

// JNI entry points for ai.desertant.redact.RedactNative, written directly in
// Swift (no C shim). The reusable harness (byte marshalling, thread attach, and
// installing the CHostBridge regex/JSON callbacks against the host class) lives
// in desert-ant-core's HostBridge module; this file forwards to the C ABI in
// CABI.swift. The API mirrors the Swift SDK: an instance (opaque handle) per
// Redact, with lazy loading, isDownloaded, download, and redaction.
//
// The model is either bundled (createBundled, bytes from the optional
// redact-onnx-resources) or loaded on demand (create, download/local dir).
// Text crosses as UTF-8 byte arrays; the redaction result comes back as the
// FFIBuffer length-prefixed typed buffer. Handles cross as jlong.

private func handle(_ ptr: UnsafeMutableRawPointer?) -> jlong { jlong(Int(bitPattern: ptr)) }
private func pointer(_ handle: jlong) -> UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: Int(handle)) }

/// Create a redactor. `cacheRoot` is the app cache dir (base for the managed
/// nested layout); `directory` is an explicit model dir (direct) or NULL/empty
/// for the managed layout under `cacheRoot`.
@_cdecl("Java_ai_desertant_redact_RedactNative_create")
public func RedactNative_create(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                      _ cacheRoot: jbyteArray?, _ directory: jbyteArray?) -> jlong {
    installHostBridge(env, cls)  // wires regex/JSON + http callbacks to RedactNative's statics
    let root = hostCopyBytes(env, cacheRoot).flatMap { $0.isEmpty ? nil : Array($0) }
    let dir = hostCopyBytes(env, directory).flatMap { $0.isEmpty ? nil : Array($0) }
    return withHostCText(root) { rootPtr in
        withHostCText(dir) { dirPtr in handle(redact_create(rootPtr, dirPtr)) }
    }
}

/// Create a redactor from bundled model bytes (the redact-onnx-resources path).
@_cdecl("Java_ai_desertant_redact_RedactNative_createBundled")
public func RedactNative_createBundled(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                             _ tokenizer: jbyteArray?, _ labelsJson: jbyteArray?, _ model: jbyteArray?) -> jlong {
    installHostBridge(env, cls)
    guard let tok = hostCopyBytes(env, tokenizer), let labels = hostCopyBytes(env, labelsJson),
          let mdl = hostCopyBytes(env, model) else { return 0 }
    return withHostCText(labels) { labelsC in
        tok.withUnsafeBufferPointer { t in
            mdl.withUnsafeBufferPointer { m in
                handle(redact_create_bundled(t.baseAddress, Int32(t.count), labelsC, m.baseAddress, Int32(m.count)))
            }
        }
    }
}

@_cdecl("Java_ai_desertant_redact_RedactNative_destroy")
public func RedactNative_destroy(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong) {
    redact_destroy(pointer(handle))
}

@_cdecl("Java_ai_desertant_redact_RedactNative_isDownloaded")
public func RedactNative_isDownloaded(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong) -> jint {
    installHostBridge(env, cls)
    return jint(redact_is_downloaded(pointer(handle)))
}

/// Download/verify the model ahead of time. Blocking; call off the main thread.
@_cdecl("Java_ai_desertant_redact_RedactNative_download")
public func RedactNative_download(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?, _ handle: jlong) -> jint {
    installHostBridge(env, cls)
    return jint(redact_download(pointer(handle)))
}

@_cdecl("Java_ai_desertant_redact_RedactNative_run")
public func RedactNative_run(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass?,
                                   _ handle: jlong, _ textUtf8: jbyteArray?,
                                   _ minimumConfidence: jdouble, _ labelsCsv: jbyteArray?) -> jbyteArray? {
    installHostBridge(env, cls)
    guard let text = hostCopyBytes(env, textUtf8) else { return nil }
    let buf = withHostCText(text) { t in
        withHostCText(hostCopyBytes(env, labelsCsv)) { l in redact_run(pointer(handle), t, minimumConfidence, l) }
    }
    return hostTakeBuffer(env, buf)
}
#endif
