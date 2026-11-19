// Assigning a whole moved-from variable makes it usable again; writing one
// field of a moved-from variable does not, the rest stays moved-from
// (ownership.mdx, Moved-From State). `std::move(x)` moves for every type and
// reassignment revives it. A variable declared and moved in a loop or a
// branch is a fresh object on each entry.
// Cases from Rust tests/ui/moves/issue-34721, match-move-same-binding-15571;
// borrowck/issue-54499-field-mutation-of-moved-out;
// drop/dropflag-reinit-in-loop.

import std

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

class Cp {
    pub var id: i32 = 0
    fn Cp(self, id: i32) { self.id = id }
    @copy fn Cp(self, const other: Self) { self.id = other.id }
}

class Pair {
    pub var a: Tok
    pub var b: Tok
    fn Pair(self) { self.a = Tok(1); self.b = Tok(2) }
}

fn eat(t: Tok) -> i32 { return t.id }

fn reassign_then_use() -> i32 {
    var a = Tok(1)
    var b = a
    a = Tok(2)
    return a.id + b.id
}

fn reassign_twice() -> i32 {
    var a = Tok(1)
    var b = a
    a = Tok(2)
    var c = a
    a = Tok(3)
    return a.id + b.id + c.id
}

fn reassign_from_another_variable() -> i32 {
    var a = Tok(1)
    var b = Tok(2)
    var c = a
    a = b
    return a.id + c.id + b.id //! SC052E
}

fn reassign_to_self_value_moved() -> i32 {
    var a = Tok(1)
    var b = a
    a = a //! SC052E
    return b.id
}

fn use_between_move_and_reassign() -> i32 {
    var a = Tok(1)
    var b = a
    var n = a.id //! SC052E
    a = Tok(2)
    return n + a.id + b.id
}

fn field_write_does_not_revive_whole() -> i32 {
    var p = Pair()
    var q = p.a
    p.b = Tok(9)
    return eat_pair_a(p) + q.id //! SC052E
}

fn eat_pair_a(p: Pair) -> i32 { return p.a.id }

fn std_move_then_reassign() -> i32 {
    var a = Tok(1)
    var b = std::move(a)
    a = Tok(2)
    return a.id + b.id
}

fn std_move_then_use() -> i32 {
    var a = Tok(1)
    var b = std::move(a)
    return a.id + b.id //! SC052E
}

fn std_move_copy_type_is_moved_from() -> i32 {
    var c = Cp(1)
    var d = std::move(c)
    return c.id + d.id //! SC052E
}

fn std_move_primitive_is_moved_from() -> i32 {
    var n = 5
    var m = std::move(n)
    return n + m //! SC052E
}

fn std_copy_leaves_source() -> i32 {
    var c = Cp(1)
    var d = std::copy(c)
    return c.id + d.id
}

fn std_move_field_then_field() -> i32 {
    var p = Pair()
    var x = std::move(p.a)
    return p.b.id + x.id
}

fn std_move_field_then_same_field() -> i32 {
    var p = Pair()
    var x = std::move(p.a)
    return p.a.id + x.id //! SC052E
}

fn reinit_in_branch_both_arms(c: bool) -> i32 {
    var a = Tok(1)
    var b = a
    if c {
        a = Tok(2)
    } else {
        a = Tok(3)
    }
    return a.id + b.id
}

fn reinit_in_one_arm(c: bool) -> i32 {
    var a = Tok(1)
    var b = a
    if c {
        a = Tok(2)
    }
    return a.id + b.id //! SC052E
}

fn reinit_in_loop_before_use() -> i32 {
    var a = Tok(1)
    var b = a
    var n = 0
    for i in 0..3 {
        a = Tok(i)
        n += a.id
    }
    return n + b.id
}

fn reinit_in_loop_may_not_run() -> i32 {
    var a = Tok(1)
    var b = a
    for i in 0..3 {
        a = Tok(i)
    }
    return a.id + b.id //! SC052E
}

fn reinit_in_infinite_loop_before_break() -> i32 {
    var a = Tok(1)
    var b = a
    loop {
        a = Tok(4)
        break
    }
    return a.id + b.id
}

fn move_reinit_move_again() -> i32 {
    var a = Tok(1)
    var n = eat(a)
    a = Tok(2)
    n += eat(a)
    return n
}

fn reinit_by_call_result() -> i32 {
    var a = Tok(1)
    var n = eat(a)
    a = Tok(eat(Tok(8)))
    return n + a.id
}

fn pointer_assign_through_revives() -> i32 {
    var a = Tok(1)
    var p: *Tok = &a
    var b = cxx::std::move(*p)
    *p = Tok(3)
    return (*p).id + b.id
}

fn plain_copy_assign_never_moves() -> i32 {
    var c = Cp(1)
    var d = Cp(2)
    d = c
    return c.id + d.id
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: reinitialization.k:53:{{[0-9]+}}: error [SC052E]:
// CHECK: reinitialization.k:59:{{[0-9]+}}: error [SC052E]:
// CHECK: reinitialization.k:66:{{[0-9]+}}: error [SC052E]:
// CHECK: reinitialization.k:75:{{[0-9]+}}: error [SC052E]:
// CHECK: reinitialization.k:90:{{[0-9]+}}: error [SC052E]:
// CHECK: reinitialization.k:96:{{[0-9]+}}: error [SC052E]:
// CHECK: reinitialization.k:102:{{[0-9]+}}: error [SC052E]:
// CHECK: reinitialization.k:120:{{[0-9]+}}: error [SC052E]:
// CHECK: reinitialization.k:140:{{[0-9]+}}: error [SC052E]:
// CHECK: reinitialization.k:160:{{[0-9]+}}: error [SC052E]:
ffi "c++" import "utility"
