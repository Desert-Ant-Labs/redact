import Foundation
let jsLabels: Set<String> = ["EMAIL","URL","IP_ADDRESS","CREDIT_CARD","BANK_ACCOUNT","GOVERNMENT_ID","TAX_ID","PASSPORT","DRIVERS_LICENSE","IMEI","SSN","ROUTING_NUMBER","PHONE"]
let data = try! Data(contentsOf: URL(fileURLWithPath: "/tmp/parity_corpus.json"))
let arr = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
var okc = 0, mism = 0, shown = 0
for row in arr {
  let text = row["text"] as! String
  let py = (row["py"] as! [[Any]]).map { "\($0[0]),\($0[1]),\($0[2])" }
  let sw = Deterministic.detect(text, enabled: jsLabels).map { "\($0.start),\($0.end),\($0.label)" }
  let pset = Set(py), sset = Set(sw)
  let missing = py.filter { !sset.contains($0) }, extra = sw.filter { !pset.contains($0) }
  if missing.isEmpty && extra.isEmpty { okc += 1; continue }
  mism += 1
  if shown < 22 { shown += 1; print("TEXT:", text.prefix(72)); if !missing.isEmpty { print("  PY-only:", missing) }; if !extra.isEmpty { print("  SW-only:", extra) } }
}
print("\nPARITY: \(okc) match, \(mism) mismatch / \(arr.count)")
