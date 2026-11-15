// `finally()` in a body another file declares (res.k) and this TU emits:
// an inline function and a generic one. The importing TU emits the body
// with the mode the declaring file's check decided.
import std::io::println
import res::*

struct Tag { var v: i32 }
extend Tag impl Copyable { fn tag(const self) -> i32 { return self.v } }

fn main() -> i32 {
    var a = end_early(true)
    var b = end_early(false)
    var c = end_generic(Tag { v: 3 })
    println(f"sum {a + b + c}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      ~Res 1
// CHECK-NEXT: ended early
// CHECK-NEXT: ~Res 1
// CHECK-NEXT: ~Res 2
// CHECK-NEXT: sum 4
// CHECK-EMPTY:
