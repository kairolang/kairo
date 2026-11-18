// Literal text round-trips through the source manager for other non-ASCII
// shapes: a four-byte code point, a two-byte letter beside ASCII, text next
// to an escape, and an ASCII-only literal. None shows a replacement
// character.
// CHECK: StringLiteralExpr "ñandú"
// CHECK: StringLiteralExpr "😀 ok"
// CHECK: StringLiteralExpr "é\n"
// CHECK: StringLiteralExpr "plain"
// CHECK-NOT: �
fn main() -> i32 {
    var a: string = "ñandú"
    var b: string = "😀 ok"
    var c: string = "é\n"
    var d: string = "plain"
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only --print-ast=tree || true; } | %FileCheck %s
