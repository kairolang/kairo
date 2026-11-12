// In a script's top-level code, a closure copies a top-level `var`
// it uses, and inside it the name is that copy, a local of the
// closure. An inner `|*|` closure must point at the copy, as nested
// closures in a function do (fn_case below, which pins the behaviour):
// it pointed at the GLOBAL, so the inner writes changed `x` and not the
// outer closure's copy ("10 12" where a function gives "12 10").

import std::io

fn fn_case() {
    var x = 10
    var outer = fn () -> i32 {
        var inner = fn ()|*| { *x += 1 }
        inner()
        inner()
        return x
    }

    var r = outer()
    io::println(f"fn {r} {x}")
}

var x = 10
var y = 1
var outer = fn () -> i32 {
    var inner = fn ()|*| { *x += 1 }
    inner()
    inner()
    return x
}
// A named pointer capture of the outer copy, and a copy inside a copy.
var named = fn () -> i32 {
    var inner = fn ()|*y| { *y += 5 }
    inner()
    var copy = fn () -> i32 { return y }
    return copy()
}

fn_case()
var r = outer()
var s = named()
io::println(f"script {r} {x}")
io::println(f"named {s} {y}")

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      fn 12 10
// CHECK-NEXT: script 12 10
// CHECK-NEXT: named 6 1
