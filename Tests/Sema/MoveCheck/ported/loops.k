// A move inside a loop body runs again on the next iteration, so the value is
// used after a move unless the body reassigns it, or leaves the loop right
// after the move (ownership.mdx, Moved-From State; the compiler tracks
// liveness over every path, loops included). A binder of a loop is a fresh
// local per iteration. A `for` header is evaluated once.
// Cases from Rust tests/ui/moves/issue-72649-uninit-in-loop,
// issue-75904-move-closure-loop, nested-loop-moved-value-wrong-continue,
// recreating-value-in-loop-condition;
// borrowck/moved-value-in-thread-loop-12041; drop/dropflag-reinit-in-loop.

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn eat(t: Tok) -> i32 { return t.id }
fn more() -> bool { return true }

fn while_moves() -> i32 {
    var a = Tok(1)
    var n = 0
    while n < 3 {
        n += eat(a) //! SC052E
    }
    return n
}

fn for_moves() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..3 {
        n += eat(a) //! SC052E
    }
    return n
}

fn loop_moves() -> i32 {
    var a = Tok(1)
    var n = 0
    loop {
        n += eat(a) //! SC052E
        if n > 2 { break }
    }
    return n
}

fn c_style_for_moves() -> i32 {
    var a = Tok(1)
    var n = 0
    for var i = 0; i < 3; i++ {
        n += eat(a) //! SC052E
    }
    return n
}

fn move_then_break() -> i32 {
    var a = Tok(1)
    var n = 0
    while n < 3 {
        n += eat(a)
        break
    }
    return n
}

fn move_then_return() -> i32 {
    var a = Tok(1)
    for i in 0..3 {
        if i == 1 {
            return eat(a)
        }
    }
    return 0
}

fn move_then_break_conditional() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..5 {
        if i == 2 {
            n = eat(a)
            break
        }
    }
    return n
}

fn move_then_break_use_after_loop() -> i32 {
    var a = Tok(1)
    for i in 0..5 {
        if i == 2 {
            eat(a)
            break
        }
    }
    return a.id //! SC052E
}

fn reassigned_each_iteration() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..3 {
        n += eat(a)
        a = Tok(i + 10)
    }
    return n + a.id
}

fn reassigned_before_move_each_iteration() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..3 {
        a = Tok(i)
        n += eat(a)
    }
    return n
}

fn reassigned_only_on_one_path() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..3 {
        n += eat(a) //! SC052E
        if i == 0 {
            a = Tok(5)
        }
    }
    return n
}

fn move_then_continue() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..3 {
        if i == 1 {
            n += eat(a) //! SC052E
            continue
        }
    }
    return n
}

fn move_then_continue_after_reinit() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..3 {
        if i == 1 {
            n += eat(a)
            a = Tok(7)
            continue
        }
    }
    return n + a.id
}

fn declared_in_body_moves_ok() -> i32 {
    var n = 0
    for i in 0..3 {
        var a = Tok(i)
        n += eat(a)
    }
    return n
}

fn declared_in_body_moved_then_read() -> i32 {
    var n = 0
    for i in 0..3 {
        var a = Tok(i)
        n += eat(a)
        n += a.id //! SC052E
    }
    return n
}

fn nested_loop_inner_moves() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..2 {
        for j in 0..2 {
            n += eat(a) //! SC052E
        }
    }
    return n
}

fn nested_loop_outer_declared() -> i32 {
    var n = 0
    for i in 0..2 {
        var a = Tok(i)
        for j in 0..2 {
            n += a.id
        }
        n += eat(a)
    }
    return n
}

fn nested_loop_break_inner_only() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..2 {
        for j in 0..2 {
            n += eat(a) //! SC052E
            break
        }
    }
    return n
}

fn while_condition_moves() -> i32 {
    var a = Tok(1)
    var n = 0
    while eat(a) < 5 { //! SC052E
        n += 1
        if n > 3 { break }
    }
    return n
}

fn while_condition_recreates() -> i32 {
    var n = 0
    while eat(Tok(n)) < 3 {
        n += 1
    }
    return n
}

fn loop_after_loop_moves() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..3 {
        n += i
    }
    n += eat(a)
    return n
}

fn labeled_break_outer(c: bool) -> i32 {
    var a = Tok(1)
    var n = 0
    outer: for i in 0..3 {
        for j in 0..3 {
            if j == 1 {
                n += eat(a)
                break outer
            }
        }
    }
    return n
}

fn header_evaluated_once() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..eat(a) {
        n += i
    }
    return n
}

fn header_moves_use_in_body() -> i32 {
    var a = Tok(1)
    var n = 0
    for i in 0..eat(a) {
        n += a.id //! SC052E
    }
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: loops.k:24:{{[0-9]+}}: error [SC052E]:
// CHECK: loops.k:33:{{[0-9]+}}: error [SC052E]:
// CHECK: loops.k:42:{{[0-9]+}}: error [SC052E]:
// CHECK: loops.k:52:{{[0-9]+}}: error [SC052E]:
// CHECK: loops.k:97:{{[0-9]+}}: error [SC052E]:
// CHECK: loops.k:124:{{[0-9]+}}: error [SC052E]:
// CHECK: loops.k:137:{{[0-9]+}}: error [SC052E]:
// CHECK: loops.k:171:{{[0-9]+}}: error [SC052E]:
// CHECK: loops.k:181:{{[0-9]+}}: error [SC052E]:
// CHECK: loops.k:204:{{[0-9]+}}: error [SC052E]:
// CHECK: loops.k:214:{{[0-9]+}}: error [SC052E]:
// CHECK: loops.k:266:{{[0-9]+}}: error [SC052E]:
