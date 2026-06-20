// Lane A substrate probe: Swift String internals (macOS-27 / Swift 6.4).
// Per string, observe the grapheme/UTF8/UTF16/scalar counts and ASCII-ness, plus a
// derived small-string estimate. The inline small-string TAG is not userland-observable
// without SPI; `estimated_small_string` applies the documented arm64 threshold
// (<=15 UTF-8 bytes stored inline) to the observed byte count, and is labelled as derived.
//
// Probe id: lane-a.string-internals.v1

import Foundation

func vector(_ label: String, _ content: String) -> [String: Any] {
    let utf8 = content.utf8.count
    return [
        "probe_id": "lane-a.string-internals.v1",
        "label": label,
        "char_count": content.count,
        "utf8_count": utf8,
        "utf16_count": content.utf16.count,
        "scalar_count": content.unicodeScalars.count,
        "is_empty": content.isEmpty,
        "is_ascii": content.allSatisfy { $0.isASCII },
        "estimated_small_string": utf8 <= 15
    ]
}

let vectors: [[String: Any]] = [
    vector("empty", ""),
    vector("ascii_short", "hello"),
    vector("ascii_15_inline_threshold", "123456789012345"),     // exactly 15 bytes
    vector("ascii_16_heap_threshold", "1234567890123456"),      // 16 bytes (over inline)
    vector("eacute_single_scalar", "é"),                         // precomposed: 1 scalar, 2 UTF-8 bytes
    vector("flag_us", "🇺🇸"),                                     // regional-indicator pair: 1 grapheme, 2 scalars
    vector("woman_technologist_zwj", "👩🏽‍🏭"),                    // ZWJ grapheme cluster: 1 grapheme, several scalars
    vector("mixed_ascii_emoji", "hi 🇺🇸!")
]

let out: [String: Any] = [
    "probe_id": "lane-a.string-internals.v1",
    "vector_count": vectors.count,
    "vectors": vectors
]

let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
