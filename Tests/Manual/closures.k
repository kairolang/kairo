// ==========================================================================
//  Isolated cases for known parser bugs. Each section tests one bug.
//  After fixes, this file should produce 0 errors and correct AST shapes.
// ==========================================================================


// =========================================================================
//  Bug 1: Empty capture list || not recognized
//  Expected: ClosureExpr with no captures and a block body.
//  Actual:   || parsed as expression-body trigger or logical-OR, cascading.
// =========================================================================

var empty_cap_block = fn ()|| {
    return 42
}

var empty_cap_expr = fn ()|| -> i32 = 42

// Verify the next declaration is NOT swallowed into the closure above.
var after_empty_cap = 100


// =========================================================================
//  Bug 2: Closure with default param + block body swallows next declaration
//  Expected: greet is a standalone closure, identity is a separate VarDecl.
//  Actual:   identity becomes a child ClosureExpr inside greet.
// =========================================================================

var greet = fn (name: string = "world") {
    std::println(f"Hello, {name}!")
}

var identity = fn <T>(x: T) -> T {
    return x
}

// Verify identity is its own node, not nested inside greet.
var after_greet_identity = 200


// =========================================================================
//  Bug 3: Same swallowing with default param — different body content
//  Expected: default_fn is standalone, next_fn is a separate VarDecl.
//  Actual:   next_fn consumed as child of default_fn.
// =========================================================================

var default_fn = fn (x: i32 = 0, y: i32 = 1) -> i32 {
    return x + y
}

var next_fn = fn (a: i32) -> i32 {
    return a * 2
}

var after_default = 300


// =========================================================================
//  Bug 4: Closure with no return type + block body swallows next decl
//  Isolates whether the bug is default-param-specific or general to
//  closures whose return type is inferred and body is a block.
// =========================================================================

var no_ret = fn (x: i32) {
    std::println(f"{x}")
}

var after_no_ret = fn (a: i32) -> i32 {
    return a + 1
}

var after_no_ret_sentinel = 400


// =========================================================================
//  Bug 5: Broken parameter list recovery — sync failure
//  Expected: parser reports error on bad param, recovers, then parses
//            the next three declarations as independent VarDecls.
//  Actual:   recovery runs forward and swallows multiple declarations.
// =========================================================================

var broken_param = fn (x: i32, y: ) {
    return 0
}

var recovery_a = 10
var recovery_b = 20
var recovery_c = fn (z: i32) -> i32 { return z }


// =========================================================================
//  Bug 6: Broken param with capture list — recovery should sync to |
//  Expected: error on bad param, then capture list and body still parse.
//  Actual:   capture list and body swallowed or misattributed.
// =========================================================================

var broken_param_with_cap = fn (x: i32, y: ) |*recovery_a| {
    return *recovery_a
}

var after_broken_cap = 500


// =========================================================================
//  Bug 7: Unclosed paren syncing to capture list
//  Expected: error on missing ), then |*val| and body still parse.
//  Actual:   everything through the next parseable decl gets consumed.
// =========================================================================

var sync_val = 10
var unclosed_paren = fn (x: i32 |*sync_val| {
    return *sync_val
}

var after_unclosed = 600


// =========================================================================
//  Bug 8: f-string in closure body — verify body termination
//  The greet bug may be f-string-specific. Test f-strings in closures
//  with and without default params to isolate.
// =========================================================================

// With default param
var fstr_default = fn (name: string = "test") {
    std::println(f"value: {name}")
}

var after_fstr_default = 700

// Without default param
var fstr_no_default = fn (name: string) {
    std::println(f"value: {name}")
}

var after_fstr_no_default = 800

// Multiple f-string calls
var fstr_multi = fn (a: i32, b: i32) {
    std::println(f"a = {a}")
    std::println(f"b = {b}")
}

var after_fstr_multi = 900