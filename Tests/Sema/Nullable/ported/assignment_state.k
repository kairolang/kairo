// How an assignment sets the nullness state of a local: the variable takes
// the state of the value assigned (a plain value is non-null, `null` is
// null, a call result or a maybe-null place is maybe null, a copy has the
// state of its source), a parameter of type `T?` starts maybe null, a branch
// join takes the weaker state (nullables.mdx, Narrowing, "Assignments set
// the state"; Const interaction).
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/varnotnull/
// (assignment, initialization, varNull, varIntNull, varCheck, unnecessary,
// boundInitializer, ifVarNullReturn) and nullabilityAndSmartCasts/ (kt244,
// kt362, kt1270, kt2146).

fn find(k: i32) -> i32? { if k > 0 { return k } return null }
fn maybe() -> i32? { return 3 }
fn flag() -> bool { return true }
fn take(x: i32) -> i32 { return x }
fn take_opt(x: i32?) -> i32 { if x? { return x } return 0 }

class Box { pub var v: i32 = 1 }
fn mk() -> Box? { return Box() }

fn ok_literal_initialiser() -> i32 {
    var x? = 10
    return x + 1
}

fn ok_declared_type_literal() -> i32 {
    var x: i32? = 5
    return x + 1
}

fn ok_assign_literal_after_null() -> i32 {
    var x: i32? = null
    x = 3
    return x + 1
}

fn bad_assign_null_after_literal() -> i32 {
    var x: i32? = 3
    x = null
    return x + 1 // expect: SC265E
}

fn bad_declared_without_value() -> i32 {
    var x: i32?
    return x + 1 // expect: SC265E
}

fn bad_initialised_null() -> i32 {
    var x: i32? = null
    return x + 1 // expect: SC265E
}

fn bad_assign_call_result() -> i32 {
    var x: i32? = 1
    x = find(2)
    return x + 1 // expect: SC265E
}

fn ok_assign_call_result_then_check() -> i32 {
    var x: i32? = 1
    x = find(2)
    if x? { return x + 1 }
    return 0
}

fn bad_initialiser_call_result() -> i32 {
    var x? = maybe()
    return x + 1 // expect: SC265E
}

fn ok_assign_nonnull_expression() -> i32 {
    var x: i32? = null
    x = 1 + 2
    return x * 2
}

fn ok_assign_coalesce_result() -> i32 {
    var x: i32? = null
    x = find(1) ?? 0
    return x + 1
}

fn bad_assign_coalesce_nullable_rhs() -> i32 {
    var x: i32? = 1
    x = find(1) ?? maybe()
    return x + 1 // expect: SC265E
}

fn ok_copy_of_narrowed_source(a: i32?) -> i32 {
    if !a? { return 0 }
    var x? = a
    return x + 1
}

fn ok_copy_declared_type_of_narrowed_source(a: i32?) -> i32 {
    if !a? { return 0 }
    var x: i32? = a
    return x + 1
}

fn bad_copy_of_maybe_null_source(a: i32?) -> i32 {
    var x? = a
    return x + 1 // expect: SC265E
}

fn bad_copy_of_null_source(a: i32?) -> i32 {
    if a? { return 0 }
    var x? = a
    return x + 1 // expect: SC265E
}

fn ok_assign_narrowed_param_to_local(a: i32?) -> i32 {
    var x: i32? = null
    if a? { x = a }
    return take_opt(x)
}

fn bad_assign_narrowed_in_branch_only(a: i32?) -> i32 {
    var x: i32? = null
    if a? { x = a }
    return x + 1 // expect: SC265E
}

fn ok_assign_in_both_branches(a: i32?) -> i32 {
    var x: i32? = null
    if flag() { x = 1 } else { x = 2 }
    return x + 1
}

fn bad_assign_in_one_branch_only() -> i32 {
    var x: i32? = null
    if flag() { x = 1 }
    return x + 1 // expect: SC265E
}

fn ok_assign_in_one_branch_over_nonnull() -> i32 {
    var x: i32? = 5
    if flag() { x = 1 }
    return x + 1
}

