// A union's `impl` list is checked as a struct's: a declared conformance
// the union does not meet is reported where a bound needs it, with the
// same diagnostic a struct gets.

interface Same {
    fn op ==(const self, o: Self) -> bool
}

union Bits impl Same {
    var word: u32
    var half: u16
}

struct Rec impl Same {
    var word: u32
}

fn <T> eq(x: T, y: T) -> bool requires T impl Same {
    return x == y
}

fn main() -> i32 {
    var a: Bits
    var r: Rec
    if eq(a, a) || eq(r, r) {
        return 1
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: union_impl_unmet.k:25:8: error [SC162E]: 'Bits' does not conform to 'Same': no member 'op ==' with the requirement's signature
// CHECK: union_impl_unmet.k:25:20: error [SC162E]: 'Rec' does not conform to 'Same': no member 'op ==' with the requirement's signature
// CHECK-NOT: error
