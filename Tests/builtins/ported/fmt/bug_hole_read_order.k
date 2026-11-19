// XFAIL: *
// Defect (compiler): an f-string hole that reads a mutable global is read after a later hole's call has run, so
// `f"{G}{bump()}{G}"` shows the value after every call instead of the value at that hole. Compiler/Spec/FormatStrings.md
// (The rewrite) binds holes "in source order" and language/primitives.mdx (Strings) says the holes of an f-string
// are "evaluated left to right"; the lowering treats the read of a global as pure and leaves it in place while the
// impure holes are bound to locals first.
// Smallest reproducer: the `reads around calls` case.

import std::io::*

var CODE: i32 = 0
var COUNTER: i32 = 0

fn ck(const got: string, const want: string, id: i32, const name: string) {
    if !(got == want) {
        println(f"FAIL {name}: got [{got}] want [{want}]")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn next() -> i32 {
    COUNTER += 1
    return COUNTER
}

fn main() -> i32 {
    COUNTER = 0
    ck(f"{COUNTER}{next()}{COUNTER}{next()}{COUNTER}", "01122", 1, "reads around calls")
    COUNTER = 0
    ck(f"{COUNTER:>3}|{next()}|{COUNTER:>3}", "  0|1|  1", 2, "reads with specs around a call")
    if CODE == 0 {
        println("ok")
    }

    return CODE
}

// --- lit wiring ---
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: ok
