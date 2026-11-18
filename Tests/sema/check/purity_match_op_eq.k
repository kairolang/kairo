// A `match` pattern that tests a record against a constant calls the
// record's `op ==` (MatchLowering mints the comparison), a call no node
// shows before the lowerings. A const / @pure function may make it only
// when the operator keeps the promise too: `bumps`' writes a global, so
// `classify` is rejected at the pattern; `same`'s is @pure, so `@pure`
// `classify_pure` is clean.

var hits: i32 = 0

struct Bumps {
    var x: i32
    fn op == (const self, o: Bumps) -> bool { hits = hits + 1; return self.x == o.x }
}

struct Same {
    var x: i32
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
// CHECK: purity_match_op_eq.k:25:14: error [SC200E]: 'classify' is const, so it cannot call 'op ==', which is not a const fn
// CHECK-NOT: error [SC200E]
