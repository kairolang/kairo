// `eval if A impl I` in a function body is decided once per instantiation
// (P234): the condition is I's concept in an `if constexpr`, and in the
// taken branch A has I's members, as if the bound had been declared. One
// TU instantiates the template with an allocator that has the capability
// and one that does not, and each takes its own branch. The taken branch
// calls a member only Resizer declares, so it would not bind (R051E /
// R025E) without the narrowing.

interface Allocator {
    static fn alloc(n: usize) -> usize
}
interface Resizer derives Allocator {
    static fn resize(n: usize) -> usize
}

class Grows impl Resizer {
    static fn alloc(n: usize) -> usize { return n }
    static fn resize(n: usize) -> usize { return n * 2 }
}
class Fixed impl Allocator {
    static fn alloc(n: usize) -> usize { return n + 1 }
}

fn <A impl Allocator> grow(n: usize) -> usize {
    eval if A impl Resizer {
        return A::resize(n) + A::alloc(0)
    } else {
        return A::alloc(n) + 100
    }
}

// No declared bound at all: the test alone grants the members.
fn <A> pick(n: usize) -> usize {
    eval if A impl Resizer && A impl Allocator {
        return A::resize(n)
    } else {
        return 7
    }
}

fn main() -> i32 {
    if grow<Grows>(5) != 10 { return 1 }
    if grow<Fixed>(5) != 106 { return 2 }
    if pick<Grows>(4) != 8 { return 3 }
    if pick<Fixed>(4) != 7 { return 4 }
    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: if constexpr(( ::if_impl_per_instance::Resizer_c<A>))
// IR: ::if_impl_per_instance::Resizer_witness<A>::resize(n)
// IR: if constexpr(( ::if_impl_per_instance::Resizer_c<A>) &&( ::if_impl_per_instance::Allocator_c<A>))
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
