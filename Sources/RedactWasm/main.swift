#if os(WASI)

import JavaScriptEventLoop
import JavaScriptKit
import Redact

// WebAssembly entry point. Installs the cooperative executor, constructs the
// shared redactor, and exposes it to the JS host as a Promise-returning
// function. The host must set up `__redactResources` / `__redactRunModel`
// (see JSEngine) before calling.
JavaScriptEventLoop.installGlobalExecutor()

let redactor = Redact()

let redactFn = JSClosure { args in
    let text = args.first?.string ?? ""
    let minimum = args.count > 1 ? (args[1].number ?? 0.6) : 0.6
    return JSPromise { resolve in
        Task {
            do {
                let r = try await redactor.redaction(of: text, options: .init(minimumConfidence: minimum))
                let items = JSObject.global.Array.function!.new()
                for (i, item) in r.items.enumerated() {
                    let o = JSObject.global.Object.function!.new()
                    o.label = .string(item.label.rawValue)
                    o.original = .string(item.original)
                    o.placeholder = .string(item.placeholder)
                    o.confidence = .number(item.confidence)
                    _ = items[i] = .object(o)
                }
                let out = JSObject.global.Object.function!.new()
                out.redactedText = .string(r.redactedText)
                out.items = .object(items)
                resolve(.success(.object(out)))
            } catch {
                resolve(.failure(.string(String(describing: error))))
            }
        }
    }.jsValue
}

JSObject.global.__redactSwift = .object(redactFn)
#endif
