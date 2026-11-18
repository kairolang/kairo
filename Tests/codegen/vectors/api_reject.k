// The builtin `[T]` vector is typed by its element: a wrong element type, an
// unknown member and a lossy size conversion are errors at the use.

fn main() -> i32 {
    var v: [i32] = [10, 20, 30]
    v.push("x")
    v[0] = "s"
    var n = v.nosuch()
    var w: [i32] = [1, "a"]
    var i: i32 = v.size()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="I003E"
// CHECK: api_reject.k:6:5: error [SC063E]: no matching overload for call to 'push'
// CHECK: api_reject.k:7:12: error [SC028E]: cannot convert 'string' to 'i32'
// CHECK: api_reject.k:8:15: error [R025E]: no member named 'nosuch' in 'Vector'
// CHECK: api_reject.k:9:24: error [SC028E]: cannot convert 'string' to 'i32'
// CHECK: api_reject.k:10:18: error [SC028E]: cannot convert 'usize' to 'i32'; the conversion may lose value and needs an explicit 'as'
