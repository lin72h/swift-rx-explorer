// Lane A substrate probe: Swift integer-overflow semantics vector (macOS-27 / Swift 6.4).
// Emits a JSON array of overflow behaviors using the reporting/wrapping API so the
// semantics are OBSERVED as values (Swift traps on `+` overflow by default; this probe
// avoids the trap and records the checked + wrapped results instead).
//
// Probe id: lane-a.integer-overflow.v1

import Foundation

func v(_ expr: String, _ checked: (partialValue: Int, overflow: Bool), _ wrapped: Int) -> [String: Any] {
    return [
        "probe_id": "lane-a.integer-overflow.v1",
        "expr": expr,
        "checked_value": checked.partialValue,
        "checked_overflow": checked.overflow,
        "wrapped_value": wrapped
    ]
}

let r1 = Int.max.addingReportingOverflow(1)
let r2 = Int.max.addingReportingOverflow(Int.max)
let r3 = (Int.min).subtractingReportingOverflow(1)
let r4 = (5).multipliedReportingOverflow(by: Int.max)
let r5 = Int.max.addingReportingOverflow(0)         // no overflow (control)

let vectors: [[String: Any]] = [
    v("Int.max +&+ 1", r1, Int.max &+ 1),
    v("Int.max +&+ Int.max", r2, Int.max &+ Int.max),
    v("Int.min -&- 1", r3, Int.min &- 1),
    v("5 *&* Int.max", r4, 5 &* Int.max),
    v("Int.max +&+ 0 (control)", r5, Int.max &+ 0)
]

let out: [String: Any] = [
    "probe_id": "lane-a.integer-overflow.v1",
    "vector_count": vectors.count,
    "vectors": vectors
]

let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
