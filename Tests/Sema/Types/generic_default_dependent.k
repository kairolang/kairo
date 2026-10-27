// A generic parameter's default that names an EARLIER parameter
// (`class <K, V = K> Pair`) is that parameter's argument: `Pair<i32>` is
// `Pair<i32, i32>`, the same instance as if written out (generics.md,
// Default Generic Arguments). Inside a generic body `Pair<U>` is
// `Pair<U, U>`. MONO.md G4: the default was kept as written, so
// `Pair<i32>` was `Pair<i32, K>`, a dependent type with no instance
// behind it, and the emitted C++ named a `K` nothing declares.

class <K, V = K> Pair {
    pub var k: K
    pub var v: V
    fn Pair(self, k: K, v: V) { self.k = k; self.v = v }
}

fn both(s: Pair<i32>) -> i32 { return s.k + s.v }
fn <U> second(s: Pair<U>) -> U { return s.v }

fn main() -> i32 {
    var s: Pair<i32> = Pair<i32, i32>(1, 2)     // one type: no conversion
    return both(s) + second(s)                  // 3 + 2 = 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA:      <tu>::both
// SEMA:        NamedIdentExpr {{.*}} : Pair<i32, i32>
// SEMA:      <tu>::second
// SEMA:        ChainExpr {{.*}} : U
// SEMA:        NamedIdentExpr {{.*}} : Pair<U, U>

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
