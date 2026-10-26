// A pointer converts implicitly to a nullable pointer (pointers.md,
// Pointers and Nullable Types), including after a derived-to-base step,
// and `??` picks the fallback only when it is null.
//
// Spelled `(*T)?`, which `*T?` also means since NULLABLE.md G1.
//
// Runs since G8 (NULLABLE.md 2.4, CoalesceLowering): `p ?? q` on a
// `(*A)?` is `if p? => p else q`, then the virtual call dispatches on what
// it chose.

class A { virtual fn k(self) -> i32 { return 1 } }
class D derives A { override fn k(self) -> i32 { return 5 } }

fn k_or(p: (*A)?, q: *A) -> i32 { return (p ?? q)->k() }

fn main() -> i32 {
    var r = 0
    var n = 42
    var pi: (*i32)? = &n
    var other = 0
    if *(pi ?? &other) == 42 { r += 1 }
    var a = A()
    var d = D()
    if k_or(&a, &d) == 1 { r += 2 }
    if k_or(&d, &a) == 5 { r += 4 }             // *D -> *A -> (*A)?, then dispatch
    var v: i32? = 9
    if (v ?? 0) == 9 { r += 8 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
