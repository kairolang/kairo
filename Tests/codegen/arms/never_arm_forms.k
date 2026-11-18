// An if-expression arm of type `!` in every position and at every join type::
// the then arm, an else-if arm, a record join type with no copy (a
// `@move` class), a closure body and a namespace-scope initializer. The arm
// is spelled as a lambda returning the join type that never returns, so
// C++'s `?:` gets two values of that type and nothing is copied; at
// namespace scope the lambda captures nothing. The arms that run return;
// the last run takes the `!` arm and crashes.

class Mv {
    pub var n: i32
    pub fn Mv(self, n: i32) { self.n = n; }
    @move fn Mv(self, other: Self) { self.n = other.n; }
}

fn die() -> ! { crash!() }

fn first(c: bool) -> i32 = if !c => die() else => 1
fn middle(k: i32) -> i32 = if k == 0 => 10 else if k == 1 => die() else => 20
fn moved(c: bool) -> i32 {
    var m = if c => Mv(4) else => die()
    return m.n
}

fn one() -> i32 { return 100 }
var g: i32 = if one() > 0 => one() else => die()

fn main(argc: i32) -> i32 {
    var f = fn (c: bool) -> i32 { return if c => 1000 else => die() }
    var r = first(true) + middle(2) + moved(true) + g + f(true)
    if argc > 1 {
        return middle(1)
    }

    return r - 1125
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %t.exe die 2> %t.err; test $? -eq 134
