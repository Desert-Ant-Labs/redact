#if !os(WASI)
@_spi(RedactBindings) import Redact
import FFIBuffer
import PlatformSupport

// C ABI over the Redact core, called by the Swift JNI entry points in
// `AndroidJNI.swift` (and usable from any other host language). Kept
// Foundation-free so the Android build ships without the ~50 MB Foundation/ICU
// stack. Instance-based, mirroring the Swift SDK (one `Redact` per handle).
//
//   redact_create(cacheRootUTF8, dirUTF8|NULL)        -> handle | NULL
//   redact_create_bundled(tok,len, labels, model,len) -> handle | NULL
//   redact_is_downloaded(handle)                      -> 0/1
//   redact_download(handle)                           -> 0/-1   (blocks)
//   redact_run(handle, textUTF8, minConf, labelsCSV|NULL) -> buffer | NULL
//   redact_destroy(handle)
//   redact_string_free(ptr)
//
// The redaction result is a self-describing binary buffer (no hand-rolled JSON):
// a big-endian uint32 payload length, then u32 textLen,text; u32 itemCount, then
// per item u32 labelLen,label; u32 origLen,orig; u32 phLen,placeholder;
// f64 confidence; u32 start; u32 end. Strings are UTF-8; offsets are UTF-16.
//
// The async core API is bridged synchronously here (callers are host-language
// worker threads).

/// A retained box so the opaque handle keeps its `Redact` alive.
private final class Handle { let redact: Redact; init(_ redact: Redact) { self.redact = redact } }

private func redact(_ handle: UnsafeMutableRawPointer?) -> Redact? {
    guard let handle else { return nil }
    return Unmanaged<Handle>.fromOpaque(handle).takeUnretainedValue().redact
}

/// Create a redactor. `cacheRoot` is the app cache dir (the base for the managed
/// nested layout). `directory` is an explicit model directory (adopt files
/// there, else download; direct layout), or NULL for the managed nested layout
/// under `cacheRoot`. Loading is lazy, like the Swift SDK.
@_cdecl("redact_create")
public func redact_create(
    _ cacheRoot: UnsafePointer<CChar>?, _ directory: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    let redact = Redact(
        directory: directory.map { String(cString: $0) },
        cacheRoot: cacheRoot.map { String(cString: $0) })
    return Unmanaged.passRetained(Handle(redact)).toOpaque()
}

/// Create a redactor from in-memory bundled model bytes (the Android AAR path).
@_cdecl("redact_create_bundled")
public func redact_create_bundled(
    _ tokenizer: UnsafePointer<UInt8>?, _ tokenizerLen: Int32,
    _ labelsJSON: UnsafePointer<CChar>?,
    _ model: UnsafePointer<UInt8>?, _ modelLen: Int32
) -> UnsafeMutableRawPointer? {
    guard let tokenizer, tokenizerLen > 0, let labelsJSON, let model, modelLen > 0 else { return nil }
    guard let assets = try? ModelAssets(
        tokenizer: Array(UnsafeBufferPointer(start: tokenizer, count: Int(tokenizerLen))),
        labelsJSON: String(cString: labelsJSON),
        modelBytes: Array(UnsafeBufferPointer(start: model, count: Int(modelLen)))) else { return nil }
    return Unmanaged.passRetained(Handle(Redact(assets: assets))).toOpaque()
}

@_cdecl("redact_destroy")
public func redact_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<Handle>.fromOpaque(handle).release()
}

@_cdecl("redact_is_downloaded")
public func redact_is_downloaded(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    (redact(handle)?.isDownloaded() ?? false) ? 1 : 0
}

/// Download/verify the model ahead of time (blocks). 0 on success, -1 on failure.
@_cdecl("redact_download")
public func redact_download(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let redact = redact(handle) else { return -1 }
    let ok: Bool = blockingValue {
        do { try await redact.download(); return true } catch { return false }
    }
    return ok ? 0 : -1
}

@_cdecl("redact_run")
public func redact_run(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?,
    _ minimumConfidence: Double, _ labelsCSV: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let text, let redact = redact(handle) else { return nil }
    let input = String(cString: text)
    let options = makeOptions(minimumConfidence, labelsCSV)
    let payload: [UInt8]? = blockingValue {
        guard let r = try? await redact.redaction(of: input, options: options) else { return nil }
        return encodeRedaction(r, in: input)
    }
    return payload.flatMap(ffiEmit)
}

@_cdecl("redact_string_free")
public func redact_string_free(_ ptr: UnsafeMutablePointer<CChar>?) {
    ffiFree(ptr)
}

// MARK: helpers

private func makeOptions(_ minimumConfidence: Double, _ labelsCSV: UnsafePointer<CChar>?) -> Options {
    var labels: Set<Label>?
    if let names = parseCSV(labelsCSV) {
        labels = Set(names.compactMap(Label.init(rawValue:)))
    }
    return Options(minimumConfidence: minimumConfidence, labels: labels)
}

private func parseCSV(_ csv: UnsafePointer<CChar>?) -> Set<String>? {
    guard let csv else { return nil }
    let s = String(cString: csv)
    guard !s.isEmpty else { return [] }
    return Set(s.split(separator: ",").map(String.init))
}

// Redaction payload built with core's FFIWriter (decoded by the Kotlin FfiReader;
// no JSON hand-rolled either side). The wire primitives are in desert-ant-core.
private func encodeRedaction(_ r: Redaction, in input: String) -> [UInt8] {
    var w = FFIWriter()
    w.string(r.redactedText)
    w.u32(r.items.count)
    for item in r.items {
        w.string(item.label.rawValue)
        w.string(item.original)
        w.string(item.placeholder)
        w.f64(item.confidence)
        w.u32(item.range.lowerBound.utf16Offset(in: input))
        w.u32(item.range.upperBound.utf16Offset(in: input))
    }
    return w.bytes
}
#endif
