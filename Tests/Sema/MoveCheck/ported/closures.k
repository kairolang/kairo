// A closure with no capture list captures every variable it names by value,
// at the closure's creation, using the type's transfer semantics: a MOVE
// value is moved into the closure and the enclosing binding is moved-from
// afterwards. A COPY value or a primitive is copied. `|*|`, `|*x|` and
// `|const *x|` capture a pointer and move nothing; `|x|` moves like the
// default (ownership.mdx, Closure Captures; closures.mdx, Capture Modes).
// A variable declared inside the closure is the closure's own.
// Cases from Rust tests/ui/closures/closure-move-use-after-move-diagnostic,
// borrowck/borrowck-move-moved-value-into-closure,
// moves/moves-based-on-type-capture-clause-bad, issue-75904-move-closure-loop,
// arc-consumed-in-looped-closure.

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

fn eat(t: Tok) -> i32 { return t.id }

fn default_capture_moves() -> i32 {
    var t = Tok(1)
    var f = fn () -> i32 { return t.id }
    return t.id + f() //! SC052E
}

fn default_capture_moves_then_call() -> i32 {
    var t = Tok(1)
    var f = fn () -> i32 { return t.id }
    return f()
}

fn named_capture_moves() -> i32 {
    var t = Tok(1)
    var f = fn ()|t| -> i32 { return t.id }
    return f() + t.id //! SC052E
}

fn two_closures_capture_the_same_value() -> i32 {
    var t = Tok(1)
    var f = fn () -> i32 { return t.id }
    var g = fn () -> i32 { return t.id } //! SC052E
    return f() + g()
}

fn captured_by_pointer_does_not_move() -> i32 {
    var t = Tok(1)
    var f = fn ()|*| -> i32 { return (*t).id }
    return f() + t.id
}

fn captured_by_named_pointer() -> i32 {
    var t = Tok(1)
    var f = fn ()|*t| -> i32 { return (*t).id }
    return f() + t.id
}

fn captured_by_const_pointer() -> i32 {
    var t = Tok(1)
    var f = fn ()|const *t| -> i32 { return (*t).id }
    return f() + t.id
}

fn mixed_capture_moves_only_value_names() -> i32 {
    var a = Tok(1)
    var b = Tok(2)
    var f = fn ()|a, *b| -> i32 { return a.id + (*b).id }
    return f() + b.id + a.id //! SC052E
}

fn copy_type_captured_by_copy() -> i32 {
    var c = Cp(4)
    var f = fn () -> i32 { return c.id }
    return f() + c.id
}

fn primitive_captured_by_copy() -> i32 {
    var n = 4
    var f = fn () -> i32 { return n }
    return f() + n
}

fn reassigned_after_capture() -> i32 {
    var t = Tok(1)
    var f = fn () -> i32 { return t.id }
    t = Tok(2)
    return f() + t.id
}

fn closure_declared_in_branch(c: bool) -> i32 {
    var t = Tok(1)
    if c {
        var f = fn () -> i32 { return t.id }
    }
    return t.id //! SC052E
}

fn closure_declared_in_loop() -> i32 {
    var t = Tok(1)
    var n = 0
    for i in 0..2 {
        var f = fn () -> i32 { return t.id } //! SC052E
        n += f()
    }
    return n
}

fn closure_declared_in_loop_reinit() -> i32 {
    var t = Tok(1)
    var n = 0
    for i in 0..2 {
        var f = fn () -> i32 { return t.id }
        n += f()
        t = Tok(i)
    }
    return n
}

fn captured_local_of_closure_is_its_own() -> i32 {
    var t = Tok(1)
    var f = fn () -> i32 {
        var inner = Tok(5)
        var moved = inner
        return moved.id
    }
    return f() + t.id
}

fn closure_param_is_moved_in_the_body() -> i32 {
    var f = fn (p: Tok) -> i32 {
        var q = p
        return p.id //! SC052E
    }
    return f(Tok(3))
}

fn closure_moves_captured_and_reads() -> i32 {
    var t = Tok(1)
    var f = fn () -> i32 {
        var q = t
        return t.id //! SC052E
    }
    return f()
}

fn nested_closure_default_capture() -> i32 {
    var t = Tok(1)
    var f = fn () -> i32 {
        var g = fn () -> i32 { return t.id }
        return g()
    }
    return f() + t.id //! SC052E
}

fn closure_argument_moved_into_call() -> i32 {
    var t = Tok(1)
    var f = fn (x: Tok) -> i32 { return x.id }
    var r = f(t)
    return r + t.id //! SC052E
}

fn closure_does_not_name_the_value() -> i32 {
    var t = Tok(1)
    var f = fn () -> i32 { return 5 }
    return f() + t.id
}

fn closure_names_only_a_field() -> i32 {
    var t = Tok(1)
    var f = fn () -> i32 { return t.id }
    return f() + t.id //! SC052E
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: closures.k:30:{{[0-9]+}}: error [SC052E]:
// CHECK: closures.k:42:{{[0-9]+}}: error [SC052E]:
// CHECK: closures.k:48:{{[0-9]+}}: error [SC052E]:
// CHECK: closures.k:74:{{[0-9]+}}: error [SC052E]:
// CHECK: closures.k:101:{{[0-9]+}}: error [SC052E]:
// CHECK: closures.k:108:{{[0-9]+}}: error [SC052E]:
// CHECK: closures.k:138:{{[0-9]+}}: error [SC052E]:
// CHECK: closures.k:147:{{[0-9]+}}: error [SC052E]:
// CHECK: closures.k:158:{{[0-9]+}}: error [SC052E]:
// CHECK: closures.k:165:{{[0-9]+}}: error [SC052E]:
// CHECK: closures.k:177:{{[0-9]+}}: error [SC052E]:
