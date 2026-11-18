// A `where` guard that moves a value moves it whether the guard holds or
// not, and a failed guard falls through to the next case
// (pattern-matching.mdx, `where` guards: "A case with a guard that fails
// falls through to the next case"; ownership.mdx, Function Parameters: passing
// a MOVE value moves it). A later guard or the default arm that names the
// value is a use after the move: SC052E. The compiler accepts both reads
// below; a read in the body of the guarded case is rejected (branches.k).

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn take_true(t: Tok) -> bool { return true }

fn second_guard_moves_again(v: i32) -> i32 {
    var a = Tok(1)
    match v {
        case 1 where take_true(a) { return 1 }
        case 2 where take_true(a) { return 2 } //! SC052E
        default { return 3 }
    }
}

fn default_reads_after_failed_guard(v: i32) -> i32 {
    var a = Tok(1)
    match v {
        case 1 where take_true(a) { return 1 }
        default { return a.id } //! SC052E
    }
}

// XFAIL: *

// XFAIL: *
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: bug_match_guard_moves.k:21:{{[0-9]+}}: error [SC052E]:
// CHECK: bug_match_guard_moves.k:30:{{[0-9]+}}: error [SC052E]:
