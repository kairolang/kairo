// The right operand of `??` runs only when the left is null, so a move there
// happens on some paths: afterwards the value is moved-from, as after a move
// in the right operand of `&&` or `||` (evaluation_order.k; ownership.mdx,
// Moved-From State). The compiler accepts the read below.

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn null_coalesce_right_operand_moves() -> i32 {
    var a = Tok(1)
    var o: Tok? = null
    var t = o ?? a
    return a.id + t.id //! SC052E
}


// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: bug_coalesce_right_operand_move.k:16:{{[0-9]+}}: error [SC052E]:
