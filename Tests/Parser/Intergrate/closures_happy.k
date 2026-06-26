// ==========================================================================
//  closures_happy.k
//  All syntactically valid closure forms. Zero diagnostics expected.
// ==========================================================================


// --- Basic lambdas (no captures) -----------------------------------------

var basic_block = fn (a: i32, b: i32) -> i32 {
    return a + b
}

var basic_expr = fn (x: i32) -> i32 = x * 2

var no_params = fn () -> i32 {
    return 42
}

var no_return_type = fn (x: i32) {
    std::println(f"{x}")
}

var inferred_return = fn (x: i32) {
    return x + 1
}


// --- Explicit fn-pointer type annotation ---------------------------------

var typed: fn(i32, i32) -> i32 = fn (a: i32, b: i32) -> i32 { return a + b }


// --- Capture by copy (default, implicit) ---------------------------------

var cx = 10
var capture_copy_implicit = fn (y: i32) -> i32 {
    return y + cx
}


// --- Capture by copy (explicit named) ------------------------------------

var na = 1
var nb = 2
var capture_copy_named = fn ()|na, nb| -> i32 {
    return na + nb
}


// --- Capture all by pointer |*| ------------------------------------------

var count = 0
var capture_all_ptr = fn ()|*| {
    *count += 1
}


// --- Named pointer captures |*a, *b| ------------------------------------

var pa = 10
var pb = 20
var capture_named_ptrs = fn ()|*pa, *pb| -> i32 {
    return *pa + *pb
}


// --- Const pointer captures |const *a, ...| ------------------------------

var ka = 10
var kb = 20
var kc = 30
var capture_const_ptrs = fn (a: i32)|const *ka, const *kb, const *kc| -> i32 {
    return a + *ka + *kb + *kc
}


// --- Mixed captures |copy, *ptr| ----------------------------------------

var ma = 10
var mb = 20
var capture_mixed = fn (x: i32)|ma, *mb| -> i32 {
    *mb += 1
    return x + ma + *mb
}


// --- Empty capture list || -----------------------------------------------

var empty_capture = fn ()|| {
    return 42
}


// --- Generic closures ----------------------------------------------------

var generic_identity = fn <T>(x: T) -> T {
    return x
}

var generic_capture = fn <T>(x: T)|*context| {
    *context = x
}


// --- Valid trailing modifiers --------------------------------------------

var panic_closure = fn () panic -> i32 {
    return 42
}

var volatile_closure = fn () volatile {}

var async_closure = fn () async {}

var multi_modifier = fn () volatile async panic -> i32 {
    return 100
}


// --- Default parameters --------------------------------------------------

var default_param = fn (name: string = "world") {
    std::println(f"Hello, {name}!")
}

var default_numeric = fn (x: i32 = 0, y: i32 = 1) -> i32 {
    return x + y
}


// --- Expression body variants --------------------------------------------

var expr_no_params = fn () -> i32 = 42

var expr_with_capture = fn ()|na| -> i32 = na + 1

var expr_generic = fn <T>(x: T) -> T = x


// --- Nested closures -----------------------------------------------------

var nested = fn () = fn (x: i32) -> i32 = x * 2

var nested_block = fn () -> fn(i32) -> i32 {
    return fn (x: i32) -> i32 { return x + 1 }
}


// --- Closures as parameters / higher-order -------------------------------

fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x)
}

var r1 = apply(fn (x: i32) -> i32 { return x * 2 }, 21)

var triple = fn (x: i32) -> i32 { return x * 3 }
var r2 = apply(triple, 10)

fn map(data: [i32], transform: fn(i32) -> i32) -> [i32] {
    var result: [i32]
    for item in data {
        result.push(transform(item))
    }
    return result
}

var doubled = map([1, 2, 3], fn (x: i32) -> i32 { return x * 2 })


// --- Inner function (not a closure), verifies no capture ----------------

fn outer() -> i32 {
    var x = 10
    fn inner(y: i32) -> i32 = y + 1
    return inner(x)
}


// --- Non-escaping pointer capture (safe) ---------------------------------

fn local_scope() {
    var x = 0
    var inc = fn ()|*x| { *x += 1 }
    inc()
    inc()
    // x == 2, closure does not escape, no AMT issue
}


// --- Escaping copy capture (safe) ----------------------------------------

fn make_adder(n: i32) -> fn(i32) -> i32 {
    return fn (x: i32) -> i32 { return x + n }
}

// --- Never-return type ---------------------------------------------------

var divergent = fn () panic -> ! {
    panic std::Error::Runtime("fatal")
}


// --- Nested closures (all three forms) -----------------------------------

var nested_expr = fn () = fn (x: i32) -> i32 = x * 2

var nested_block = fn () -> fn(i32) -> i32 {
    return fn (x: i32) -> i32 { return x + 1 }
}

var nested_mixed = fn () -> fn(i32) -> i32 {
    var offset = 10
    return fn (x: i32) -> i32 = x + offset
}