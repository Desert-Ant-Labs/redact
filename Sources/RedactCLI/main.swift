#if !os(WASI)
import Foundation
import Redact

// Tiny smoke-test CLI: redacts argv (or a default sample) and prints the
// result. Used to exercise the shared Swift pipeline on Android/Linux.
let text = CommandLine.arguments.dropFirst().joined(separator: " ").isEmpty
    ? """
    Hi, I'm Anna Kowalska. Email me at anna.k@example.com or call +1 (555) 010-4477.
    I live at 123 Any Street, Apt 4B, Seattle, WA 98109. Card: 4539 1488 0343 6467.
    """
    : CommandLine.arguments.dropFirst().joined(separator: " ")

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let redact = Redact()
        let start = Date()
        let r = try await redact.redaction(of: text)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("input:    \(text)")
        print("redacted: \(r.redactedText)")
        for item in r.items {
            print("  \(item.placeholder)  <-  \"\(item.original)\"  (\(item.label.rawValue), \(String(format: "%.2f", item.confidence)))")
        }
        print("restored: \(r.restore(r.redactedText))")
        print("(\(ms) ms)")
    } catch {
        print("error: \(error)")
        exit(1)
    }
    semaphore.signal()
}
semaphore.wait()
#endif
