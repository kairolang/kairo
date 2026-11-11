// A chain of adjacent literals with different prefixes in a serialized
// AST. The payload keeps every segment (its own prefix, body and holes) and
// the `next` links between them; the node's parts are the holes of all the
// segments, in order, and survive the round trip like any other nodes.

import std::io::println

fn twice(x: i32) -> i32 {
    return x * 2
}

fn main() -> i32 {
    var n: i32 = 21
    var s = "s"
    println("plain " f"{n} " r"\raw " f"{twice(n)}")
    println(f"{s}" F"{n:x}" "\x21")
    println("a" f"{f"in{n}" r"\z" "{q}"}")
    println("x"
        rf"\{n}\"
        "y")
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
// CHECK:      plain 21 \raw 42
// CHECK-NEXT: s15!
// CHECK-NEXT: ain21\z{q}
// CHECK-NEXT: x\21\y
