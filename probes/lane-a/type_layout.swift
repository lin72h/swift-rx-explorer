// Lane A substrate probe: Swift type-layout ABI vector (macOS-27 / Swift 6.4).
// Emits a JSON array of MemoryLayout<T> {size, stride, alignment} for a
// representative set of Swift types. These are stable ABI parity vectors:
// a change in size/stride/alignment is an ABI regression.
//
// Probe id: lane-a.type-layout.v1

import Foundation

struct Empty {}
struct SingleInt { var x: Int }
struct PairIntDouble { var a: Int; var b: Double }
struct PaddedTuple { var a: Int8; var b: Int64 }
enum VoidlessEnum { case a, b, c }
enum IndirectOptional { case none, some(Int) }
final class FinalBox { var x: Int = 0 }
struct GenericBox<T> { var value: T }

func vector<T>(_ type: T.Type, _ name: String, _ kind: String) -> [String: Any] {
    return [
        "probe_id": "lane-a.type-layout.v1",
        "type": name,
        "kind": kind,
        "size": MemoryLayout<T>.size,
        "stride": MemoryLayout<T>.stride,
        "alignment": MemoryLayout<T>.alignment
    ]
}

let vectors: [[String: Any]] = [
    vector(Int.self, "Int", "builtin"),
    vector(Int64.self, "Int64", "builtin"),
    vector(Int32.self, "Int32", "builtin"),
    vector(Int8.self, "Int8", "builtin"),
    vector(UInt.self, "UInt", "builtin"),
    vector(Double.self, "Double", "builtin"),
    vector(Float.self, "Float", "builtin"),
    vector(Bool.self, "Bool", "builtin"),
    vector(Character.self, "Character", "builtin"),
    vector(String.self, "String", "builtin"),
    vector(Empty.self, "Empty", "struct"),
    vector(SingleInt.self, "SingleInt", "struct"),
    vector(PairIntDouble.self, "PairIntDouble", "struct"),
    vector(PaddedTuple.self, "PaddedTuple", "struct"),
    vector(VoidlessEnum.self, "VoidlessEnum", "enum"),
    vector(Optional<Int>.self, "Optional<Int>", "optional"),
    vector(GenericBox<Int>.self, "GenericBox<Int>", "generic-struct"),
    vector(Array<Int>.self, "Array<Int>", "array"),
    vector(FinalBox.self, "FinalBox", "class"),
    vector(UnsafeRawPointer.self, "UnsafeRawPointer", "pointer")
]

let out: [String: Any] = [
    "probe_id": "lane-a.type-layout.v1",
    "vector_count": vectors.count,
    "vectors": vectors
]

let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
