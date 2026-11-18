// Narrowing by an `if` over a null test: which state a nullable local has in
// the then-branch, the else-branch and after the statement, for every
// spelling of the test, with early exits and with conditions joined by `&&`,
// `||` and `!` (nullables.mdx, Narrowing, "Conditions refine the state").
// A read of a maybe-null or known-null nullable is SC265E; `ok_*` functions
// compile without a diagnostic, `bad_*` functions carry one marked line each.
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/varnotnull/
// (ifVarNotNull, ifVarNotNullAnd, ifVarNullElse, ifVarNullReturn) and
// smartCasts/controlStructures/ (simpleIf, returns, elvis), and from
// nullabilityAndSmartCasts/.

fn find(k: i32) -> i32? { if k > 0 { return k } return null }
fn stop() -> ! { while true { } }
fn take(x: i32) -> i32 { return x }
fn flag() -> bool { return true }

fn ok_then_branch(a: i32?) -> i32 {
    if a != null { return a + 1 }
    return 0
}

fn ok_question_form(a: i32?) -> i32 {
    if a? { return a * 2 }
    return 0
}

fn ok_null_on_left(a: i32?) -> i32 {
    if null != a { return a - 1 }
    return 0
}

fn ok_eq_null_else(a: i32?) -> i32 {
    if a == null { return 0 } else { return a + 1 }
}

fn ok_null_eq_else(a: i32?) -> i32 {
    if null == a { return 0 } else { return a + 1 }
}

fn ok_not_question_else(a: i32?) -> i32 {
    if !a? { return 0 } else { return a + 1 }
}

fn ok_not_group(a: i32?) -> i32 {
    if !(a == null) { return a + 1 }
    return 0
}

fn ok_not_not(a: i32?) -> i32 {
    if !!a? { return a + 1 }
    return 0
}

fn ok_not_group_eq_else(a: i32?) -> i32 {
    if !(a != null) { return 0 } else { return a + 1 }
}

fn bad_after_if(a: i32?) -> i32 {
    if a != null { take(a) }
    return a + 1 // expect: SC265E
}

fn bad_after_if_else_empty(a: i32?) -> i32 {
    if a? { take(a) } else { }
    return take(a) // expect: SC265E
}

fn bad_else_of_nonnull_test(a: i32?) -> i32 {
    if a != null { return 0 } else { return a + 1 } // expect: SC265E
}

fn bad_then_of_null_test(a: i32?) -> i32 {
    if a == null { return a + 1 } // expect: SC265E
    return 0
}

fn ok_after_return_on_null(a: i32?) -> i32 {
    if a == null { return 0 }
    return a + 1
}

fn ok_after_return_on_not_question(a: i32?) -> i32 {
    if !a? { return 0 }
    var u = a + 1
    return u + take(a)
}

fn ok_after_return_on_eq_null_left(a: i32?) -> i32 {
    if null == a { return 0 }
    return a + 1
}

fn ok_after_noreturn_call(a: i32?) -> i32 {
    if a == null { stop() }
    return a + 1
}

fn ok_early_exit_in_else(a: i32?) -> i32 {
    if a? { } else { return 0 }
    return a + 1
}

fn ok_early_exit_nested(a: i32?, b: i32?) -> i32 {
    if a? {
        if b? { return a + b }
        return a
    }
    return 0
}

fn bad_early_exit_only_in_inner(a: i32?, b: i32?) -> i32 {
    if a == null {
        if b? { return 1 }
    }
    return a + 1 // expect: SC265E
}

fn bad_early_exit_conditional(a: i32?) -> i32 {
    if a == null {
        if flag() { return 0 }
    }
    return a + 1 // expect: SC265E
}

fn ok_both_branches_exit(a: i32?) -> i32 {
    if a? { return a } else { return 0 }
}

fn bad_exit_on_wrong_side(a: i32?) -> i32 {
    if a? { return 0 }
    return a + 1 // expect: SC265E
}

fn ok_known_null_branch_without_read(a: i32?) -> i32 {
    if a == null {
        var n: i32? = a
        if n? { return 1 }
        return 0
    }
    return a
}

fn bad_known_null_read(a: i32?) -> i32 {
    if !a? { return a } // expect: SC265E
    return 0
}

fn ok_and(a: i32?, b: i32?) -> i32 {
    if a? && b? { return a + b }
    return 0
}

fn ok_and_rhs_uses_lhs(a: i32?) -> bool {
    return a? && a > 0
}

fn ok_and_chain3(a: i32?, b: i32?, c: i32?) -> i32 {
    if a? && b? && c? { return a + b + c }
    return 0
}

fn ok_and_then_neq(a: i32?, b: i32?) -> i32 {
    if a != null && b != null { return a + b }
    return 0
}

fn bad_and_other_operand(a: i32?, b: i32?) -> i32 {
    if a? && flag() { return a + b } // expect: SC265E
    return 0
}

