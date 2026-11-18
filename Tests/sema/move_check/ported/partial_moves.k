// Moving a field leaves that field moved-from and the rest of the value
// usable. Using the moved field, or the value as a whole, is SC052E until
// the field is assigned again. The same holds for nested fields, for a field
// of `self`, for tuple elements and for a field reached through a pointer
// (ownership.mdx, Moving a part). A COPY field is copied, not moved.
// Cases from Rust tests/ui/moves/move-out-of-field, move-out-of-tuple-field,
// moves-based-on-type-match-bindings,
// moves-based-on-type-cyclic-types-issue-4821,
// matching-partially-moved-value-17385, nll/move-subpaths-moves-root,
// borrowck/issue-54499-field-mutation-of-moved-out.

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

class Pair {
    pub var a: Tok
    pub var b: Tok
    fn Pair(self) { self.a = Tok(1); self.b = Tok(2) }
}

class Outer {
    pub var p: Pair
    pub var n: i32 = 0
    pub var c: Tok
    fn Outer(self) { self.p = Pair(); self.c = Tok(3) }
}

struct Plain { var x: i32; var y: i32 }

fn eat(t: Tok) -> i32 { return t.id }
fn eat_pair(p: Pair) -> i32 { return p.a.id }
fn read_pair(const p: Pair) -> i32 { return p.b.id }

fn move_field_read_other() -> i32 {
    var p = Pair()
    var x = p.a
    return p.b.id + x.id
}

fn move_field_read_same() -> i32 {
    var p = Pair()
    var x = p.a
    return p.a.id + x.id //! SC052E
}

fn move_field_use_whole() -> i32 {
    var p = Pair()
    var x = p.a
    return eat_pair(p) + x.id //! SC052E
}

fn move_field_use_whole_const() -> i32 {
    var p = Pair()
    var x = p.a
    return read_pair(p) + x.id //! SC052E
}

fn move_field_reassign_field() -> i32 {
    var p = Pair()
    var x = p.a
    p.a = Tok(9)
    return eat_pair(p) + x.id
}

fn move_field_reassign_whole() -> i32 {
    var p = Pair()
    var x = p.a
    p = Pair()
    return p.a.id + x.id
}

fn move_both_fields_then_whole() -> i32 {
    var p = Pair()
    var x = p.a
    var y = p.b
    return eat_pair(p) + x.id + y.id //! SC052E
}

fn move_both_fields_reassign_both() -> i32 {
    var p = Pair()
    var x = p.a
    var y = p.b
    p.a = Tok(7)
    p.b = Tok(8)
    return eat_pair(p) + x.id + y.id
}

fn move_both_fields_reassign_one() -> i32 {
    var p = Pair()
    var x = p.a
    var y = p.b
    p.a = Tok(7)
    return eat_pair(p) + x.id + y.id //! SC052E
}

fn move_field_twice() -> i32 {
    var p = Pair()
    var x = p.a
    var y = p.a //! SC052E
    return x.id + y.id
}

fn move_field_into_call() -> i32 {
    var p = Pair()
    var r = eat(p.a)
    return p.a.id + r //! SC052E
}

fn nested_field_move() -> i32 {
    var o = Outer()
    var x = o.p.a
    return o.p.b.id + o.c.id + x.id
}

fn nested_field_use_parent() -> i32 {
    var o = Outer()
    var x = o.p.a
    return eat_pair(o.p) + x.id //! SC052E
}

fn nested_field_use_grandparent_field() -> i32 {
    var o = Outer()
    var x = o.p.a
    return o.p.a.id + x.id //! SC052E
}

fn nested_field_reassign_parent() -> i32 {
    var o = Outer()
    var x = o.p.a
    o.p = Pair()
    return o.p.a.id + x.id
}

fn move_parent_then_child() -> i32 {
    var o = Outer()
    var q = o.p
    return o.p.a.id + q.a.id //! SC052E
}

fn move_child_then_parent_field_ok() -> i32 {
    var o = Outer()
    var x = o.p.a
    var y = o.c
    return o.n + x.id + y.id
}

fn copy_field_survives() -> i32 {
    var o = Outer()
    var n = o.n
    return o.n + n
}

fn plain_struct_fields_copy() -> i32 {
    var s = Plain { x: 1, y: 2 }
    var a = s.x
    return s.x + s.y + a
}

class Machine {
    pub var a: Tok
    pub var b: Tok
    fn Machine(self) { self.a = Tok(1); self.b = Tok(2) }

    fn take_a_then_read_a(self) -> i32 {
        var x = self.a
        return self.a.id + x.id //! SC052E
    }

    fn take_a_then_read_b(self) -> i32 {
        var x = self.a
        self.a = Tok(5)
        return self.b.id + x.id + self.a.id
    }

    fn take_a_reassign(self) -> i32 {
        var x = self.a
        self.a = Tok(5)
        return self.a.id + x.id
    }
}

fn tuple_element_moves() -> i32 {
    var t = (Tok(1), Tok(2))
    var x = t.0
    return t.1.id + x.id
}

fn tuple_element_read_moved() -> i32 {
    var t = (Tok(1), Tok(2))
    var x = t.0
    return t.0.id + x.id //! SC052E
}

fn tuple_whole_after_element_move() -> i32 {
    var t = (Tok(1), Tok(2))
    var x = t.0
    var u = t //! SC052E
    return x.id
}

fn partial_move_in_branch(c: bool) -> i32 {
    var p = Pair()
    if c {
        var x = p.a
    }
    return p.a.id //! SC052E
}

fn partial_move_other_field_after_branch(c: bool) -> i32 {
    var p = Pair()
    if c {
        var x = p.a
    }
    return p.b.id
}

fn partial_move_return_field(c: bool) -> Tok {
    var p = Pair()
    return p.a
}

fn partial_move_return_whole_after(c: bool) -> Pair {
    var p = Pair()
    var x = p.a
    return p //! SC052E
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: partial_moves.k:46:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:52:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:58:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:79:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:96:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:102:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:109:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:121:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:127:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:140:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:169:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:194:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:200:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:209:{{[0-9]+}}: error [SC052E]:
// CHECK: partial_moves.k:228:{{[0-9]+}}: error [SC052E]:
