// Move assignment from a NAMED value: `x = y` on a MOVE-category lvalue is
// an implicit move (the transfer-checking rule), so the derived `op =`
// destroys the old x and move-constructs y into it: one move, one
// destruction. `x = x` is the self-assignment guard's case and does
// nothing. derived_assign.k covers the prvalue form (`m = M(5)`); the
// use-after-move half lives in Sema/Modes/MoveCheck/move_assign_named.k.

var moves: i32 = 0
var drops: i32 = 0

class M {
    pub var v: i32
    pub fn M(self, v: i32) { self.v = v }
    @move
    fn M(self, other: Self) {
        self.v = other.v
        moves = moves + 1
    }
    fn op delete(self) { drops = drops + 1 }
}

fn named() -> i32 {
    var x = M(1)
    var y = M(5)
    x = y
    if (moves == 1) && (drops == 1) && (x.v == 5) { return 1 }
    return 0
}

fn self_assign() -> i32 {
    var x = M(3)
    x = x
    if (moves == 0) && (drops == 0) && (x.v == 3) { return 2 }
    return 0
}

fn main() -> i32 {
    var r = named()
    moves = 0
    drops = 0
    r += self_assign()
    return r                            // 1 + 2 == 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}move_assign_named.k
// IR:      (x = static_cast<{{ ?}}::move_assign_named::M &&>(y));
// IR:      (x = static_cast<{{ ?}}::move_assign_named::M &&>(x));

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 3
