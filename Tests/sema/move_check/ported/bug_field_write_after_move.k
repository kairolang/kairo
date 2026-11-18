// A write to a field of a moved-from variable is an access to the moved-from
// binding: "between the move and the reassignment, any access is a hard
// error" (ownership.mdx, Moved-From State). A write to a field of a moved-from
// local is accepted today; the same write through the whole-container move
// of an array element is rejected (containers_and_pointers.k).

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn write_tuple_element_after_move() -> i32 {
    var t = (Tok(1), 2)
    var u = t
    t.1 = 5 //! SC052E
    return u.1
}

fn write_field_after_move() -> i32 {
    var a = Tok(1)
    var b = a
    a.id = 4 //! SC052E
    return b.id
}

// XFAIL: *

// XFAIL: *
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: bug_field_write_after_move.k:16:{{[0-9]+}}: error [SC052E]:
// CHECK: bug_field_write_after_move.k:23:{{[0-9]+}}: error [SC052E]:
