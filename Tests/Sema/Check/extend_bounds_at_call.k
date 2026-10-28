// An extension member exists only on the instances whose arguments meet
// the extension's bounds (extends.mdx, Generic Extends: "Calling
// `pair_of_noncomparable.max()` ... is a compile error"), so the call is
// rejected at the call site.
//
// XFAIL: *
// Ticket "[Sema] An extension member's bounds are not checked at the call
// site" (private/IMPORTANT/TICKETS.TXT, 2026-10-26; status.mdx, Not
// Diagnosed). Today `p.max()` on a Pair<Opaque> type-checks: the bound
// `T impl Comparable` is not checked for T = Opaque, and the error (if
// any) comes from clang. The code is not decided; the check asks for an
// error at the call. When it XPASSes, delete the XFAIL and pin the code
// and message.

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
// CHECK: extend_bounds_at_call.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
    return m.n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
