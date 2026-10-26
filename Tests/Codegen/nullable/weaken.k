// G12 (Compiler/Sema/NULLABLE.md 3.4), run: the writes that end a check
// are real. Each case checks a place, lets a call change it, re-checks,
// and prints what the re-check found, which is what the analysis refused
// to assume: an `@inout` argument nulled (`bump(&x)`), a field nulled
// through its owner passed `@inout` (`clear(&s)`), a field nulled by a
// mutable-self method (`f.reset()`), a pointer written through
// (`*p = null`), and a `*const` pointer passed, which leaves the value
// alone. The re-checks narrow, so each proven read is `__value()`.

import std::io::println

class Foo {
    pub var cache: i32? = null
    pub fn Foo(self) { }
    pub fn reset(self) { self.cache = null }
}
struct S { pub var n: i32? = null }

fn bump(@inout x: i32?) { x = null }
fn clear(@inout s: S) { s.n = null }
fn look(p: *const (i32?)) -> i32 { return 0 }

fn show(tag: string, x: i32?) {
    if x? { println(f"{tag}: {x}") } else { println(f"{tag}: null") }
}

fn main() -> i32 {
    var x: i32? = 1
    if x? { println(f"before: {x}") }
    bump(&x)
    show("inout", x)

    var s = S()
    s.n = 2
    clear(&s)
    show("owner", s.n)

    var f = Foo()
    f.cache = 3
    f.reset()
    show("self", f.cache)

    var y: i32? = 4
    var *p = &y
    *p = null
    show("pointer", y)

    var z: i32? = 5
    look(&z)
    if z? { println(f"const: {z + 0}") }
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
// OUT:      before: 1
// OUT-NEXT: inout: null
// OUT-NEXT: owner: null
// OUT-NEXT: self: null
// OUT-NEXT: pointer: null
// OUT-NEXT: const: 5
