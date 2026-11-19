// A byte string survives the serialized AST: the reloaded literal is still
// a byte string (its kind and each segment's prefix are written), so the
// tree prints the same and types the same.

fn total(xs: [const u8;]) -> usize {
    return xs.size()
}

fn main() -> i32 {
    var a = b"ab\x00\xff"
    var c = b"ab" b"cd"
    return (total(a) + total(c)) as i32 - 8
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --syntax-only --print-ast=tree > %t.parsed
// RUN: %kairo %s --syntax-only --print-ast=tree --ast-roundtrip > %t.reloaded
// RUN: diff %t.parsed %t.reloaded
// RUN: %FileCheck %s --check-prefix=TREE < %t.reloaded
// TREE: StringLiteralExpr "ab\x00\xff" bytes
// TREE: StringLiteralExpr "ab" bytes
// RUN: %kairo %s --type-check-only --verify-ast-roundtrip --ast-roundtrip 2>&1 | %FileCheck %s --check-prefix=CLEAN --allow-empty
// CLEAN-NOT: {{error|I002F}}