fn bad_and_lhs_not_narrowed_by_rhs(a: i32?, b: i32?) -> bool {
    return b > 0 && a? // expect: SC265E
}

fn ok_or_not(a: i32?) -> bool {
    return !a? || a > 0
}

fn ok_or_eq_null(a: i32?) -> bool {
    return a == null || a > 0
}

fn ok_or_else_branch(a: i32?, b: i32?) -> i32 {
    if a == null || b == null { return 0 } else { return a + b }
}

fn ok_or_early_exit(a: i32?, b: i32?) -> i32 {
    if !a? || !b? { return 0 }
    return a + b
}

fn bad_or_rhs_on_true_path(a: i32?) -> bool {
    return a? || a > 0 // expect: SC265E
}

fn bad_or_then_branch(a: i32?, b: i32?) -> i32 {
    if a? || b? { return a + b } // expect: SC265E
    return 0
}

fn bad_precedence_trap(a: i32?) -> bool {
    return a? && a > 0 || a < 0 // expect: SC265E
}

fn ok_precedence_fixed(a: i32?) -> bool {
    return a? && (a > 0 || a < 0)
}

fn bad_not_and_then(a: i32?, b: i32?) -> i32 {
    if !(a? && b?) { return a + b } // expect: SC265E
    return 0
}

fn ok_not_and_early_exit(a: i32?, b: i32?) -> i32 {
    if !(a? && b?) { return 0 }
    return a + b
}

fn ok_not_or_else(a: i32?, b: i32?) -> i32 {
    if !(a == null || b == null) { return a + b }
    return 0
}

fn bad_not_or_early(a: i32?, b: i32?) -> i32 {
    if a? || b? { return 0 }
    return a + b // expect: SC265E
}

fn ok_both_null_exit(a: i32?, b: i32?) -> i32 {
    if a == null && b == null { return 0 }
    var r = 0
    if a? { r += a }
    if b? { r += b }
    return r
}

fn bad_one_null_exit(a: i32?, b: i32?) -> i32 {
    if a == null && b == null { return 0 }
    return a + b // expect: SC265E
}

fn ok_value_form_if(a: i32?) -> i32 {
    return if a? => a else => 0
}

fn ok_value_form_if_null_test(a: i32?) -> i32 {
    return if a == null => 0 else => a
}

fn ok_nested_in_condition(a: i32?) -> i32 {
    if (if a? => a else => 0) > 0 { return 1 }
    return 0
}

fn ok_else_if_chain(a: i32?, b: i32?) -> i32 {
    if a == null { return 0 } else if b == null { return a } else { return a + b }
}

fn bad_else_if_chain(a: i32?, b: i32?) -> i32 {
    if a == null { return 0 } else if b? { return a + b } else { return b } // expect: SC265E
}

fn ok_join_both_nonnull(a: i32?) -> i32 {
    var x: i32? = null
    if a? { x = a } else { x = 1 }
    return x + 1
}

fn bad_join_nonnull_and_null(a: i32?) -> i32 {
    var x: i32? = 0
    if a? { x = 1 } else { x = null }
    return x + 1 // expect: SC265E
}

fn ok_test_inside_condition_arg(a: i32?) -> i32 {
    if a? && take(a) > 0 { return 1 }
    return 0
}

fn ok_comparison_both_sides(a: i32?, b: i32?) -> bool {
    if a != null && b != null && a == b { return true }
    return false
}

fn ok_test_param_by_name_shadow(a: i32?) -> i32 {
    if a? {
        var a = 5
        return a
    }
    return 0
}

fn ok_nested_if_then_then(a: i32?) -> i32 {
    if a? {
        if a > 0 { return a }
        if flag() { return a + 1 }
        return a
    }
    return 0
}

fn ok_local_from_call(k: i32) -> i32 {
    var x? = find(k)
    if x? { return x }
    return -1
}

fn bad_local_from_call(k: i32) -> i32 {
    var x? = find(k)
    return x + 1 // expect: SC265E
}

fn ok_local_initialised_nonnull() -> i32 {
    var x? = 10
    return x + 1
}

fn ok_two_variables_independent(a: i32?, b: i32?) -> i32 {
    if a? {
        if b == null { return a }
        return a + b
    }
    return 0
}

fn bad_other_variable_not_narrowed(a: i32?, b: i32?) -> i32 {
    if a? { return b + 1 } // expect: SC265E
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='warning ['
// CHECK: if_narrowing.k:60:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:65:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:69:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:73:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:115:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:122:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:131:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:144:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:168:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:173:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:194:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:198:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:203:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:211:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:227:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:240:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:261:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:273:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:311:{{[0-9]+}}: error [SC265E]
// CHECK: if_narrowing.k:328:{{[0-9]+}}: error [SC265E]
