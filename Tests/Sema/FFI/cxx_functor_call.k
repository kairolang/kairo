// `f(args)` on an imported C++ function object (a class with operator()):
// resolved over its operator() set as `f.operator()(args)` would be, with
// the object as the receiver. A const object picks the const overload, the
// arguments pick among overloads, and the object is never moved by the
// call (Ticker is move-only and is called twice). Through a pointer it is
// `(*p)(x)`, on a member `self.fn_(x)` / `pw->fn_(x)`. It is not
// SC062E "'Counter' is not callable".

ffi "c++" import "cxx_functor_call.h"

class Wrap {
    pub var fn_: Counter
    fn go(self, x: i32) -> i32 { return self.fn_(x) }
}

fn main() -> i32 {
    var c = Counter()
    c(5)                       // mutable operator(): n = 5
    var a = c(2)               // n = 7, a = 7
    const k = Counter()
    var b = k(3)               // const operator(): 1003
    var s = c("x")             // the const char* overload: -1
    var m = c(6i64, 7i64)      // the two-argument overload: 42
    var t = Ticker()
    t()                        // 8
    var u = t()                // 9: t was not moved by the first call
    var unsafe *p = unsafe &c
    var via = unsafe (*p)(1)   // through a pointer: n = 8
    var w = Wrap()
    var g = w.go(4)            // member functor: 4
    var *pw = &w
    var h = pw->fn_(1)         // member through a pointer: 5
    // 7 + 1003 - 1 + 42 + 9 + 8 + 4 + 5 = 1077
    var total = a + b + s + (m as i32) + u + via + g + h
    return if (total == 1077) => 0 else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
