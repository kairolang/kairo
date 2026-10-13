// `.Variant` against a plain enum is the variant's value: the expected type
// names the enum -- a declared variable, a return type, the parameter a call
// resolves to -- and the C++ is the qualified enumerator, as for
// `Dir::South`. It needs no layout record, so it is not gated.

enum Dir derives u8 { North = 1, South = 2, East = 4 }
enum Color { Red, Green }

fn pick(n: i32) -> Dir {
    if n > 0 { return .East; }
    return .South;
}

fn weight(d: Dir) -> i32 { return (d as u8) as i32; }

// Two overloads: `.Green` fits only the one whose enum has a `Green`.
fn score(d: Dir) -> i32 { return 100; }
fn score(c: Color) -> i32 { return ((c as u32) as i32) * 8; }

fn main() -> i32 {
    var d: Dir = .North;
// LOWERED: NamedIdentExpr @ [[@LINE-1]]:18 : Dir{{$}}
    return weight(d) + weight(pick(1)) + weight(pick(0)) + weight(.East) + score(.Green);   // 1 + 4 + 2 + 4 + 8
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --type-check-only --print-lowered 2>/dev/null || true; } | %FileCheck %s --check-prefix=LOWERED

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 19
