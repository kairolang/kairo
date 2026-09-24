// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var add
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl a: i32
// AST-NEXT: |     |-ParamDecl b: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr a
// AST-NEXT: |           `-NamedIdentExpr b
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var double
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl x: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr *
// AST-NEXT: |           |-NamedIdentExpr x
// AST-NEXT: |           `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var opr: fn(i32, i32) -> i32
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl a: i32
// AST-NEXT: |     |-ParamDecl b: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr a
// AST-NEXT: |           `-NamedIdentExpr b
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var x
// AST-NEXT: |   `-IntegerLiteralExpr 10
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var add_x
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl y: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr y
// AST-NEXT: |           `-NamedIdentExpr x
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var count
// AST-NEXT: |   `-IntegerLiteralExpr 0
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var increment
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-Capture *
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ExpressionStmt
// AST-NEXT: |         `-AssignOperatorExpr +=
// AST-NEXT: |           |-UnaryOperatorExpr prefix *
// AST-NEXT: |           | `-NamedIdentExpr count
// AST-NEXT: |           `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var cx
// AST-NEXT: |   `-IntegerLiteralExpr 10
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var cy
// AST-NEXT: |   `-IntegerLiteralExpr 20
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var cz
// AST-NEXT: |   `-IntegerLiteralExpr 30
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var const_capture
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl a: i32
// AST-NEXT: |     |-Capture const *cx
// AST-NEXT: |     |-Capture const *cy
// AST-NEXT: |     |-Capture const *cz
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-BinaryOperatorExpr +
// AST-NEXT: |           | |-BinaryOperatorExpr +
// AST-NEXT: |           | | |-NamedIdentExpr a
// AST-NEXT: |           | | `-UnaryOperatorExpr prefix *
// AST-NEXT: |           | |   `-NamedIdentExpr cx
// AST-NEXT: |           | `-UnaryOperatorExpr prefix *
// AST-NEXT: |           |   `-NamedIdentExpr cy
// AST-NEXT: |           `-UnaryOperatorExpr prefix *
// AST-NEXT: |             `-NamedIdentExpr cz
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var ma
// AST-NEXT: |   `-IntegerLiteralExpr 10
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var mb
// AST-NEXT: |   `-IntegerLiteralExpr 20
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var mixed_capture
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl x: i32
// AST-NEXT: |     |-Capture ma
// AST-NEXT: |     |-Capture *mb
// AST-NEXT: |     `-CompoundStmt (2)
// AST-NEXT: |       |-ExpressionStmt
// AST-NEXT: |       | `-AssignOperatorExpr +=
// AST-NEXT: |       |   |-UnaryOperatorExpr prefix *
// AST-NEXT: |       |   | `-NamedIdentExpr mb
// AST-NEXT: |       |   `-IntegerLiteralExpr 1
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-BinaryOperatorExpr +
// AST-NEXT: |           | |-NamedIdentExpr x
// AST-NEXT: |           | `-NamedIdentExpr ma
// AST-NEXT: |           `-UnaryOperatorExpr prefix *
// AST-NEXT: |             `-NamedIdentExpr mb
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var na
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var nb
// AST-NEXT: |   `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var copy_named
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-Capture na
// AST-NEXT: |     |-Capture nb
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr na
// AST-NEXT: |           `-NamedIdentExpr nb
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var pa
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var pb
// AST-NEXT: |   `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var ptr_named
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-Capture *pa
// AST-NEXT: |     |-Capture *pb
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-UnaryOperatorExpr prefix *
// AST-NEXT: |           | `-NamedIdentExpr pa
// AST-NEXT: |           `-UnaryOperatorExpr prefix *
// AST-NEXT: |             `-NamedIdentExpr pb
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var greet
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-ParamDecl name: string = "world"
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ExpressionStmt
// AST-NEXT: |         `-CallExpr (1 args)
// AST-NEXT: |           |-ChainExpr 'std::println'
// AST-NEXT: |           | |-NamedIdentExpr std
// AST-NEXT: |           | `-Step ::println
// AST-NEXT: |           `-StringLiteralExpr "Hello, {name}!"
// AST-NEXT: |             `-NamedIdentExpr name
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var identity
// AST-NEXT: |   `-ClosureExpr ->  T
// AST-NEXT: |     |-GenericParamDecl 'T'
// AST-NEXT: |     |-ParamDecl x: T
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-NamedIdentExpr x
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var risky
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     `-CompoundStmt (2)
// AST-NEXT: |       |-ConditionalStmt
// AST-NEXT: |       | |-cond
// AST-NEXT: |       | | `-NamedIdentExpr bad_condition
// AST-NEXT: |       | `-then
// AST-NEXT: |       |   `-CompoundStmt (1)
// AST-NEXT: |       |     `-PanicStmt
// AST-NEXT: |       |       `-CallExpr (1 args)
// AST-NEXT: |       |         |-ChainExpr 'std::Error::Runtime'
// AST-NEXT: |       |         | |-NamedIdentExpr std
// AST-NEXT: |       |         | |-Step ::Error
// AST-NEXT: |       |         | `-Step ::Runtime
// AST-NEXT: |       |         `-StringLiteralExpr "failed"
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 42
// AST-NEXT: |-FunctionDecl  outer() -> i32
// AST-NEXT: | `-CompoundStmt (3)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var x
// AST-NEXT: |   |   `-IntegerLiteralExpr 10
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-FunctionDecl  inner(y: i32) -> i32
// AST-NEXT: |   |   |-ParamDecl y: i32
// AST-NEXT: |   |   `-BinaryOperatorExpr +
// AST-NEXT: |   |     |-NamedIdentExpr y
// AST-NEXT: |   |     `-IntegerLiteralExpr 1
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-CallExpr (1 args)
// AST-NEXT: |       |-NamedIdentExpr inner
// AST-NEXT: |       `-NamedIdentExpr x
// AST-NEXT: |-FunctionDecl  apply(f: fn(i32) -> i32, x: i32) -> i32
// AST-NEXT: | |-ParamDecl f: fn(i32) -> i32
// AST-NEXT: | |-ParamDecl x: i32
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-CallExpr (1 args)
// AST-NEXT: |       |-NamedIdentExpr f
// AST-NEXT: |       `-NamedIdentExpr x
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var r1
// AST-NEXT: |   `-CallExpr (2 args)
// AST-NEXT: |     |-NamedIdentExpr apply
// AST-NEXT: |     |-ClosureExpr ->  i32
// AST-NEXT: |     | |-ParamDecl x: i32
// AST-NEXT: |     | `-CompoundStmt (1)
// AST-NEXT: |     |   `-ReturnStmt
// AST-NEXT: |     |     `-BinaryOperatorExpr *
// AST-NEXT: |     |       |-NamedIdentExpr x
// AST-NEXT: |     |       `-IntegerLiteralExpr 2
// AST-NEXT: |     `-IntegerLiteralExpr 21
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var triple
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl x: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr *
// AST-NEXT: |           |-NamedIdentExpr x
// AST-NEXT: |           `-IntegerLiteralExpr 3
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var r2
// AST-NEXT: |   `-CallExpr (2 args)
// AST-NEXT: |     |-NamedIdentExpr apply
// AST-NEXT: |     |-NamedIdentExpr triple
// AST-NEXT: |     `-IntegerLiteralExpr 10
// AST-NEXT: |-FunctionDecl  map(data: [i32], transform: fn(i32) -> i32) -> [i32]
// AST-NEXT: | |-ParamDecl data: [i32]
// AST-NEXT: | |-ParamDecl transform: fn(i32) -> i32
// AST-NEXT: | `-CompoundStmt (3)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var result: [i32]
// AST-NEXT: |   |-RangedForStmt item
// AST-NEXT: |   | |-NamedIdentExpr data
// AST-NEXT: |   | `-CompoundStmt (1)
// AST-NEXT: |   |   `-ExpressionStmt
// AST-NEXT: |   |     `-CallExpr (1 args)
// AST-NEXT: |   |       |-ChainExpr 'result.push'
// AST-NEXT: |   |       | |-NamedIdentExpr result
// AST-NEXT: |   |       | `-Step .push
// AST-NEXT: |   |       `-CallExpr (1 args)
// AST-NEXT: |   |         |-NamedIdentExpr transform
// AST-NEXT: |   |         `-NamedIdentExpr item
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-NamedIdentExpr result
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var doubled
// AST-NEXT: |   `-CallExpr (2 args)
// AST-NEXT: |     |-NamedIdentExpr map
// AST-NEXT: |     |-ListLiteralExpr (3)
// AST-NEXT: |     | |-IntegerLiteralExpr 1
// AST-NEXT: |     | |-IntegerLiteralExpr 2
// AST-NEXT: |     | `-IntegerLiteralExpr 3
// AST-NEXT: |     `-ClosureExpr ->  i32
// AST-NEXT: |       |-ParamDecl x: i32
// AST-NEXT: |       `-CompoundStmt (1)
// AST-NEXT: |         `-ReturnStmt
// AST-NEXT: |           `-BinaryOperatorExpr *
// AST-NEXT: |             |-NamedIdentExpr x
// AST-NEXT: |             `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var panic_closure
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     `-CompoundStmt (2)
// AST-NEXT: |       |-ConditionalStmt
// AST-NEXT: |       | |-cond
// AST-NEXT: |       | | `-NamedIdentExpr bad_condition
// AST-NEXT: |       | `-then
// AST-NEXT: |       |   `-CompoundStmt (1)
// AST-NEXT: |       |     `-PanicStmt
// AST-NEXT: |       |       `-CallExpr (1 args)
// AST-NEXT: |       |         |-ChainExpr 'std::Error::Runtime'
// AST-NEXT: |       |         | |-NamedIdentExpr std
// AST-NEXT: |       |         | |-Step ::Error
// AST-NEXT: |       |         | `-Step ::Runtime
// AST-NEXT: |       |         `-StringLiteralExpr "failed"
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 42
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var volatile_closure
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var async_closure
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var multi_modifier
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 100
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var divergent
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-PanicStmt
// AST-NEXT: |         `-CallExpr (1 args)
// AST-NEXT: |           |-ChainExpr 'std::Error::Runtime'
// AST-NEXT: |           | |-NamedIdentExpr std
// AST-NEXT: |           | |-Step ::Error
// AST-NEXT: |           | `-Step ::Runtime
// AST-NEXT: |           `-StringLiteralExpr "always panics"
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var nested_expr
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-ClosureExpr ->  i32
// AST-NEXT: |       |-ParamDecl x: i32
// AST-NEXT: |       `-BinaryOperatorExpr *
// AST-NEXT: |         |-NamedIdentExpr x
// AST-NEXT: |         `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var nested_block
// AST-NEXT: |   `-ClosureExpr ->  fn(i32) -> i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-ClosureExpr ->  i32
// AST-NEXT: |           |-ParamDecl x: i32
// AST-NEXT: |           `-CompoundStmt (1)
// AST-NEXT: |             `-ReturnStmt
// AST-NEXT: |               `-BinaryOperatorExpr +
// AST-NEXT: |                 |-NamedIdentExpr x
// AST-NEXT: |                 `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var nested_mixed
// AST-NEXT: |   `-ClosureExpr ->  fn(i32) -> i32
// AST-NEXT: |     `-CompoundStmt (2)
// AST-NEXT: |       |-DeclStmt
// AST-NEXT: |       | `-VariableDecl var offset
// AST-NEXT: |       |   `-IntegerLiteralExpr 10
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-ClosureExpr ->  i32
// AST-NEXT: |           |-ParamDecl x: i32
// AST-NEXT: |           `-BinaryOperatorExpr +
// AST-NEXT: |             |-NamedIdentExpr x
// AST-NEXT: |             `-NamedIdentExpr offset
// AST-NEXT: |-FunctionDecl  make_safe_closure() -> fn() -> i32
// AST-NEXT: | `-CompoundStmt (2)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var x
// AST-NEXT: |   |   `-IntegerLiteralExpr 42
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-ClosureExpr ->  i32
// AST-NEXT: |       `-CompoundStmt (1)
// AST-NEXT: |         `-ReturnStmt
// AST-NEXT: |           `-NamedIdentExpr x
// AST-NEXT: `-FunctionDecl  make_bad_closure() -> fn() -> i32
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-DeclStmt
// AST-NEXT:     | `-VariableDecl var x
// AST-NEXT:     |   `-IntegerLiteralExpr 42
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-ClosureExpr ->  i32
// AST-NEXT:         |-Capture *x
// AST-NEXT:         `-CompoundStmt (1)
// AST-NEXT:           `-ReturnStmt
// AST-NEXT:             `-UnaryOperatorExpr prefix *
// AST-NEXT:               `-NamedIdentExpr x
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [SC004E]:
// END-GENERATED-CHECKS

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
