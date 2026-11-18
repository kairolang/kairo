// Narrowing across loops: `while` conditions refine the body and the code
// after the loop, a variable assigned in the loop is maybe null again at the
// loop head, `break` and `continue` carry the state at their point, and a
// `for` body starts from the state before the loop less what the body can
// make maybe null (nullables.mdx, Narrowing, "Loops").
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/loops/
// (whileNull, whileSimple, whileTrue, whileNullWithBreak, nestedLoops,
// whileTrueBreakReturn, forLoopWithAssignment) and smartCasts/varnotnull/
// (varChangedInLoop, varNotChangedInLoop, whileTrue, infiniteWhileWithBreak,
// nestedWhile, forEach, forEachWithBreak, forEachWithContinue, iterations).

fn find(k: i32) -> i32? { if k > 0 { return k } return null }
fn next(x: i32) -> i32? { if x > 1 { return x - 1 } return null }
fn flag() -> bool { return true }
fn take(x: i32) -> i32 { return x }

fn ok_while_condition_body(a: i32?) -> i32 {
    var r = 0
    var x? = a
    while x? {
        r += x
        x = next(x)
    }
    return r
}

fn ok_while_condition_neq(a: i32?) -> i32 {
    var r = 0
    var x? = a
    while x != null {
        r += x
        x = next(x)
    }
    return r
}

fn ok_while_condition_retests_after_null_assignment(a: i32?) -> i32 {
    var x? = a
    var r = 0
    while x? {
        r += x
        x = null
    }
    return r
}

fn ok_while_condition_and(a: i32?, b: i32?) -> i32 {
    var r = 0
    while a? && b? {
        r += a + b
        if flag() { break }
    }
    return r
}

fn bad_while_condition_does_not_cover_other(a: i32?, b: i32?) -> i32 {
    var r = 0
    while a? {
        r += b // expect: SC265E
        if flag() { break }
    }
    return r
}

fn ok_after_while_is_condition_false_case(a: i32?) -> i32 {
    var x? = a
    while x == null {
        x = find(1)
    }
    return x + 1
}

fn ok_after_while_null_test_negated(a: i32?) -> i32 {
    var x? = a
    while !x? {
        x = find(2)
    }
    return x
}

fn bad_after_while_nonnull_test(a: i32?) -> i32 {
    var x? = a
    while x? {
        x = next(x)
    }
    return x + 1 // expect: SC265E
}

fn bad_after_while_with_break_merges(a: i32?) -> i32 {
    var x? = a
    while x == null {
        if flag() { break }
        x = find(1)
    }
    return x + 1 // expect: SC265E
}

fn ok_after_while_break_when_nonnull(a: i32?) -> i32 {
    var x? = a
    while x == null {
        x = find(1)
        if x? { break }
    }
    return x + 1
}

fn bad_loop_assigns_maybe_null_at_head(a: i32?) -> i32 {
    var r = 0
    var x? = a
    if x? {
        while flag() {
            r += x // expect: SC265E
            x = next(r)
        }
    }
    return r
}

fn ok_loop_not_assigned_keeps_state(a: i32?) -> i32 {
    var r = 0
    if a? {
        while flag() {
            r += a
            if r > 10 { break }
        }
    }
    return r
}

fn ok_loop_assigned_nonnull_keeps_state(a: i32?) -> i32 {
    var r = 0
    var x? = 1
    while flag() {
        r += x
        x = r + 1
        if r > 10 { break }
    }
    return r
}

fn bad_loop_assigned_null_later_in_body(a: i32?) -> i32 {
    var r = 0
    var x? = 1
    while flag() {
        r += x // expect: SC265E
        x = null
        if r > 10 { break }
    }
    return r
}

fn bad_loop_assigned_maybe_null_in_branch(a: i32?) -> i32 {
    var r = 0
    var x? = 1
    while flag() {
        r += x // expect: SC265E
        if r > 3 { x = find(r) }
        if r > 10 { break }
    }
    return r
}

fn ok_loop_check_then_assign_inside(a: i32?) -> i32 {
    var r = 0
    var x? = a
    while flag() {
        if x? { r += x }
        x = find(r)
        if r > 10 { break }
    }
    return r
}

fn ok_loop_early_continue_on_null(a: i32?) -> i32 {
    var r = 0
    var x? = a
    while flag() {
        x = find(r)
        if !x? { continue }
        r += x
        if r > 10 { break }
    }
    return r
}

fn ok_loop_early_break_on_null(a: i32?) -> i32 {
    var r = 0
    var x? = a
    while flag() {
        x = find(r)
        if x == null { break }
        r += x
    }
    return r
}

