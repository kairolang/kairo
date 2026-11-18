// The owning `string` API is typed: a non-string initializer, an unknown
// member, extra arguments, a lossy size conversion and `+` with a number are
// errors at the use.

fn main() -> i32 {
    var s = "abc" + "d"
    var t: string = 5
    var n = s.nosuch()
    var c = s.c_str(1)
    var m: i32 = s.size()
    var q = s + 1
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="I003E"
// CHECK: owning_api_reject.k:7:21: error [SC028E]: cannot convert 'i32' to 'string'
// CHECK: owning_api_reject.k:8:15: error [R025E]: no member named 'nosuch' in 'string'
// CHECK: owning_api_reject.k:9:13: error [SC063E]: no matching overload for call to 'c_str'
// CHECK: owning_api_reject.k:10:18: error [SC028E]: cannot convert 'usize' to 'i32'; the conversion may lose value and needs an explicit 'as'
// CHECK: owning_api_reject.k:11:13: error [SC063E]: no matching overload for call to 'op +'
