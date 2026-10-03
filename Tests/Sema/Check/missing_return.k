// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=SC104E --implicit-check-not=SC105E

// ReturnPathCheck: SC104 when a value-returning function can reach its
// closing brace, SC105 when a `-> !` function can. Every `ok_*` function
// must stay silent (--implicit-check-not); every `bad_*` has one error.

enum Color { Red, Green, Blue }

enum Opt { Some { v: i32 }, None }

fn stop() -> ! { loop { } }

// --- straight line ----------------------------------------------------------

fn ok_plain() -> i32 { return 1; }

fn ok_void() { }

fn ok_expr_body() -> i32 = 1

fn bad_empty() -> i32 {
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_empty' does not return a value on all control paths
// CHECK-NEXT: missing_return.k:[[@LINE-3]]:19: note [SC104N]: declared to return 'i32' here

// --- if ---------------------------------------------------------------------

fn ok_if_else(c: bool) -> i32 {
    if c { return 1; } else { return 2; }
}

fn ok_else_if_chain(x: i32) -> i32 {
    if x > 0 { return 1; } else if x < 0 { return -1; } else { return 0; }
}

fn bad_if_no_else(c: bool) -> i32 {
    if c { return 1; }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_if_no_else'

fn bad_else_if_no_else(x: i32) -> i32 {
    if x > 0 { return 1; } else if x < 0 { return -1; }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_else_if_no_else'

fn bad_one_arm_falls(c: bool) -> i32 {
    if c { return 1; } else { }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_one_arm_falls'

// --- divergence -------------------------------------------------------------

fn ok_tail_noreturn_call(c: bool) -> i32 {
    if c { return 1; }
    stop();
}

fn ok_panic_arm(c: bool) panic -> i32 {
    if c { return 1; }
    panic 0;
}

// --- loops ------------------------------------------------------------------

fn ok_infinite_loop() -> i32 {
    loop { }
}

fn ok_loop_inner_break() -> i32 {
    loop {
        while true { break; }
    }
}

fn bad_loop_with_break(c: bool) -> i32 {
    loop { if c { break; } }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_loop_with_break'

fn bad_labeled_break() -> i32 {
    outer: loop {
        loop { break outer; }
    }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_labeled_break'

fn ok_while_true_returns(x: i32) -> i32 {
    while true { if x > 0 { return x; } }
}

fn bad_while_cond(c: bool) -> i32 {
    while c { return 1; }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_while_cond'

// --- match ------------------------------------------------------------------

fn ok_match_default(x: i32) -> i32 {
    match x {
        case 1 { return 10; }
        default { return 0; }
    }
}

fn ok_match_enum_all(c: Color) -> i32 {
    match c {
        case Color::Red   { return 1; }
        case Color::Green { return 2; }
        case Color::Blue  { return 3; }
    }
}

fn ok_match_enum_dotted_commas(c: Color) -> i32 {
    match c {
        case .Red, .Green { return 1; }
        case .Blue        { return 3; }
    }
}

fn ok_match_bool(b: bool) -> i32 {
    match b {
        case true  { return 1; }
        case false { return 0; }
    }
}

fn ok_match_catch_all(x: i32) -> i32 {
    match x {
        case 1     { return 1; }
        case var n { return n; }
    }
}

fn ok_match_adt_irrefutable(o: Opt) -> i32 {
    match o {
        case .Some(var v) { return v; }
        case .None        { return 0; }
    }
}

fn bad_match_enum_missing(c: Color) -> i32 {
    match c {
        case Color::Red   { return 1; }
        case Color::Green { return 2; }
    }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_match_enum_missing'

fn bad_match_int_no_default(x: i32) -> i32 {
    match x {
        case 1 { return 1; }
        case 2 { return 2; }
    }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_match_int_no_default'

fn bad_match_arm_falls(c: Color) -> i32 {
    match c {
        case .Red   { return 1; }
        case .Green { }
        default     { return 3; }
    }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_match_arm_falls'

fn bad_match_guarded(c: Color, k: bool) -> i32 {
    match c {
        case .Red where k { return 1; }
        case .Green       { return 2; }
        case .Blue        { return 3; }
    }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_match_guarded'

fn bad_match_adt_refutable(o: Opt) -> i32 {
    match o {
        case .Some(1) { return 1; }
        case .None    { return 0; }
    }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_match_adt_refutable'

fn bad_partial_match_then_if(c: Color) -> i32 {
    match c {
        case .Red   { return 1; }
        case .Green { return 2; }
    }
    if true { return 3; }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC104E]: 'bad_partial_match_then_if'

// --- `-> !` -----------------------------------------------------------------

fn ok_never_loop() -> ! { loop { } }

fn bad_never(c: bool) -> ! {
    if c { stop(); }
}
// CHECK: missing_return.k:[[@LINE-1]]:1: error [SC105E]: 'bad_never' is declared to never return

// --- operators (their name token is a sentinel; the message must not spell it)

class V {
    var x: i32;
    fn op + (self, o: V) -> V { }
}
// CHECK: missing_return.k:[[@LINE-2]]:{{[0-9]+}}: error [SC104E]: this operator does not return a value on all control paths

// --- generators ---------------------------------------------------------------
// `-> yield T` types each yielded value; falling off the bottom ends the
// sequence, so none of these is a missing return.

fn ok_generator(n: i32) -> yield i32 {
    for var i: i32 = 0; i < n; ++i {
        yield i
    }
}

fn ok_generator_early_return(n: i32) -> yield i32 {
    if n < 0 { return; }
    yield n
}

fn ok_generator_empty() -> yield i32 { }

fn bad_generator_return_value() -> yield i32 {
    yield 1
    return 2
}
// CHECK: missing_return.k:[[@LINE-2]]:5: error [SC001E]: a generator cannot 'return' a value; 'yield' it, or write a bare 'return' to end the sequence
