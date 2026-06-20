// Lane A substrate probe: Swift runtime metadata + witness-table presence (macOS-27 / Swift 6.4).
// Per type, observe: Mirror displayStyle, is-class, conformance to a protocol P (witness-table
// presence for P), the result of dispatching P's requirement THROUGH a `[P]` existential
// (which exercises the witness table), plus size/alignment.
//
// Probe id: lane-a.runtime-metadata.v1

import Foundation

protocol Describable { var desc: String { get } }

struct S1: Describable { var x: Int; var desc: String { "S1(\(x))" } }
struct S2: Describable { var s: String; var desc: String { "S2" } }
final class C1: Describable { var y: Int; init(_ y: Int) { self.y = y }; var desc: String { "C1(\(y))" } }
enum E1: Describable { case a, b; var desc: String { "E1" } }
struct Plain { var z: Int }   // does NOT conform to Describable (no witness table for P)

func vector<T>(_ value: T, _ name: String) -> [String: Any] {
    let m = Mirror(reflecting: value)
    let style = m.displayStyle.map { String(describing: $0) } ?? "unknown"
    let conforms = (value is Describable)
    // Witness-table dispatch: if it conforms, route the requirement through a `[Describable]`
    // existential so the call goes via the witness table; record the returned result.
    var witness = "(no witness)"
    if conforms {
        let box: [Describable] = [value as! Describable]
        witness = box[0].desc
    }
    return [
        "probe_id": "lane-a.runtime-metadata.v1",
        "type": name,
        "mirror_display_style": style,
        "is_class": m.displayStyle == .class,
        "conforms_to_describable": conforms,
        "witness_desc_result": witness,
        "size": MemoryLayout<T>.size,
        "alignment": MemoryLayout<T>.alignment
    ]
}

let vectors: [[String: Any]] = [
    vector(S1(x: 42), "S1"),
    vector(S2(s: "hi"), "S2"),
    vector(C1(7), "C1"),
    vector(E1.a, "E1"),
    vector(Plain(z: 9), "Plain")
]

let out: [String: Any] = [
    "probe_id": "lane-a.runtime-metadata.v1",
    "vector_count": vectors.count,
    "vectors": vectors
]

let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
