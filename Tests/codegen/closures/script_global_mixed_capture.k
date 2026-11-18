// The other capture forms on a script's top-level vars: a mixed list
// `|step, *count|` (step read as a value, count through its pointer), a
// named `|*count|` beside `|*|` in one closure chain, and a by-value
// closure that only reads. By-value capture of a top-level var is not pinned
// to a copy here: it still reads the global where the body names it,
// so step is never written after the closures are made.

import std::io

var count = 0
var step = 3

var mixed = fn ()|step, *count| { *count += step }
mixed()
mixed()
io::println(f"mixed {count}")

var named = fn ()|*count| -> i32 {
    var all = fn ()|*| -> i32 { return *count + 1 }
    return all()
}
io::println(f"named {named()}")

var reads = fn () -> i32 { return count + step }
io::println(f"reads {reads()}")

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      mixed 6
// CHECK-NEXT: named 7
// CHECK-NEXT: reads 9
