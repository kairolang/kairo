// The type of the nullable operators and the forms that are errors: `??`
// yields `T` (or `T?` when its right side is nullable) and chains to the
// right, `?.` yields the member's type made nullable and never wraps twice,
// `unwrap!` yields `T` and leaves the place known non-null, `===` narrows
// both sides of a true result, and a `T?` never converts to `T` implicitly
// or by cast (nullables.mdx: Nullable Types, Shorthand declaration, Safe
// access, Null coalescing, Null-aware equality, Force unwrap; casting.mdx,
// Nullable to Non-Nullable).
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/elvis/,
// smartCasts/elvisExprNotNull, smartCasts/longElvisChain,
// smartCasts/safecalls/ (safeCallIsAlwaysNullable, chainAndUse, receiver),
// smartCasts/bangbang, nullabilityAndSmartCasts/ (AssertNotNull,
// dataFlowInfoAfterExclExcl, equalityUnderNotNullCheck) and nullableTypes/
// (uselessElvis, safeCallOperators).

class Net { pub var port: i32 = 80; pub fn Net(self) { } }
class Config {
    pub var timeout: i32 = 30
    pub var retries: i32? = null
    pub var net: Net? = null
    pub fn Config(self) { }
    pub fn save(self, k: i32) -> bool { return true }
    pub fn close(self) { }
}

fn find(k: i32) -> i32? { if k > 0 { return k } return null }
fn load() -> Config? { return Config() }
fn take(x: i32) -> i32 { return x }
fn take_opt(x: i32?) -> i32 { return 0 }
fn fallback() -> i32? { return 1 }

// `??` types

fn ok_coalesce_literal(a: i32?) -> i32 {
    var v: i32 = a ?? 0
    return v
}

fn ok_coalesce_infers_nonnull(a: i32?) -> i32 {
    var v = a ?? 0
    return take(v)
}

fn ok_coalesce_call_lhs() -> i32 {
    var v: i32 = find(1) ?? 7
    return v
}

fn ok_coalesce_chain(a: i32?, b: i32?) -> i32 {
    var v: i32 = a ?? b ?? 80
    return v
}

fn ok_coalesce_nullable_rhs(a: i32?, b: i32?) -> i32? {
    var v: i32? = a ?? b
    return v
}

fn ok_coalesce_nullable_rhs_inferred(a: i32?) -> i32 {
    var v? = a ?? fallback()
    return take_opt(v)
}

fn bad_coalesce_nullable_rhs_to_value(a: i32?, b: i32?) -> i32 {
    var v: i32 = a ?? b // expect: SC028E
    return v
}

fn bad_coalesce_chain_all_nullable(a: i32?, b: i32?, c: i32?) -> i32 {
    var v: i32 = a ?? b ?? c // expect: SC028E
    return v
}

fn ok_coalesce_rhs_not_evaluated_state(a: i32?) -> i32 {
    return a ?? 0
}

fn ok_coalesce_uses_narrowing_in_rhs(a: i32?, b: i32?) -> i32 {
    if !a? { return b ?? 0 }
    return a ?? 0
}

fn ok_coalesce_unchecked_lhs_is_fine(a: i32?) -> i32 {
    var s = a ?? 1
    var t = a ?? 2
    return s + t
}

fn bad_coalesce_rhs_reads_unchecked(a: i32?, b: i32?) -> i32 {
    return a ?? b + 1 // expect: SC265E
}

fn bad_coalesce_rhs_type_differs(a: i32?, b: bool) -> i32 {
    var v = a ?? b // expect: SC033E
    return 0
}

fn bad_value_from_nullable_declared(a: i32?) -> i32 {
    var v: i32 = a // expect: SC265E
    return v
}

fn ok_value_to_nullable_param() -> i32 {
    return take_opt(3)
}

fn ok_null_to_nullable_param() -> i32 {
    return take_opt(null)
}

fn bad_null_to_value_param() -> i32 {
    return take(null) // expect: SC063E
}

fn bad_null_to_value_local() -> i32 {
    var v: i32 = null // expect: SC076E
    return v
}

// `?.` types

fn ok_safe_member_is_nullable(c: Config?) -> i32? {
    var t: i32? = c?.timeout
    return t
}

fn bad_safe_member_to_value(c: Config?) -> i32 {
    var t: i32 = c?.timeout // expect: SC028E
    return t
}

fn ok_safe_member_coalesced(c: Config?) -> i32 {
    var t: i32 = c?.timeout ?? 30
    return t
}

fn ok_safe_member_nullable_member_not_wrapped(c: Config?) -> i32? {
    var r: i32? = c?.retries
    return r
}

fn ok_safe_call(c: Config?) -> bool? {
    var ok: bool? = c?.save(1)
    return ok
}

fn ok_safe_call_statement(c: Config?) {
    c?.close()
}

fn ok_safe_chain(c: Config?) -> i32? {
    var r: i32? = c?.net?.port
    return r
}

fn bad_safe_chain_second_step_missing(c: Config?) -> i32? {
    return c?.net.port // expect: R025E
}

fn bad_safe_assign(c: Config?) {
    c?.timeout = 5 // expect: SC071E
}

