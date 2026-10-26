// A captured copy is made once and destroyed once (ownership.md, Default
// capture): making the closure copies the variable exactly once (no
// temporary lambda in between), and the copy is destroyed with the last
// `fn` value that holds it, after the original. Copying the closure
// copies the capture once more, and that copy is destroyed with its own
// closure. A pointer capture copies and destroys nothing. Moving the
// closure (returning it) moves the lambda, which copies nothing.

import std::io::println

var copies: i32 = 0
var drops: i32 = 0

class Tracked {
    pub var v: i32 = 0
    fn Tracked(self, v: i32) { self.v = v }
    @copy fn Tracked(self, const other: Self) { self.v = other.v; copies += 1 }
    fn op delete(self) { drops += 1 }
}

fn one_closure() {
    var t = Tracked(7)
    var f = fn () -> i32 { return t.v }
    println(f"inside: {f()} copies={copies} drops={drops}")
}

fn copied_closure() {
    var t = Tracked(8)
    var f = fn () -> i32 { return t.v }
    var g = f
    println(f"copied: {g()} copies={copies} drops={drops}")
}

fn by_pointer() {
    var t = Tracked(9)
    var f = fn ()|*t| -> i32 { return (*t).v }
    println(f"pointer: {f()} copies={copies} drops={drops}")
}

fn make() -> fn() -> i32 {
    var t = Tracked(10)
    return fn () -> i32 { return t.v }
}

fn main() -> i32 {
    one_closure()
    println(f"after one: copies={copies} drops={drops}")
    copied_closure()
    println(f"after copied: copies={copies} drops={drops}")
    by_pointer()
    println(f"after pointer: copies={copies} drops={drops}")
    var m = make()
    println(f"returned: {m()} copies={copies} drops={drops}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      inside: 7 copies=1 drops=0
// OUT-NEXT: after one: copies=1 drops=2
// OUT-NEXT: copied: 8 copies=3 drops=2
// OUT-NEXT: after copied: copies=3 drops=5
// OUT-NEXT: pointer: 9 copies=3 drops=5
// OUT-NEXT: after pointer: copies=3 drops=6
// OUT-NEXT: returned: 10 copies=4 drops=7
