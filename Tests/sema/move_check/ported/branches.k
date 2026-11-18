// A move on one path of a branch leaves the value moved-from after the
// join: the compiler tracks which bindings are live on every path
// (ownership.mdx, Moved-From State). A path that leaves the function or the
// loop after the move does not reach the join. Reassigning on every moving
// path makes the value usable again.
// Cases from Rust tests/ui/moves/move-3-unique, match-move-same-binding-15571,
// matching-partially-moved-value-17385, move-in-guard-1, move-in-guard-2,
// move-guard-same-consts; borrowck/use-moved-value-in-match-guard-drop;
// drop/conditional-drop-10734; the guard shapes are in
// bug_match_guard_moves.k.

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

enum Shape { Circle, Square, Tri }

fn eat(t: Tok) -> i32 { return t.id }
fn pick() -> bool { return true }

fn one_arm_moves(c: bool) -> i32 {
    var a = Tok(1)
    if c {
        var b = a
    }
    return a.id //! SC052E
}

fn else_arm_moves(c: bool) -> i32 {
    var a = Tok(1)
    if c {
    } else {
        eat(a)
    }
    return a.id //! SC052E
}

fn both_arms_move(c: bool) -> i32 {
    var a = Tok(1)
    if c {
        eat(a)
    } else {
        eat(a)
    }
    return a.id //! SC052E
}

fn neither_arm_moves(c: bool) -> i32 {
    var a = Tok(1)
    if c {
        var n = a.id
    } else {
        var m = a.id + 1
    }
    return a.id
}

fn else_if_chain(x: i32) -> i32 {
    var a = Tok(1)
    if x == 0 {
        var n = 1
    } else if x == 1 {
        eat(a)
    } else {
        var m = 2
    }
    return a.id //! SC052E
}

fn moving_arm_returns(c: bool) -> i32 {
    var a = Tok(1)
    if c {
        return eat(a)
    }
    return a.id
}

fn moving_arm_returns_then_falls(c: bool) -> i32 {
    var a = Tok(1)
    if c {
        eat(a)
        return 0
    } else {
        var n = 1
    }
    return a.id
}

fn use_inside_moving_arm_after_move(c: bool) -> i32 {
    var a = Tok(1)
    if c {
        eat(a)
        return a.id //! SC052E
    }
    return a.id
}

fn reassigned_in_moving_arm(c: bool) -> i32 {
    var a = Tok(1)
    if c {
        eat(a)
        a = Tok(2)
    }
    return a.id
}

fn reassigned_in_other_arm_only(c: bool) -> i32 {
    var a = Tok(1)
    if c {
        eat(a)
    } else {
        a = Tok(2)
    }
    return a.id //! SC052E
}

fn reassigned_in_both_arms(c: bool) -> i32 {
    var a = Tok(1)
    eat(a)
    if c {
        a = Tok(2)
    } else {
        a = Tok(3)
    }
    return a.id
}

fn moved_before_branch_used_in_one_arm(c: bool) -> i32 {
    var a = Tok(1)
    eat(a)
    if c {
        return a.id //! SC052E
    }
    return 0
}

fn nested_branch(c: bool, d: bool) -> i32 {
    var a = Tok(1)
    if c {
        if d {
            eat(a)
        }
    }
    return a.id //! SC052E
}

fn if_expression_moves(c: bool) -> i32 {
    var a = Tok(1)
    var r = if c => eat(a) else => 0
    return r + a.id //! SC052E
}

fn match_arm_moves(s: Shape) -> i32 {
    var a = Tok(1)
    match s {
        case .Circle { eat(a) }
        case .Square { var n = 1 }
        case .Tri { var n = 2 }
    }
    return a.id //! SC052E
}

fn match_every_arm_moves(s: Shape) -> i32 {
    var a = Tok(1)
    match s {
        case .Circle { eat(a) }
        case .Square { eat(a) }
        case .Tri { eat(a) }
    }
    return a.id //! SC052E
}

fn match_no_arm_moves(s: Shape) -> i32 {
    var a = Tok(1)
    match s {
        case .Circle { var n = a.id }
        case .Square { var n = 1 }
        default { var n = 2 }
    }
    return a.id
}

fn match_moving_arm_returns(s: Shape) -> i32 {
    var a = Tok(1)
    match s {
        case .Circle { return eat(a) }
        default { var n = 2 }
    }
    return a.id
}

fn match_value_form(s: Shape) -> i32 {
    var a = Tok(1)
    var r = match s {
        case .Circle => eat(a)
        default => 0
    }
    return r + a.id //! SC052E
}

fn match_scrutinee_moves(s: Shape) -> i32 {
    var a = Tok(1)
    var r = match eat(a) {
        case 1 => 10
        default => 20
    }
    return r + a.id //! SC052E
}

fn match_guard_reads_moved(s: Shape) -> i32 {
    var a = Tok(1)
    eat(a)
    match s {
        case .Circle where a.id == 1 { return 1 } //! SC052E
        default { return 2 }
    }
}

fn guard_moves_then_body_reads(v: i32) -> i32 {
    var a = Tok(1)
    match v {
        case 1 where take_true(a) { return a.id } //! SC052E
        default { return 3 }
    }
}

fn take_true(t: Tok) -> bool { return true }

fn scrutinee_of_moved_value(s: Shape) -> i32 {
    var a = Tok(1)
    eat(a)
    match a.id { //! SC052E
        case 1 { return 1 }
        default { return 2 }
    }
}

fn moved_in_both_then_reinit(c: bool) -> i32 {
    var a = Tok(1)
    if c {
        eat(a)
    } else {
        eat(a)
    }
    a = Tok(9)
    return a.id
}

fn moved_in_branch_reinit_after_join(c: bool) -> i32 {
    var a = Tok(1)
    if c {
        eat(a)
    }
    a = Tok(9)
    return a.id
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: branches.k:28:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:37:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:47:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:69:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:95:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:116:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:134:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:146:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:152:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:162:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:172:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:200:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:209:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:216:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:224:{{[0-9]+}}: error [SC052E]:
// CHECK: branches.k:234:{{[0-9]+}}: error [SC052E]:
