// G17 (Compiler/Sema/NULLABLE.md 3.7), run: the writes through an alias
// the analysis refuses to ignore are real. `*p = null` through `var p = &x`
// and through a copy `var q = p` null `x`; a pointer passed to `keep`,
// which stores it in a global, lets a LATER call (`clobber()`) null `x`;
// a pointer that never escapes leaves `x` proven across a call, so the
// read after it is `__value()`. Each re-check prints what it found.
// The closure half: 3.7's own example in its non-error form (the call of a
// `|*x|` closure does null `x`, and the re-check after it sees null), the
// same through a copy of the closure, and a by-copy capture of a checked
// nullable, read narrowed inside the closure (`__value()` on its copy).
// The error forms are Sema/Nullable/alias.k.

import std::io::println

var held: (*(i32?))? = null

fn keep(p: *(i32?)) { held = p }
fn clobber() { if held? { *held = null } }
fn noop() { }

fn show(tag: string, x: i32?) {
    if x? { println(f"{tag}: {x}") } else { println(f"{tag}: null") }
}

fn main() -> i32 {
    var x: i32? = 1
    var *p = &x
    *p = null
    show("through", x)

    var y: i32? = 2
    var *p2 = &y
    var *q = p2
    *q = null
    show("copy", y)

    var z: i32? = 3
    keep(&z)
    if z? { println(f"before: {z}") }
    clobber()
    show("escaped", z)

    var w: i32? = 4
    var *pw = &w
    noop()
    println(f"kept: {w + 0}")

    var n: i32? = 5
    var clear = fn ()|*n| { *n = null }
    if n? {
        println(f"before clear: {n}")
        clear()
        show("cleared", n)
    }

    var m: i32? = 6
    var clear_m = fn ()|*m| { *m = null }
    var again = clear_m
    again()
    show("closure copy", m)

    var a: i32? = 7
    if a? {
        var f = fn () -> i32 { return a + 1 }
        println(f"by copy: {f()}")
    }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: w.__value()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      through: null
// OUT-NEXT: copy: null
// OUT-NEXT: before: 3
// OUT-NEXT: escaped: null
// OUT-NEXT: kept: 4
// OUT-NEXT: before clear: 5
// OUT-NEXT: cleared: null
// OUT-NEXT: closure copy: null
// OUT-NEXT: by copy: 8
