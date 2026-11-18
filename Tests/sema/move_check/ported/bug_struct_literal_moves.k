// A brace initializer evaluates its field initialisers in order, so a second
// initialiser that names a value an earlier one moved is a use after the
// move: SC052E, as for an array literal `[a, a]` or a call `f(a, a)`
// (ownership.mdx, Moved-From State: "any use of a moved-from binding is a
// compile error"). The compiler accepts both shapes below; the same shapes
// as a tuple or an array literal are rejected (straight_line.k).

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

struct Two { var a: Tok; var b: Tok }
struct Box2 { var a: Tok; var n: i32 }

fn same_value_in_two_fields() -> i32 {
    var a = Tok(1)
    var t = Two { a: a, b: a } //! SC052E
    return t.a.id
}

fn field_reads_the_value_an_earlier_field_moved() -> i32 {
    var a = Tok(1)
    var t = Box2 { a: a, n: a.id } //! SC052E
    return t.n
}

// XFAIL: *

// XFAIL: *
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: bug_struct_literal_moves.k:19:{{[0-9]+}}: error [SC052E]:
// CHECK: bug_struct_literal_moves.k:25:{{[0-9]+}}: error [SC052E]:
