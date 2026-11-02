// generics/dependent_explicit_args.k -- exit 0 (P127)
// Explicit generic arguments that name the enclosing generic's parameters
// are kept in the emitted C++. A call in a generic body has no instance (it
// is dependent), so the arguments written on it are all there is to spell;
// dropped, `size_of_a<A>()` became `size_of_a()` and clang could not infer
// A. Every call form: a free call, a static call through a bounded and a
// `: type` parameter, a method on a dependent object (both again), a
// static of a generic class named through the parameter, and calls inside
// a `requires` clause (emitted as a per-instance static_assert).

fn <A> size_of_a() -> usize { return sizeof A }
eval fn <A> small() -> bool { return sizeof A <= 8 }

interface HasF {
    static fn <B> f() -> usize
    fn <B> m(const self) -> usize
}

class S impl HasF {
    static fn <B> f() -> usize { return sizeof B }
    fn <B> m(const self) -> usize { return sizeof B }
}

class <X> G {
    static fn <B> f() -> usize { return sizeof B + sizeof X }
}

fn <A> twice() -> usize { return size_of_a<A>() * 2 }
fn <A impl HasF, B> stat_b() -> usize { return A::f<B>() }
fn <A: type, B> stat_d() -> usize { return A::f<B>() }
fn <T impl HasF, B> meth_b(x: T) -> usize { return x.m<B>() }
fn <T: type, B> meth_d(x: T) -> usize { return x.m<B>() }
fn <A, B> gstat() -> usize { return G<A>::f<B>() }
fn <A> req() -> usize requires small<A>() { return 1 }
fn <A> req_builtin() -> usize requires __builtin_is_trivially_copyable<A>() { return 2 }

fn main() -> i32 {
    var s = S()
    if twice<i64>() != 16 { return 1 }
    if stat_b<S, i16>() != 2 { return 2 }
    if stat_d<S, i32>() != 4 { return 3 }
    if meth_b<S, i64>(s) != 8 { return 4 }
    if meth_d<S, i64>(s) != 8 { return 5 }
    if gstat<i32, i8>() != 5 { return 6 }
    if req<i32>() != 1 { return 7 }
    if req_builtin<i32>() != 2 { return 8 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s -fduck-generics --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: ::size_of_a<A>()
// IR-DAG: HasF_witness<A>::template f<B>()
// IR-DAG: return( ::__kairo_nopanic(), A::template f<B>());
// IR-DAG: HasF_witness<T>::template m<B>((& x))
// IR-DAG: return( ::__kairo_nopanic(), x.template m<B>());
// IR-DAG: G<A>::template f<B>()
// IR-DAG: static_assert({{ ?}}::{{.*}}::small<A>(),
// IR-DAG: static_assert({{ ?}}::{{.*}}::__builtin_is_trivially_copyable<A>(),

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe
