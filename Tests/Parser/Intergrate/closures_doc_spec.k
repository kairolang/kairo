// ==========================================================================
//  closures_doc_spec.k
//  Full coverage of every feature described in the Closures documentation.
//  Each section maps 1:1 to a doc heading.
// ==========================================================================


// --- Doc #Basic Syntax ---------------------------------------------------

// Anonymous function with explicit return type and block body
var add = fn (a: i32, b: i32) -> i32 {
    return a + b
}

// Anonymous function with inferred return type
var double = fn (x: i32) -> i32 {
    return x * 2
}

// Closure assigned to a variable with explicit fn-pointer type annotation
var opr: fn(i32, i32) -> i32 = fn (a: i32, b: i32) -> i32 { return a + b }


// --- Doc #Capture Modes --------------------------------------------------

// Default capture: by copy, mutations inside do not affect original
var x = 10
var add_x = fn (y: i32) -> i32 {
    return y + x    // x captured by copy
}

// Capture all by pointer |*|
var count = 0
var increment = fn ()|*| {
    *count += 1     // modifies the original count
}

// Const pointer capture |const *name, ...|
var cx = 10
var cy = 20
var cz = 30
var const_capture = fn (a: i32)|const *cx, const *cy, const *cz| -> i32 {
    return a + *cx + *cy + *cz  // can read, not modify
}

// Mixed capture, copy and pointer in the same list
var ma = 10
var mb = 20
var mixed_capture = fn (x: i32)|ma, *mb| -> i32 {
    *mb += 1
    return x + ma + *mb     // ma is copy, mb is pointer
}

// Named copy-only captures |a, b|
var na = 1
var nb = 2
var copy_named = fn ()|na, nb| -> i32 {
    return na + nb
}

// Named pointer-only captures |*a, *b|
var pa = 1
var pb = 2
var ptr_named = fn ()|*pa, *pb| -> i32 {
    return *pa + *pb
}


// --- Doc #Default Parameters ---------------------------------------------

var greet = fn (name: string = "world") {
    std::println(f"Hello, {name}!")
}


// --- Doc #Generic Closures -----------------------------------------------

var identity = fn <T>(x: T) -> T {
    return x
}


// --- Doc #Panic Specifier ------------------------------------------------

var risky = fn () panic -> i32 {
    if bad_condition {
        panic std::Error::Runtime("failed")
    }
    return 42
}


// --- Doc #Closures vs Inner Functions ------------------------------------

fn outer() -> i32 {
    var x = 10
    fn inner(y: i32) -> i32 = y + 1    // cannot access x
    return inner(x)
}


// --- Doc #Passing Closures to Functions ----------------------------------

fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x)
}

// Inline anonymous function as argument
var r1 = apply(fn (x: i32) -> i32 { return x * 2 }, 21)

// Pre-bound closure as argument
var triple = fn (x: i32) -> i32 { return x * 3 }
var r2 = apply(triple, 10)

// Higher-order: map
fn map(data: [i32], transform: fn(i32) -> i32) -> [i32] {
    var result: [i32]
    for item in data {
        result.push(transform(item))
    }
    return result
}

var doubled = map([1, 2, 3], fn (x: i32) -> i32 { return x * 2 })

// --- Doc #Modifiers ------------------------------------------------------

var panic_closure = fn () panic -> i32 {
    if bad_condition {
        panic std::Error::Runtime("failed")
    }
    return 42
}

var volatile_closure = fn () volatile {}

var async_closure = fn () async {}

var multi_modifier = fn () volatile async panic -> i32 {
    return 100
}

var divergent = fn () panic -> ! {
    panic std::Error::Runtime("always panics")
}


// --- Doc #Nested Closures ------------------------------------------------

var nested_expr = fn () = fn (x: i32) -> i32 = x * 2

var nested_block = fn () -> fn(i32) -> i32 {
    return fn (x: i32) -> i32 { return x + 1 }
}

var nested_mixed = fn () -> fn(i32) -> i32 {
    var offset = 10
    return fn (x: i32) -> i32 = x + offset
}

// --- Doc #AMT and Lifetime Safety ----------------------------------------

// Capture by copy: closure outlives enclosing scope, safe
fn make_safe_closure() -> fn() -> i32 {
    var x = 42
    return fn () -> i32 { return x }    // x copied, no lifetime issue
}

// Capture by pointer of stack local in escaping closure, AMT error expected
fn make_bad_closure() -> fn() -> i32 {
    var x = 42
    return fn ()|*x| -> i32 { return *x }
    // expected-error: closure captures stack local by pointer and escapes scope
}
