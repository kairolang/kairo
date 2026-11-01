// generics/static_member_value.k -- exit 0 (P222)
// A static member used as a VALUE inside a generic is spelled through what
// names it. A static requirement through a bounded parameter (`A::make`) is
// the witness's member, as a `::` call is -- the requirement itself is no
// C++ function, and was emitted as the interface's `I::make`. A member of
// a generic class (`H<A>::get`, `Self::twice`) keeps the instance, and a
// generic function (`tramp<A>`) its arguments: both were spelled as the
// bare template. The concrete forms are the same rule with no dependence.

interface I {
    static fn make(n: usize) -> usize
    static fn <B> sized(n: usize) -> usize
}

class M impl I {
    static fn make(n: usize) -> usize { return n * 2 }
    static fn <B> sized(n: usize) -> usize { return n + sizeof B }
}

class <X> H {
    static fn get(n: usize) -> usize { return n + sizeof X }
}

fn <A impl I> tramp(n: usize) -> usize { return A::make(n) }

class <A impl I> G {
    static fn twice(n: usize) -> usize { return n * 2 }
    static fn run() -> usize {
        var f: fn(usize) -> usize = A::make
        var z: fn(usize) -> usize = A::sized<i64>
        var g: fn(usize) -> usize = tramp<A>
        var h: fn(usize) -> usize = H<A>::get
        var s: fn(usize) -> usize = Self::twice
        return f(3) + z(3) + g(3) + h(3) + s(3)
    }
}

fn concrete() -> usize {
    var g: fn(usize) -> usize = tramp<M>
    var h: fn(usize) -> usize = H<M>::get
    return g(1) + h(1)
}

fn main() -> i32 {
    // 6 + 11 + 6 + 4 + 6
    if G<M>::run() != 33 { return 1 }
    // 2 + 2
    if concrete() != 4 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: f = {{ ?}}::{{.*}}::I_witness<A>::make;
// IR-DAG: z = {{ ?}}::{{.*}}::I_witness<A>::template sized<signed long>;
// IR-DAG: g = {{ ?}}::{{.*}}::tramp<A>;
// IR-DAG: h = {{ ?}}::{{.*}}::H<A>::get;
// IR-DAG: s = {{ ?}}::{{.*}}::G<A>::twice;
// IR-DAG: g ={{ ?}}::{{.*}}::tramp<{{ ?}}::{{.*}}::M>;
// IR-DAG: h = {{ ?}}::{{.*}}::H<{{ ?}}::{{.*}}::M>::get;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
