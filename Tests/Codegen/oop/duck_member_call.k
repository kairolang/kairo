// Member calls through a `<T: type>` parameter (-fduck-generics, MONO.md D1)
// go out as written and clang resolves each one per instance: `.f(...)` on
// a value, `->f(...)` through a pointer, `.template f<A>(...)` with explicit
// generic arguments, and `T::f(...)` for a static member -- the shape of
// Compiler/'s `isa<T>(n)` (`T::classof(n)`). crtp_duck.k is the CRTP case.
// Only a chain rooted at a `: type` parameter goes out unbound; an unbound
// step in a bounded body still ICEs (witness/bound_call_member.k, G7).

struct In { var w: i32 }

class Box {
    fn inner(const self) -> In { return In { w: 2 } }
    fn <U> pick(const self, u: U) -> U { return u }
    fn twice(const self) -> i32 { return 21 }
    static fn classof(n: i32) -> bool { return n == 1 }
}

fn <T: type> by_ptr(p: *T) -> i32 { return p->twice() }

fn <T: type> by_value(t: T) -> i32 { return t.pick<i32>(5) + t.twice() }

fn <T: type> is(n: i32) -> bool { return T::classof(n) }

// A step past the first is on a result only the instance knows.
fn <T: type> chained(t: T) -> i32 { return t.inner().w }

fn main() -> i32 {
    var b = Box()
    var r = by_value(b) + by_ptr(&b)    // 5 + 21 + 21
    if is<Box>(1) && (!is<Box>(2)) { r += 1 }
    return r + chained(b)               // 48 + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s -fduck-generics --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: p->twice()
// IR-DAG: t.template pick<
// IR-DAG: T::classof(n)
// IR-DAG: t.inner().w

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 50
