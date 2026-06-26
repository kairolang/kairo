// ==========================================================================
//  closures_mixed_stress.k
//  Interleaved valid, invalid, and pathological cases.
//  Tests parser recovery: valid code after each error must parse correctly.
//  Annotations mark whether each declaration is expected to succeed or fail.
// ==========================================================================


// ---- VALID: baseline before any errors ----------------------------------

var v1_basic = fn (a: i32, b: i32) -> i32 { return a + b }         // ok
var v1_expr = fn (x: i32) -> i32 = x * 2                           // ok


// ---- ERROR: prohibited modifier -----------------------------------------

var e1_const = fn () const { return 1 }     // expected-error: 'const' not allowed


// ---- VALID: recovery check, must parse cleanly after e1 ----------------

var v2_after_const = fn (x: i32) -> i32 { return x + 1 }           // ok
var v2_count = 0
var v2_ptr_capture = fn ()|*v2_count| { *v2_count += 1 }           // ok


// ---- ERROR: broken parameter list (missing type) ------------------------

var e2_broken_param = fn (x: i32, y: ) |*v2_count| {   // expected-error: expected type
    return 0
}


// ---- VALID: recovery check ----------------------------------------------

var v3_mixed_cap_a = 10
var v3_mixed_cap_b = 20
var v3_mixed = fn (x: i32)|v3_mixed_cap_a, *v3_mixed_cap_b| -> i32 {   // ok
    *v3_mixed_cap_b += 1
    return x + v3_mixed_cap_a + *v3_mixed_cap_b
}


// ---- ERROR: unclosed paren syncing to capture list ----------------------

var e3_unclosed = fn (x: i32 |*v3_mixed_cap_a| {   // expected-error: expected ')'
    return *v3_mixed_cap_a
}


// ---- VALID: generic closure ---------------------------------------------

var v4_generic = fn <T>(x: T) -> T { return x }                    // ok


// ---- ERROR: multiple prohibited modifiers on one closure ----------------

var e4_multi_bad = fn () const unsafe virtual { return 0 }
// expected-error: 'const' not allowed
// expected-error: 'unsafe' not allowed
// expected-error: 'virtual' not allowed


// ---- VALID: valid modifiers right after bad ones, proves recovery ------

var v5_panic = fn () panic -> i32 { return 42 }                    // ok
var v5_volatile = fn () volatile {}                                 // ok
var v5_async = fn () async {}                                       // ok
var v5_all_valid = fn () volatile async panic -> i32 { return 0 }   // ok


// ---- ERROR: trailing comma in capture list ------------------------------

var e5_trailing = fn ()|*v3_mixed_cap_a, | {    // expected-error: expected name or '*'
    return 0
}


// ---- VALID: const pointer captures right after capture-list error -------

var v6_ka = 10
var v6_kb = 20
var v6_const_cap = fn (a: i32)|const *v6_ka, const *v6_kb| -> i32 {    // ok
    return a + *v6_ka + *v6_kb
}


// ---- ERROR: const capture missing identifier ----------------------------

var e6_const_missing = fn ()|const * , *v6_kb| {    // expected-error: expected identifier
    return 0
}


// ---- VALID: empty capture list ------------------------------------------

var v7_empty_cap = fn ()|| { return 42 }                            // ok


// ---- ERROR: expression body with nothing after '=' ----------------------

var e7_empty_expr = fn () =             // expected-error: expected expression
var v8_recovery = 5                     // ok, must parse as VarDecl, not get swallowed


// ---- ERROR: expression body recovery inside a function ------------------

fn test_stmt_recovery() {
    var e8_broken = fn () =             // expected-error: expected expression
    return                              // ok, return must not be swallowed
}


// ---- VALID: nested closures (expression body chains) --------------------

var v9_nested = fn () = fn (x: i32) -> i32 = x * 2                 // ok

var v9_nested_block = fn () -> fn(i32) -> i32 {                     // ok
    return fn (x: i32) -> i32 { return x + 1 }
}


// ---- ERROR: AMT, escaping pointer capture of stack local ---------------

fn e9_escape() -> fn() -> i32 {
    var local = 42
    return fn ()|*local| -> i32 { return *local }
    // expected-error: closure captures stack local by pointer and escapes scope
}


// ---- VALID: escaping copy capture, safe --------------------------------

fn v10_safe_escape() -> fn() -> i32 {                               // ok
    var local = 42
    return fn () -> i32 { return local }
}


// ---- ERROR: inner function trying to capture ----------------------------

fn e10_inner_capture() {
    var x = 10
    fn inner(y: i32) -> i32 = y + x    // expected-error: 'x' not in scope
}


// ---- VALID: inner function without capture, final recovery check -------

fn v11_inner_clean() -> i32 {                                       // ok
    var x = 10
    fn inner(y: i32) -> i32 = y + 1
    return inner(x)
}


// ---- ERROR: duplicate capture names -------------------------------------

var dup_a = 1
var e11_dup = fn ()|dup_a, dup_a| {     // expected-error: duplicate capture
    return dup_a
}


// ---- ERROR: same variable captured by copy and pointer ------------------

var dup_b = 1
var e12_dup_mixed = fn ()|dup_b, *dup_b| {  // expected-error: duplicate capture
    return dup_b
}


// ---- VALID: higher-order, closures as arguments ------------------------

fn apply(f: fn(i32) -> i32, x: i32) -> i32 { return f(x) }        // ok

var v12_ho = apply(fn (x: i32) -> i32 { return x * 2 }, 21)        // ok


// ---- ERROR: unclosed capture list (missing closing pipe) ----------------

var e13_unclosed_cap = fn ()|*dup_a {   // expected-error: expected '|'
    return 0
}


// ---- VALID: default parameters, final declaration in file --------------

var v13_default = fn (name: string = "world") {                     // ok
    std::println(f"Hello, {name}!")
}


// ---- PATHOLOGICAL: rapid-fire errors then valid -------------------------

var p1 = fn () eval {}                  // expected-error: 'eval' not allowed
var p2 = fn () final {}                 // expected-error: 'final' not allowed
var p3 = fn () override {}              // expected-error: 'override' not allowed
var p4 = fn () inline {}                // expected-error: 'inline' not allowed
var p5_ok = fn (a: i32, b: i32) -> i32 { return a + b }            // ok, must survive

fn make_adder(n: i32) -> fn(i32) -> i32 {                          // ok, final function
    return fn (x: i32) -> i32 { return x + n }
}

// ---- VALID: never-return type -------------------------------------------

var v_divergent = fn () panic -> ! {                                // ok
    panic std::Error::Runtime("fatal")
}


// ---- ERROR: empty capture list blocks outer access ----------------------

var stress_outer = 10
var e_empty_block = fn ()|| -> i32 {    // expected-error: not captured
    return stress_outer
}


// ---- VALID: recovery after empty capture error --------------------------

var v_after_empty = fn ()|| -> i32 { return 42 }                   // ok