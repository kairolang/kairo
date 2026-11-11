// String and char literals in a serialized AST. A literal token's payload is
// a slot of the file's immediate table: for a string, its body range, its
// prefix, the next part of a multi-part literal, and for an f-string the
// token run of every hole with its format spec. The reader re-creates the
// slot; the parsed holes (StringLiteralExpr::parts) are nodes like any
// other. An f-string nested in a hole is a payload inside a payload.

import std::io::println

fn twice(x: i32) -> i32 {
    return x * 2
}

fn main() -> i32 {
    var name = "kairo"
    var n: i32 = 21
    println(f"hello {name}")
    println(f"{n} doubled is {twice(n)}, hex {n:x}")
    println(f"nested {f"inner {n + 1}"} done")
    println("two " "parts")
    println(r"raw \n stays")
    var c = 'x'
    var nl = '\n'
    if c == 'x' && nl == '\n' {
        println("chars ok")
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --verify-ast-roundtrip
// RUN: %kairo %s --syntax-only --print-ast=tree > %t.parsed
// RUN: %kairo %s --syntax-only --print-ast=tree --ast-roundtrip > %t.reloaded
// RUN: diff %t.parsed %t.reloaded
// RUN: %kairo %s --type-check-only --print-sema > %t.sema.parsed
// RUN: %kairo %s --type-check-only --print-sema --ast-roundtrip > %t.sema.reloaded
// RUN: diff %t.sema.parsed %t.sema.reloaded

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s --ast-roundtrip -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK:      hello kairo
// CHECK-NEXT: 21 doubled is 42, hex 15
// CHECK-NEXT: nested inner 22 done
// CHECK-NEXT: two parts
// CHECK-NEXT: raw \n stays
// CHECK-NEXT: chars ok