fn bad_safe_on_nonnull(c: Config) -> i32? {
    return c?.timeout // expect: SC260E
}

fn ok_safe_access_leaves_check_state(c: Config?) -> i32 {
    var t? = c?.timeout
    if c? { return c.timeout }
    return 0
}

fn bad_safe_access_does_not_narrow(c: Config?) -> i32 {
    var t? = c?.timeout
    return c.timeout // expect: SC265E
}

fn ok_dot_in_checked_branch_of_safe_call(c: Config?) -> i32 {
    var t = if c? => c.timeout else => 0
    return t
}

// unwrap!

fn ok_unwrap_value(a: i32?) -> i32 {
    var v: i32 = unwrap!(a)
    return v
}

fn ok_unwrap_narrows_the_place(a: i32?) -> i32 {
    var v = unwrap!(a)
    return a + v
}

fn ok_unwrap_call_result() -> i32 {
    return unwrap!(find(2)) + 1
}

fn ok_unwrap_field_is_the_field(c: Config) {
    unwrap!(c.retries) = 5
}

fn bad_unwrap_on_nonnull_value(n: i32) -> i32 {
    return unwrap!(n) // expect: SC260E
}

fn bad_unwrap_does_not_narrow_before(a: i32?) -> i32 {
    var x = a + 1 // expect: SC265E
    var v = unwrap!(a)
    return v
}

fn ok_unwrap_in_condition_arm(a: i32?) -> i32 {
    if a == null { return 0 }
    return unwrap!(a)
}

fn ok_unwrap_pointer(p: (*i32)?) -> i32 {
    var *q = unwrap!(p)
    return *q
}

// casts

fn bad_cast_nullable_to_value(a: i32?) -> i32 {
    return a as i32 // expect: SC029E
}

// declarations

fn bad_shorthand_null_has_no_type() {
    var x? = null // expect: SC076E
}

fn ok_shorthand_from_nullable_call() -> i32 {
    var n? = find(1)
    return take_opt(n)
}

fn warn_inferred_nullable_without_question() -> i32 {
    var n = find(1) // expect-warning: SC226W
    return take_opt(n)
}

fn bad_bare_null_to_raw_pointer() {
    var p: unsafe *i32 = null // expect: SC076E
}

fn bad_null_to_safe_pointer() {
    var p: *i32 = &null // expect: SC259E
}

fn ok_raw_pointer_null_spelled_address() -> bool {
    var raw: unsafe *i32 = &null
    return raw == &null
}

// null-aware equality

fn ok_triple_eq_narrows_both(a: i32?, b: i32?) -> i32 {
    if a === b { return a + b }
    return 0
}

fn ok_triple_eq_literal(a: i32?) -> bool {
    return a === 5
}

fn ok_triple_eq_then_use_single(a: i32?) -> i32 {
    if a === 5 { return a }
    return 0
}

fn bad_triple_eq_false_branch_does_not_narrow(a: i32?, b: i32?) -> i32 {
    if a === b { return 0 } else { return a + 1 } // expect: SC265E
}

fn bad_triple_eq_null(a: i32?) -> bool {
    return a === null // expect: SC264E
}

fn bad_triple_eq_no_nullable(a: i32, b: i32) -> bool {
    return a === b // expect: SC034E
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='warning ['
// CHECK: expressions.k:65:{{[0-9]+}}: error [SC028E]
// CHECK: expressions.k:70:{{[0-9]+}}: error [SC028E]
// CHECK: expressions.k:90:{{[0-9]+}}: error [SC265E]
// CHECK: expressions.k:94:{{[0-9]+}}: error [SC033E]
// CHECK: expressions.k:99:{{[0-9]+}}: error [SC265E]
// CHECK: expressions.k:112:{{[0-9]+}}: error [SC063E]
// CHECK: expressions.k:116:{{[0-9]+}}: error [SC076E]
// CHECK: expressions.k:128:{{[0-9]+}}: error [SC028E]
// CHECK: expressions.k:157:{{[0-9]+}}: error [R025E]
// CHECK: expressions.k:161:{{[0-9]+}}: error [SC071E]
// CHECK: expressions.k:165:{{[0-9]+}}: error [SC260E]
// CHECK: expressions.k:176:{{[0-9]+}}: error [SC265E]
// CHECK: expressions.k:205:{{[0-9]+}}: error [SC260E]
// CHECK: expressions.k:209:{{[0-9]+}}: error [SC265E]
// CHECK: expressions.k:227:{{[0-9]+}}: error [SC029E]
// CHECK: expressions.k:233:{{[0-9]+}}: error [SC076E]
// CHECK: expressions.k:242:{{[0-9]+}}: warning [SC226W]
// CHECK: expressions.k:247:{{[0-9]+}}: error [SC076E]
// CHECK: expressions.k:251:{{[0-9]+}}: error [SC259E]
// CHECK: expressions.k:276:{{[0-9]+}}: error [SC265E]
// CHECK: expressions.k:280:{{[0-9]+}}: error [SC264E]
// CHECK: expressions.k:284:{{[0-9]+}}: error [SC034E]
