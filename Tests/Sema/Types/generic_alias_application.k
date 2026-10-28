// A generic alias APPLICATION is its aliased body with the arguments
// substituted in (types.md, Type Aliases; RESOLUTION.md §2.6): `B<i32>` of
// `type <T> B = Box<T>` IS `Box<i32>`, the same canonical and the same
// instance as if written out, so members, overloads and conversions see
// through it. An application over a generic parameter (`B<U>`) is that
// body over U, dependent like any other use of U, and deduces as `Box<U>`
// would. MONO.md G4: before, every application stayed
// instantiation-dependent with no canonical, so `b.v` had no answer and
// `gen(b)` could not deduce U.

class <T> Box {
    pub var v: T
    fn Box(self, v: T) { self.v = v }
}

class <K, V> Pair {
    pub var k: K
    pub var v: V
    fn Pair(self, k: K, v: V) { self.k = k; self.v = v }
}

type <T> Mat = [[T]]
type <T> B = Box<T>
type <T> P = *T
type <T> PB = P<B<T>>              // applications inside an alias body
type <T, U = T> Same = Pair<T, U>  // a defaulted alias parameter

fn same(m: Mat<i32>) -> [[i32]] { return m }   // one type: no conversion
fn unbox(b: B<i32>) -> i32 { return b.v }
fn deref(p: P<i32>) -> i32 { return *p }
fn through(p: PB<i32>) -> i32 { return p->v }
fn both(s: Same<i32>) -> i32 { return s.k + s.v }
fn <U> gen(b: B<U>) -> U { return b.v }

fn main() -> i32 {
    var b: B<i32> = Box<i32>(4)
    var w: Box<i32> = b                       // one type: no conversion
    var pb: PB<i32> = &b
    var s: Same<i32> = Pair<i32, i32>(1, 2)
    var x = 5
    return unbox(w) + deref(&x) + gen(b) + through(pb) + both(s)   // 4+5+4+4+3 = 20
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA:      <tu>::same
// SEMA:        NamedIdentExpr {{.*}} : {{\[\[}}i32]]
// SEMA:      <tu>::unbox
// SEMA:        ChainExpr {{.*}} : i32
// SEMA:        NamedIdentExpr {{.*}} : Box<i32>
// SEMA:      <tu>::deref
// SEMA:        NamedIdentExpr {{.*}} : *i32
// SEMA:      <tu>::through
// SEMA:        NamedIdentExpr {{.*}} : *Box<i32>
// SEMA:      <tu>::both
// SEMA:        NamedIdentExpr {{.*}} : Pair<i32, i32>
// SEMA:      <tu>::gen
// SEMA:        ChainExpr {{.*}} : U
// SEMA:        NamedIdentExpr {{.*}} : Box<U>
// SEMA:      <tu>::main
// SEMA:        CallExpr {{.*}} : i32
// SEMA-NOT:  <unknown>
// SEMA:      -- inferred decls --

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 20