fn bad_assign_null_in_one_branch_over_nonnull() -> i32 {
    var x: i32? = 5
    if flag() { x = null }
    return x + 1 // expect: SC265E
}

fn ok_reassign_to_value_after_check_failed(a: i32?) -> i32 {
    var x? = a
    if x == null { x = 0 }
    return x + 1
}

fn ok_reassign_to_value_in_early_exit_free_path(a: i32?) -> i32 {
    var x? = a
    if !x? { x = 7 }
    return x
}

fn bad_check_then_reassign_null(a: i32?) -> i32 {
    var x? = a
    if x? {
        x = null
        return x + 1 // expect: SC265E
    }
    return 0
}

fn bad_check_then_reassign_call(a: i32?) -> i32 {
    var x? = a
    if x? {
        x = find(x)
        return x + 1 // expect: SC265E
    }
    return 0
}

fn ok_check_then_reassign_nonnull(a: i32?) -> i32 {
    var x? = a
    if x? {
        x = x + 1
        return x
    }
    return 0
}

fn ok_param_reassigned_nonnull(a: i32?) -> i32 {
    a = 4
    return a + 1
}

fn bad_param_starts_maybe_null(a: i32?) -> i32 {
    return a + 1 // expect: SC265E
}

fn ok_pointer_address_is_nonnull() -> i32 {
    var k = 7
    var p: (*i32)? = &k
    return *p
}

fn bad_pointer_assigned_null_call(q: (*i32)?) -> i32 {
    var k = 7
    var p: (*i32)? = &k
    p = q
    return *p // expect: SC265E
}

fn ok_pointer_reassigned_address(q: (*i32)?) -> i32 {
    var k = 7
    var p: (*i32)? = q
    p = &k
    return *p
}

fn ok_record_literal_initialiser() -> i32 {
    var b: Box? = Box()
    return b.v
}

fn bad_record_from_call() -> i32 {
    var b: Box? = mk()
    return b.v // expect: SC265E
}

fn ok_record_from_call_checked() -> i32 {
    var b? = mk()
    if b? { return b.v }
    return 0
}

fn ok_state_does_not_leak_between_locals(a: i32?) -> i32 {
    var x? = a
    var y: i32? = 3
    if x? { return y + x }
    return y
}

fn bad_second_local_unchecked(a: i32?, b: i32?) -> i32 {
    var x? = a
    var y? = b
    if x? { return y + x } // expect: SC265E
    return 0
}

fn ok_shadowed_local_has_own_state(a: i32?) -> i32 {
    if !a? { return 0 }
    {
        var a: Box? = null
        if a? { return a.v }
    }
    return a
}

fn bad_shadowed_local_unchecked(a: i32?) -> i32 {
    if !a? { return 0 }
    {
        var a: Box? = null
        return a.v // expect: SC265E
    }
}

fn ok_state_after_block_scope(a: i32?) -> i32 {
    if !a? { return 0 }
    { var t = a + 1 }
    return a
}

fn ok_const_nullable_checked() -> i32 {
    const x: i32? = 42
    if x? { return x }
    return 0
}

fn ok_const_nullable_initialised_nonnull() -> i32 {
    const x: i32? = 42
    return x + 1
}

fn bad_const_nullable_null() -> i32 {
    const x: i32? = null
    return x + 1 // expect: SC265E
}

fn bad_const_nullable_assign() {
    const x: i32? = 42
    x = null // expect: SC071E
}

fn ok_var_nullable_assign_back_and_forth() -> i32 {
    var y: i32? = null
    y = 42
    y = null
    y = 9
    return y + 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='warning ['
// CHECK: assignment_state.k:40:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:45:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:50:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:56:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:68:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:86:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:103:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:109:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:121:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:133:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:145:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:164:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:173:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:193:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:206:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:223:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:242:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:259:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:282:{{[0-9]+}}: error [SC265E]
// CHECK: assignment_state.k:287:{{[0-9]+}}: error [SC071E]
