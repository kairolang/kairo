// A `var` binding in a pattern is a copy of what it matched, so a value that
// cannot be copied is refused there (SC182E) and bound with `const` instead,
// which reads it in place. A binder of a loop over a generator's MOVE values
// is an ordinary local: moved onward, it is not read again. `var (x, y) = t`
// over a tuple of MOVE parts moves the tuple (pattern-matching.mdx, ADT
// destructuring; control-flow.mdx, loop binders; ownership.mdx).
// Cases from Rust tests/ui/moves/move-in-guard-1,
// matching-partially-moved-value-17385, moves-based-on-type-match-bindings;
// borrowck/borrowck-move-in-irrefut-pat,
// borrow-of-moved-value-in-for-loop-61108; drop/drop-in-for-loop-destructure.

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

enum Msg {
    Quit,
    Data { t: Tok },
    Pair { a: Tok, b: Tok },
}

fn eat(t: Tok) -> i32 { return t.id }

fn gen(n: i32) -> yield Tok {
    for var i = 1; i <= n; i++ {
        yield Tok(i)
    }
}

fn var_binder_copies_move_only(m: Msg) -> i32 {
    match m {
        case .Data(var t) { return t.id } //! SC182E
        default { return 0 }
    }
}

fn const_binder_reads_in_place(m: Msg) -> i32 {
    match m {
        case .Data(const t) { return t.id }
        default { return 0 }
    }
}

fn nullable_var_binder(o: Tok?) -> i32 {
    match o {
        case null { return 0 }
        case var s { return s.id } //! SC182E
    }
}

fn nullable_const_binder(o: Tok?) -> i32 {
    match o {
        case null { return 0 }
        case const s { return s.id }
    }
}

fn tuple_destructure_moves_tuple() -> i32 {
    var p = (Tok(1), Tok(2))
    var (a, b) = p
    return a.id + b.id + p.0.id //! SC052E
}

fn tuple_destructure_ok() -> i32 {
    var p = (Tok(1), Tok(2))
    var (a, b) = p
    return a.id + b.id
}

fn generator_binder_moved_onward() -> i32 {
    var sum = 0
    for piece in gen(3) {
        sum += eat(piece)
    }
    return sum
}

fn generator_binder_read_after_move() -> i32 {
    var sum = 0
    for piece in gen(3) {
        sum += eat(piece)
        sum += piece.id //! SC052E
    }
    return sum
}

fn generator_binder_is_fresh_each_iteration() -> i32 {
    var sum = 0
    for piece in gen(3) {
        var kept = piece
        sum += kept.id
    }
    return sum
}

fn scrutinee_is_read_in_place(m: Msg) -> i32 {
    var n = 0
    match m {
        case .Pair(const a, const b) { n = a.id + b.id }
        default { n = 1 }
    }
    return n
}

fn scrutinee_not_moved_by_const_match(m: Msg) -> i32 {
    var n = 0
    match m {
        case .Data(const t) { n = t.id }
        default { n = 1 }
    }
    match m {
        case .Quit { n += 100 }
        default { n += 1 }
    }
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: patterns_and_binders.k:34:{{[0-9]+}}: error [SC182E]:
// CHECK: patterns_and_binders.k:49:{{[0-9]+}}: error [SC182E]:
// CHECK: patterns_and_binders.k:63:{{[0-9]+}}: error [SC052E]:
// CHECK: patterns_and_binders.k:84:{{[0-9]+}}: error [SC052E]:
