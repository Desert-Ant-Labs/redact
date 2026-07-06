import Foundation
let data = try! Data(contentsOf: URL(fileURLWithPath: "/tmp/pipe_corpus.json"))
let arr = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
func spans(_ a: [[Any]]) -> [Span] { a.map { Span($0[0] as! Int, $0[1] as! Int, $0[2] as! String) } }
func chain(_ text: String, _ mlIn: [Span], _ detIn: [Span]) -> [[Any]] {
    let t = UTF16Text(text)
    var ml = Pipeline.snapSpans(t, mlIn)
    ml = Pipeline.bridgeNameGaps(t, ml)
    ml = Pipeline.extendParticleNames(t, ml)
    ml = Pipeline.attachBuildingNumbers(t, ml)
    ml = Pipeline.redactUsStreet(t, ml)
    ml = Pipeline.attachStateCodes(t, ml)
    ml = Pipeline.redactSecondaryAddress(t, ml)
    let out = Pipeline.cleanSpans(text, Pipeline.relabelByContext(text, Pipeline.resolve(detIn, ml)))
    return out.map { [$0.start, $0.end, $0.label] as [Any] }
}
func key(_ a: [[Any]]) -> String { a.map { "\($0[0]),\($0[1]),\($0[2])" }.sorted().joined(separator: " | ") }
var okc = 0, mism = 0
for c in arr {
    let text = c["text"] as! String
    let sw = chain(text, spans(c["ml"] as! [[Any]]), spans(c["det"] as! [[Any]]))
    let py = c["py"] as! [[Any]]
    if key(sw) == key(py) { okc += 1; continue }
    mism += 1
    print("TEXT:", text)
    print("  PY:", py.map { "\($0[2])" }); print("  SW:", sw.map { "\($0[2])" })
}
print("\nSWIFT PIPELINE PARITY: \(okc) match, \(mism) mismatch / \(arr.count)")
