// In a script a top-level `var` is a global (modules.mdx), and a
// global is named in place rather than captured, so the default capture
// read the live value: `x = 999` before the call made `add_x(5)` 1004.
// closures.mdx: a closure captures by copy by default, and the copy is
// taken where the closure is made. In the top-level code the script's own
// `var`s are captured as the locals they look like: C++ gets an
// init-capture from the global (`x = ::ns::x`). A function of the script
// names the global as a global, captured or not; a `static` is a global
// everywhere.

import std::io

fn seven() -> i32 { return 7 }

var x = 10
var y = seven() // deferred: assigned where the line runs, not at startup.
static s = 1

var add_x = fn (n: i32) -> i32 { return n + x }
var named = fn (n: i32)|x| -> i32 { return n + x }
var both = fn () -> i32 { return x + y }
var nested = fn () -> i32 {
    var g = fn () -> i32 { return x }
    return g()
}
var stat = fn () -> i32 { return s }

// The copy is the closure's own: writing it changes neither the global
// nor the next call's start.
var own = fn () -> i32 {
    x += 1
    return x
}

fn from_fn() -> i32 {
    var f = fn () -> i32 { return x }
    return f()
}

x = 999
y = 0
s = 50
io::println(f"copy {add_x(5)} {named(5)} {both()} {nested()}")
io::println(f"own {own()} {own()} {x}")
io::println(f"static {stat()}")
io::println(f"fn {from_fn()}")

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      copy 15 15 17 10
// CHECK-NEXT: own 11 12 999
// CHECK-NEXT: static 50
// CHECK-NEXT: fn 999
