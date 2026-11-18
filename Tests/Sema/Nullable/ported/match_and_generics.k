// `match` on a nullable: `case null` first, later arms see the value as
// non-null, `case var v` binds the unwrapped `T`, guards refine like an `if`,
// and the state after the match is the merge of the arms that fall through
// (nullables.mdx, Matching a nullable; pattern-matching.mdx, Matching a
// nullable). A nullable of a generic parameter narrows like a concrete one
// (nullables.mdx, Narrowing).
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/
// (controlStructures/when, whenSubjectExpression, returnFromWhen,
// smartCastOnWhen, orInWhenBranch, literalInWhenSubject) and
// nullabilityAndSmartCasts/SenselessNullInWhen.

fn find(k: i32) -> i32? { if k > 0 { return k } return null }
fn flag() -> bool { return true }
fn take(x: i32) -> i32 { return x }

class Node { pub var value: i32 = 1 }

fn ok_null_then_default(x: i32?) -> i32 {
    match x {
        case null { return 0 }
        default { return x + 1 }
    }
}

fn ok_null_value_arm_default(x: i32?) -> i32 {
    var r = 0
    match x {
        case null { r = -1 }
        case 0 { r = x }
        default { r = x * 2 }
    }
    return r
}

fn ok_binding_is_unwrapped(x: i32?) -> i32 {
    match x {
        case null { return 0 }
        case var v { return take(v) }
    }
}

fn ok_binding_with_guard(x: i32?) -> i32 {
    match x {
        case null { return 0 }
        case var v where v > 10 { return v }
        default { return x }
    }
}

fn ok_after_match_all_arms_exit_on_null(x: i32?) -> i32 {
    match x {
        case null { return 0 }
        default { }
    }
    return x + 1
}

fn bad_after_match_null_arm_falls_through(x: i32?) -> i32 {
    var r = 0
    match x {
        case null { r = 1 }
        default { r = 2 }
    }
    return x + r // expect: SC265E
}

fn bad_null_arm_reads_value(x: i32?) -> i32 {
    match x {
        case null { return x + 1 } // expect: SC265E
        default { return 0 }
    }
}

fn ok_guard_on_other_nullable_refines_arm(x: i32?, y: i32?) -> i32 {
    match x {
        case null { return 0 }
        case var v where y? { return v + y }
        default { return x }
    }
}

fn bad_guard_other_nullable_not_refining_default(x: i32?, y: i32?) -> i32 {
    match x {
        case null { return 0 }
        case var v where y? { return v }
        default { return y } // expect: SC265E
    }
}

fn ok_match_on_call_result() -> i32 {
    match find(3) {
        case null { return 0 }
        case var v { return v }
    }
}

fn ok_bool_nullable_exhaustive(b: bool?) -> i32 {
    match b {
        case null { return 0 }
        case true { return 1 }
        case false { return 2 }
    }
}

fn bad_match_without_null_arm(x: i32?) -> i32 {
    match x { // expect: SC254E
        case 0 { return 0 }
        default { return 1 }
    }
}

fn bad_null_arm_not_first(x: i32?) -> i32 {
    match x { // expect: SC254E
        case 0 { return 0 }
        case null { return 1 }
        default { return 2 }
    }
}

fn bad_null_arm_guarded(x: i32?) -> i32 {
    match x { // expect: SC254E
        case null where flag() { return 0 }
        default { return 1 }
    }
}

fn bad_null_arm_in_alternation(x: i32?) -> i32 {
    match x { // expect: SC254E
        case null, 0 { return 0 }
        default { return 1 }
    }
}

fn bad_second_null_arm(x: i32?) -> i32 {
    match x {
        case null { return 0 }
        case 1 { return 1 }
        case null { return 2 } // expect: SC254E
        default { return 3 }
    }
}

fn ok_record_nullable_match(n: Node?) -> i32 {
    match n {
        case null { return 0 }
        default { return n.value }
    }
}

fn bad_record_nullable_member_in_null_arm(n: Node?) -> i32 {
    match n {
        case null { return n.value } // expect: SC265E
        default { return 0 }
    }
}

// generics

fn <T> ok_generic_checked(t: T?, d: T) -> T {
    if t? { return t }
    return d
}

fn <T> ok_generic_early_exit(t: T?, d: T) -> T {
    if t == null { return d }
    return t
}

fn <T> ok_generic_coalesce(t: T?, d: T) -> T {
    return t ?? d
}

fn <T> bad_generic_unchecked(t: T?) -> T {
    return t // expect: SC265E
}

fn <T> ok_generic_unwrap(t: T?) -> T {
    return unwrap!(t)
}

fn <T> bad_generic_after_if(t: T?, d: T) -> T {
    if t? { var u = t }
    return t // expect: SC265E
}

fn <T> ok_generic_match(t: T?, d: T) -> T {
    match t {
        case null { return d }
        default { return t }
    }
}

fn ok_generic_instantiated() -> i32 {
    return ok_generic_checked(find(2), 9) + ok_generic_coalesce(find(0), 3)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='warning ['
// CHECK: match_and_generics.k:64:{{[0-9]+}}: error [SC265E]
// CHECK: match_and_generics.k:69:{{[0-9]+}}: error [SC265E]
// CHECK: match_and_generics.k:86:{{[0-9]+}}: error [SC265E]
// CHECK: match_and_generics.k:106:{{[0-9]+}}: error [SC254E]
// CHECK: match_and_generics.k:113:{{[0-9]+}}: error [SC254E]
// CHECK: match_and_generics.k:121:{{[0-9]+}}: error [SC254E]
// CHECK: match_and_generics.k:128:{{[0-9]+}}: error [SC254E]
// CHECK: match_and_generics.k:138:{{[0-9]+}}: error [SC254E]
// CHECK: match_and_generics.k:152:{{[0-9]+}}: error [SC265E]
// CHECK: match_and_generics.k:174:{{[0-9]+}}: error [SC265E]
// CHECK: match_and_generics.k:183:{{[0-9]+}}: error [SC265E]