fn ok_loop_early_return_on_null(a: i32?) -> i32 {
    var r = 0
    var x? = a
    while flag() {
        x = find(r)
        if x == null { return r }
        r += x
        if r > 10 { break }
    }
    return r
}

fn bad_loop_continue_before_check(a: i32?) -> i32 {
    var r = 0
    var x? = a
    while flag() {
        x = find(r)
        if flag() { continue }
        r += x // expect: SC265E
        if r > 10 { break }
    }
    return r
}

fn ok_loop_infinite_with_break_nonnull() -> i32 {
    var x: i32? = null
    loop {
        x = find(3)
        if x? { break }
    }
    return x + 1
}

fn bad_loop_infinite_break_may_be_null() -> i32 {
    var x: i32? = null
    loop {
        if flag() { break }
        x = find(3)
    }
    return x + 1 // expect: SC265E
}

fn ok_loop_breaks_all_nonnull(a: i32?) -> i32 {
    var x: i32? = null
    loop {
        if flag() { x = 1; break }
        x = 2
        break
    }
    return x + 1
}

fn bad_loop_one_break_null(a: i32?) -> i32 {
    var x: i32? = null
    loop {
        if flag() { x = 1; break }
        x = null
        break
    }
    return x + 1 // expect: SC265E
}

fn ok_for_body_keeps_state(a: i32?) -> i32 {
    var r = 0
    if a? {
        for k in 0..3 {
            r += a + k
        }
    }
    return r
}

fn bad_for_body_assigned_null(a: i32?) -> i32 {
    var r = 0
    var x? = 1
    for k in 0..3 {
        r += x + k // expect: SC265E
        x = null
    }
    return r
}

fn ok_for_body_assigned_nonnull(a: i32?) -> i32 {
    var r = 0
    var x? = 1
    for k in 0..3 {
        r += x + k
        x = k
    }
    return r
}

fn bad_for_body_assigned_maybe_null(a: i32?) -> i32 {
    var r = 0
    var x? = 1
    for k in 0..3 {
        r += x // expect: SC265E
        x = find(k)
    }
    return r
}

fn bad_for_does_not_test_unchecked(a: i32?) -> i32 {
    var r = 0
    for k in 0..3 {
        r += a + k // expect: SC265E
    }
    return r
}

fn ok_for_local_checked_each_iteration() -> i32 {
    var r = 0
    for k in 0..4 {
        var e? = find(k)
        if !e? { continue }
        r += e
    }
    return r
}

fn bad_for_after_loop_loses_nothing_but_loop_assigned(a: i32?) -> i32 {
    var x? = 1
    for k in 0..3 {
        x = find(k)
    }
    return x + 1 // expect: SC265E
}

fn ok_for_after_loop_not_assigned(a: i32?) -> i32 {
    if !a? { return 0 }
    var r = 0
    for k in 0..3 { r += k }
    return r + a
}

fn ok_nested_loops_outer_check(a: i32?) -> i32 {
    var r = 0
    if a? {
        for i in 0..3 {
            for j in 0..3 {
                r += a + i + j
            }
        }
    }
    return r
}

fn bad_nested_loops_inner_assigns(a: i32?) -> i32 {
    var r = 0
    var x? = a
    if x? {
        for i in 0..3 {
            r += x // expect: SC265E
            for j in 0..3 {
                x = find(j)
            }
        }
    }
    return r
}

fn ok_nested_while_inner_condition(a: i32?, b: i32?) -> i32 {
    var r = 0
    var x? = a
    while x? {
        var y? = b
        while y? {
            r += x + y
            y = next(y)
        }
        x = next(x)
    }
    return r
}

fn ok_break_after_check_in_nested(a: i32?) -> i32 {
    var r = 0
    for i in 0..5 {
        if !a? { break }
        r += a + i
    }
    return r
}

fn ok_continue_in_inner_does_not_leak(a: i32?) -> i32 {
    var r = 0
    var x? = a
    while x? {
        for k in 0..2 {
            if k == 0 { continue }
            r += x
        }
        x = next(x)
    }
    return r
}

fn ok_assign_after_loop_resets(a: i32?) -> i32 {
    var x? = a
    while x? { x = next(x) }
    x = 5
    return x + 1
}

fn ok_while_true_return_in_body(a: i32?) -> i32 {
    var x? = a
    while true {
        if x? { return x }
        x = find(1)
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='warning ['
// CHECK: loop_narrowing.k:59:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:86:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:95:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:112:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:145:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:156:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:215:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:236:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:256:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:273:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:293:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:302:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:322:{{[0-9]+}}: error [SC265E]
// CHECK: loop_narrowing.k:349:{{[0-9]+}}: error [SC265E]
