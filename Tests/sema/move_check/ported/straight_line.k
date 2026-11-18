// A MOVE-only value is invalidated by every by-value transfer: a variable
// initialiser, an assignment, a by-value argument, a return, an element of an
// array, tuple or vector literal, a field of a struct or class built with
// field syntax, a by-value method receiver's argument. Any later read of
// the source is SC052E until the variable is assigned again
// (ownership.mdx, Moved-From State; functions-parameter-modes.mdx, @move is
// checked). A COPY value is untouched by the same shapes.
// Cases from Rust tests/ui/moves/move-2, move-3-unique, move-4, move-arg,
// move-arg-2, moves-based-on-type-exprs, moves-based-on-type-tuple,
// moves-based-on-type-distribute-copy-over-paren.

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

class Holder {
    pub var t: Tok
    fn Holder(self, t: Tok) { self.t = t }
}

struct Wrap { var t: Tok }

fn eat(t: Tok) -> i32 { return t.id }
fn eat2(a: Tok, b: Tok) -> i32 { return a.id + b.id }
fn peek(const t: Tok) -> i32 { return t.id }
fn make(id: i32) -> Tok { return Tok(id) }

fn init_then_read() -> i32 {
    var a = Tok(1)
    var b = a
    return a.id //! SC052E
}

fn assign_then_read() -> i32 {
    var a = Tok(1)
    var b = Tok(2)
    b = a
    return a.id //! SC052E
}

fn arg_then_read() -> i32 {
    var a = Tok(1)
    var r = eat(a)
    return a.id + r //! SC052E
}

fn arg_then_pass_again() -> i32 {
    var a = Tok(1)
    var r = eat(a)
    return eat(a) + r //! SC052E
}

fn return_moves_local() -> Tok {
    var a = Tok(1)
    return a
}

fn two_moves_same_call() -> i32 {
    var a = Tok(1)
    return eat2(a, a) //! SC052E
}

fn array_literal() -> i32 {
    var a = Tok(1)
    var arr = [a, Tok(2)]
    return a.id //! SC052E
}

fn vector_literal() -> i32 {
    var a = Tok(1)
    var v: [Tok] = [a, Tok(2)]
    return a.id //! SC052E
}

fn tuple_literal() -> i32 {
    var a = Tok(1)
    var t = (a, 5)
    return a.id //! SC052E
}

fn struct_literal() -> i32 {
    var a = Tok(1)
    var w = Wrap { t: a }
    return a.id //! SC052E
}

fn class_ctor_arg() -> i32 {
    var a = Tok(1)
    var h = Holder(a)
    return a.id //! SC052E
}

fn moved_twice_into_vars() -> i32 {
    var a = Tok(1)
    var b = a
    var c = a //! SC052E
    return b.id + c.id
}

fn chain_of_moves() -> i32 {
    var a = Tok(1)
    var b = a
    var c = b
    return c.id + b.id //! SC052E
}

fn const_param_does_not_move() -> i32 {
    var a = Tok(1)
    var r = peek(a)
    return a.id + r
}

fn temporaries_do_not_leave_a_name() -> i32 {
    var r = eat(Tok(1)) + eat(make(2))
    return r
}

fn field_read_does_not_move() -> i32 {
    var a = Tok(1)
    var n = a.id
    return a.id + n
}

fn copy_type_survives() -> i32 {
    var a = Cp(1)
    var b = a
    var r = a.id + b.id
    return r
}

fn primitive_survives() -> i32 {
    var a = 5
    var b = a
    return a + b
}

fn ok_assigned_then_read() -> i32 {
    var a = Tok(1)
    var b = a
    a = Tok(3)
    return a.id + b.id
}

fn move_into_new_scope_variable() -> i32 {
    var a = Tok(1)
    {
        var inner = a
    }
    return a.id //! SC052E
}

fn move_in_nested_block_assign_outer() -> i32 {
    var a = Tok(1)
    var out = Tok(0)
    {
        out = a
    }
    return a.id + out.id //! SC052E
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: straight_line.k:39:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:46:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:52:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:58:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:68:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:74:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:80:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:86:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:92:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:98:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:104:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:112:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:157:{{[0-9]+}}: error [SC052E]:
// CHECK: straight_line.k:166:{{[0-9]+}}: error [SC052E]:
