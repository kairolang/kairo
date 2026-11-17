// An extension member exists only on the instances whose arguments meet
// the extension's bounds (extends.mdx, Generic Extends: "Calling
// `pair_of_noncomparable.max()` ... is a compile error"), so the call is
// rejected at the call site.

interface Comparable {
    fn op <(const self, other: Self) -> bool
}

struct <T> Pair {
    pub var first: T
    pub var second: T
}

extend <T impl Comparable> Pair<T> {
    pub fn max(const self) -> T {
        return if self.first < self.second => self.second else => self.first
    }
}

struct Opaque {
    pub var n: i32
}

fn main() -> i32 {
    var p = Pair<Opaque> { first: Opaque { n: 1 }, second: Opaque { n: 2 } }
    var m = p.max()
// CHECK: extend_bounds_at_call.k:[[@LINE-1]]:13: error [SC162E]: 'Opaque' does not conform to 'Comparable': no member 'op <' with the requirement's signature
// CHECK: extend_bounds_at_call.k:15:9: note [I900N]: required by this bound
    return m.n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
