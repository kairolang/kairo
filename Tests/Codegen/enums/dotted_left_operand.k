// The shorthand `.V` as the LEFT operand of `==` / `!=` takes its enum type
// from the other operand, as it does on the right (enums-plain.mdx; pattern-
// matching.mdx).
//
// Was SC123E "'.North' names an enum variant, but nothing here gives it an
// enum type" (GitHub #83): the left operand was typed before the right one
// could give it an expected type. Operator typing now types the right
// operand first whenever the left has no type of its own
// (ExprTyper::is_context_typed); context_typed_left_operand.k covers the
// literal and list-literal halves of that rule.

enum Dir { North, South }

fn main() -> i32 {
    var d = Dir::North
    var r = 0
    if .North == d { r += 1 }
    if .South != d { r += 2 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
