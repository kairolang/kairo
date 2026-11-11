// P486: only an unprefixed literal chains onto the string before it
// (Compiler/Spec/Lexing.md, adjacent string literals), so `f"a{x}" f"b{y}"`
// lexed as two tokens and the second was silently a new statement (SC268W)
// or a parse error inside a call. It is now an error with the `+` that
// joins them. An unprefixed continuation of an f-string still chains.

fn main() -> i32 {
    var x = 1
    var s = f"a{x}" f"b{x}"
    var t = "a" r"b"
    var u = f"a{x}" "b"
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: prefixed_string_continuation.k:9:21: error [S001E]: a prefixed string literal does not join the literal before it; only an unprefixed "..." continues a string
// CHECK-NEXT: fix-it:"{{.*}}":{9:21-9:21}:"+ "
// CHECK: prefixed_string_continuation.k:10:17: error [S001E]: a prefixed string literal
// CHECK-NEXT: fix-it:"{{.*}}":{10:17-10:17}:"+ "
// CHECK-NOT: prefixed_string_continuation.k:11
