// The members of `eval if A impl Resizer` are granted only inside the taken
// branch. Outside it, a bound of just Allocator does not reach `resize`.

interface Allocator {
    static fn alloc(n: usize) -> usize
}
interface Resizer derives Allocator {
    static fn resize(n: usize) -> usize
}

class Fixed impl Allocator {
    static fn alloc(n: usize) -> usize { return n + 1 }
}

fn <A impl Allocator> grow(n: usize) -> usize {
    return A::resize(n)
}

fn main() -> i32 { return grow<Fixed>(1) as i32 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: if_impl_per_instance_reject.k:16:15: error [R025E]: no member named 'resize' in the bounds of 'A'
