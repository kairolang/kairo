// A move in an operand is seen by every later operand, argument, field
// initialiser and statement: operands run left to right, so a read that
// follows the move in the same expression is a use after the move. A read
// that comes first is fine. A move in the right operand of `&&`, `||` or `??`
// happens only on some paths and leaves the value moved-from after the
// expression (ownership.mdx, Moved-From State: the compiler tracks which
// bindings are live on every path).
// Cases from Rust tests/ui/moves/moves-based-on-type-tuple,
// moves-based-on-type-exprs, moves-based-on-type-distribute-copy-over-paren,
// issue-46099-move-in-macro; borrowck/borrowck-bad-nested-calls-move (the
// move-while-borrowed half is for Tether).

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

struct Two { var a: Tok; var b: Tok }

struct Box2 { var a: Tok; var n: i32 }

fn eat(t: Tok) -> i32 { return t.id }
fn both(a: Tok, n: i32) -> i32 { return a.id + n }
fn rd(const t: Tok) -> i32 { return t.id }
fn yes(t: Tok) -> bool { return t.id > 0 }
fn mk(n: i32) -> Tok { return Tok(n) }
fn maybe(n: i32) -> Tok? { return Tok(n) }

fn arg_reads_before_move_in_next_arg() -> i32 {
    var a = Tok(1)
    return both(a, a.id) //! SC052E
}

fn arg_reads_after_move_in_earlier_arg() -> i32 {
    var a = Tok(1)
    return both(a, a.id + 1) //! SC052E
}

fn arg_reads_then_moves() -> i32 {
    var a = Tok(1)
    return rd(a) + eat(a)
}

fn arg_moves_then_reads() -> i32 {
    var a = Tok(1)
    return eat(a) + rd(a) //! SC052E
}

fn binary_operands_left_moves() -> i32 {
    var a = Tok(1)
    return eat(a) + a.id //! SC052E
}

fn binary_operands_right_moves() -> i32 {
    var a = Tok(1)
    return a.id + eat(a)
}

fn and_right_operand_moves(c: bool) -> i32 {
    var a = Tok(1)
    if c && yes(a) {
        return 1
    }
    return a.id //! SC052E
}

fn or_right_operand_moves(c: bool) -> i32 {
    var a = Tok(1)
    if c || yes(a) {
        return 1
    }
    return a.id //! SC052E
}

fn and_left_operand_moves(c: bool) -> i32 {
    var a = Tok(1)
    if yes(a) && c {
        return 1
    }
    return a.id //! SC052E
}

fn and_both_operands_move_same() -> bool {
    var a = Tok(1)
    return yes(a) && yes(a) //! SC052E
}

fn and_right_reads_after_left_moves() -> bool {
    var a = Tok(1)
    return yes(a) && a.id > 0 //! SC052E
}

fn and_right_moves_inside_the_right_branch() -> bool {
    var a = Tok(1)
    var c = a.id > 0
    return c && yes(a)
}

fn while_and_condition(c: bool) -> i32 {
    var a = Tok(1)
    var n = 0
    while n < 2 && yes(a) { //! SC052E
        n += 1
    }
    return n
}

fn struct_literal_field_reads_before_move() -> i32 {
    var a = Tok(1)
    var t = Box2 { n: a.id, a: a }
    return t.n
}

fn struct_literal_distinct_values() -> i32 {
    var a = Tok(1)
    var b = Tok(2)
    var t = Two { a: a, b: b }
    return t.a.id + t.b.id
}

fn array_literal_same_value_twice() -> i32 {
    var a = Tok(1)
    var arr = [a, a] //! SC052E
    return 0
}

fn tuple_literal_same_value_twice() -> i32 {
    var a = Tok(1)
    var t = (a, a) //! SC052E
    return 0
}

fn return_expression_moves_then_reads() -> i32 {
    var a = Tok(1)
    return eat(a) + a.id //! SC052E
}

fn return_moves_in_branches(c: bool) -> Tok {
    var a = Tok(1)
    var b = Tok(2)
    if c {
        return a
    }
    return b
}

fn return_value_after_move() -> Tok {
    var a = Tok(1)
    var b = a
    return a //! SC052E
}

fn compound_assign_reads_moved() -> i32 {
    var a = Tok(1)
    var n = eat(a)
    n += a.id //! SC052E
    return n
}

fn index_expression_moves_then_reads() -> i32 {
    var a = Tok(1)
    var arr = [1, 2, 3]
    return arr[eat(a)] + a.id //! SC052E
}

fn call_result_temporary_is_not_a_name() -> i32 {
    return eat(mk(1)) + eat(mk(2)) + mk(3).id
}

fn string_interpolation_reads_after_move() -> i32 {
    var a = Tok(1)
    var r = eat(a)
    var s = f"{a.id} {r}" //! SC052E
    return r
}

fn sequence_of_calls_each_moves_own() -> i32 {
    var a = Tok(1)
    var b = Tok(2)
    var c = Tok(3)
    return eat(a) + eat(b) + eat(c)
}

fn argument_order_with_side_effect_reassign() -> i32 {
    var a = Tok(1)
    var n = eat(a)
    a = Tok(5)
    return n + eat(a)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: evaluation_order.k:32:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:37:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:47:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:52:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:65:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:73:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:81:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:86:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:91:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:103:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:124:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:130:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:136:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:151:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:157:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:164:{{[0-9]+}}: error [SC052E]:
// CHECK: evaluation_order.k:174:{{[0-9]+}}: error [SC052E]:
