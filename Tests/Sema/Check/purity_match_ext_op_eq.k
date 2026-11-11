// A `match` pattern's `op ==` judged by FnPurityCheck, when the operator is
// an EXTENSION member (purity_match_op_eq.k has the member case).
//
// The check found the operator through a MemberLookup whose extension index
// it never built, so an extension `op ==` was invisible to it: `classify`,
// a const fn, compared against `B1` through `Bumps`' writing `op ==` and was
// accepted, though C++ is then told `[[gnu::const]]` of a function that
// writes a global. The index is built on first lookup. `Same`'s
// extension `op ==` is @pure, so `@pure` `classify_pure` stays clean.

var hits: i32 = 0

struct Bumps {
    var x: i32
}

extend Bumps {
    fn op == (const self, o: Bumps) -> bool { hits = hits + 1; return self.x == o.x }
}

struct Same {
    var x: i32
}

extend Same {
    @pure fn op == (const self, o: Same) -> bool { return self.x == o.x }
}

eval B1: Bumps = Bumps { x: 1 }
eval S1: Same = Same { x: 1 }

fn classify(b: Bumps) const -> i32 {
    match b {
        case B1 { return 1 }
        default { return 0 }
    }
}

@pure fn classify_pure(s: Same) -> i32 {
    match s {
        case S1 { return 1 }
        default { return 0 }
    }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: purity_match_ext_op_eq.k:34:14: error [SC200E]: 'classify' is const, so it cannot call 'op ==', which is not a const fn
// CHECK-NOT: error [SC200E]
