// A tuple's lifecycle facts are its elements' folded (ClassLifecycle::
// facts_of_type), not its minted pattern's, which hang on the parameters:
// `(Mv, i32)` is MOVE, so `var u = t` moves `t` and a later read of it is
// a use after move. Without the fold the copy reaches clang as a deleted
// copy constructor (CL001E) with no Kairo diagnostic before it.

class Mv {
    pub var id: i32
    pub fn Mv(self, id: i32) { self.id = id; }
    @move fn Mv(self, other: Self) { self.id = other.id; }
}

fn mk() -> (Mv, i32) { return (Mv(7), 1) }

fn moved() -> i32 {
    var t = mk()
    var u = t
    return t.1
// DIAG: move_tuple.k:[[@LINE-1]]:12: error [SC052E]: 't' is used after being moved
}

fn plain() -> i32 {
    var t = (1, 2)
    var u = t                            // a copy: nothing to report
    return t.0 + u.1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
