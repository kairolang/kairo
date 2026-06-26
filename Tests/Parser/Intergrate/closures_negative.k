// ==========================================================================
//  closures_negative.k
//  Every case in this file is expected to produce a diagnostic.
//  Grouped: prohibited modifiers, AMT violations, malformed syntax.
// ==========================================================================


// --- Prohibited trailing modifiers ---------------------------------------
// Doc: closures cannot be eval, const, unsafe, virtual, override, inline, final

var bad_const    = fn () const    { return 1 }  // expected-error: 'const' not allowed on closures
var bad_unsafe   = fn () unsafe   { return 2 }  // expected-error: 'unsafe' not allowed on closures
var bad_eval     = fn () eval     { return 3 }  // expected-error: 'eval' not allowed on closures
var bad_final    = fn () final    { return 4 }  // expected-error: 'final' not allowed on closures
var bad_inline   = fn () inline   { return 5 }  // expected-error: 'inline' not allowed on closures
var bad_virtual  = fn () virtual  { return 6 }  // expected-error: 'virtual' not allowed on closures
var bad_override = fn () override { return 7 }  // expected-error: 'override' not allowed on closures


// --- Multiple prohibited modifiers on one closure ------------------------

var bad_multi = fn () const unsafe final { return 8 }
// expected-error: 'const' not allowed on closures
// expected-error: 'unsafe' not allowed on closures
// expected-error: 'final' not allowed on closures


// --- Prohibited mixed with valid ----------------------------------------

var bad_mixed = fn () panic const -> i32 { return 9 }
// expected-error: 'const' not allowed on closures
// (panic is valid and should still be accepted)


// --- AMT: escaping pointer capture of stack local ------------------------

fn escape_stack_ptr() -> fn() -> i32 {
    var x = 42
    return fn ()|*x| -> i32 { return *x }
    // expected-error: closure captures stack local 'x' by pointer and escapes scope
}


// --- AMT: escaping |*| capture of stack local ----------------------------

fn escape_stack_all() -> fn() {
    var a = 1
    var b = 2
    return fn ()|*| { *a += *b }
    // expected-error: closure captures stack locals by pointer and escapes scope
}


// --- Inner function attempting capture (not a closure, no captures) ------

fn inner_capture_error() {
    var x = 10
    fn inner(y: i32) -> i32 = y + x    // expected-error: 'x' not in scope
}


// --- Malformed parameter list: missing type -------------------------------

var bad_param_no_type = fn (x: i32, y: ) -> i32 {  // expected-error: expected type
    return 0
}

// --- Malformed parameter list: missing closing paren ---------------------

var bad_unclosed_paren = fn (x: i32 {  // expected-error: expected ')'
    return 0
}

// --- Malformed capture list: trailing comma ------------------------------

var bad_trailing_comma = fn ()|*x, | {  // expected-error: expected name or '*'
    return 0
}

// --- Malformed capture list: const with no identifier --------------------

var bad_const_no_ident = fn ()|const * , *y| {  // expected-error: expected identifier
    return 0
}

// --- Malformed capture list: unclosed pipe -------------------------------

var bad_unclosed_capture = fn ()|*x {   // expected-error: expected '|'
    return 0
}

// --- Missing body entirely -----------------------------------------------

var bad_no_body = fn (x: i32) -> i32    // expected-error: expected '{' or '='

// --- Expression body with nothing after '=' ------------------------------

var bad_empty_expr = fn () =            // expected-error: expected expression
var after_bad_expr = 5                  // recovery: this should parse as VarDecl

// --- Expression body with nothing after '=' inside a function ------------

fn test_expr_recovery() {
    var broken = fn () =                // expected-error: expected expression
    return                              // recovery: return should not be swallowed
}

// --- Duplicate capture names ---------------------------------------------

var da = 1
var bad_dup_capture = fn ()|da, da| {   // expected-error: duplicate capture 'da'
    return da
}

// --- Pointer and copy of same variable -----------------------------------

var sa = 1
var bad_dup_mixed = fn ()|sa, *sa| {    // expected-error: duplicate capture 'sa'
    return sa
}

// --- Empty capture list blocks outer variable access ---------------------

var outer_val = 10
var bad_empty_capture = fn ()|| -> i32 {
    return outer_val    // expected-error: 'outer_val' is not captured
}