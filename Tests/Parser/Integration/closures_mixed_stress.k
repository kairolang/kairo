// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v1_basic
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl a: i32
// AST-NEXT: |     |-ParamDecl b: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr a
// AST-NEXT: |           `-NamedIdentExpr b
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v1_expr
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl x: i32
// AST-NEXT: |     `-BinaryOperatorExpr *
// AST-NEXT: |       |-NamedIdentExpr x
// AST-NEXT: |       `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var e1_const
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v2_after_const
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl x: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr x
// AST-NEXT: |           `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v2_count
// AST-NEXT: |   `-IntegerLiteralExpr 0
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v2_ptr_capture
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-Capture *v2_count
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ExpressionStmt
// AST-NEXT: |         `-AssignOperatorExpr +=
// AST-NEXT: |           |-UnaryOperatorExpr prefix *
// AST-NEXT: |           | `-NamedIdentExpr v2_count
// AST-NEXT: |           `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var e2_broken_param
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-ParamDecl x: i32
// AST-NEXT: |     |-Capture *v2_count
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 0
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v3_mixed_cap_a
// AST-NEXT: |   `-IntegerLiteralExpr 10
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v3_mixed_cap_b
// AST-NEXT: |   `-IntegerLiteralExpr 20
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v3_mixed
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl x: i32
// AST-NEXT: |     |-Capture v3_mixed_cap_a
// AST-NEXT: |     |-Capture *v3_mixed_cap_b
// AST-NEXT: |     `-CompoundStmt (2)
// AST-NEXT: |       |-ExpressionStmt
// AST-NEXT: |       | `-AssignOperatorExpr +=
// AST-NEXT: |       |   |-UnaryOperatorExpr prefix *
// AST-NEXT: |       |   | `-NamedIdentExpr v3_mixed_cap_b
// AST-NEXT: |       |   `-IntegerLiteralExpr 1
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-BinaryOperatorExpr +
// AST-NEXT: |           | |-NamedIdentExpr x
// AST-NEXT: |           | `-NamedIdentExpr v3_mixed_cap_a
// AST-NEXT: |           `-UnaryOperatorExpr prefix *
// AST-NEXT: |             `-NamedIdentExpr v3_mixed_cap_b
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var e3_unclosed
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-ParamDecl x: i32
// AST-NEXT: |     |-Capture *v3_mixed_cap_a
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-UnaryOperatorExpr prefix *
// AST-NEXT: |           `-NamedIdentExpr v3_mixed_cap_a
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v4_generic
// AST-NEXT: |   `-ClosureExpr ->  T
// AST-NEXT: |     |-GenericParamDecl 'T'
// AST-NEXT: |     |-ParamDecl x: T
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-NamedIdentExpr x
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var e4_multi_bad
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 0
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v5_panic
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 42
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v5_volatile
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v5_async
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v5_all_valid
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 0
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var e5_trailing
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-Capture *v3_mixed_cap_a
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 0
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v6_ka
// AST-NEXT: |   `-IntegerLiteralExpr 10
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v6_kb
// AST-NEXT: |   `-IntegerLiteralExpr 20
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v6_const_cap
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl a: i32
// AST-NEXT: |     |-Capture const *v6_ka
// AST-NEXT: |     |-Capture const *v6_kb
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-BinaryOperatorExpr +
// AST-NEXT: |           | |-NamedIdentExpr a
// AST-NEXT: |           | `-UnaryOperatorExpr prefix *
// AST-NEXT: |           |   `-NamedIdentExpr v6_ka
// AST-NEXT: |           `-UnaryOperatorExpr prefix *
// AST-NEXT: |             `-NamedIdentExpr v6_kb
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var e6_const_missing
// AST-NEXT: |   `-BinaryOperatorExpr |
// AST-NEXT: |     |-BinaryOperatorExpr *
// AST-NEXT: |     | |-RecoveryExpr trying: ClosureExpr
// AST-NEXT: |     | `-NamedIdentExpr v6_kb
// AST-NEXT: |     `-SetLiteralExpr (1)
// AST-NEXT: |       `-RecoveryExpr trying: ChainExpr
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-IntegerLiteralExpr 0
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-RecoveryExpr trying: ChainExpr
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v7_empty_cap
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CaptureList (explicit no capture)
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 42
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var e7_empty_expr
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v8_recovery
// AST-NEXT: |   `-IntegerLiteralExpr 5
// AST-NEXT: |-FunctionDecl  test_stmt_recovery()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-VariableDecl var e8_broken
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v9_nested
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-ClosureExpr ->  i32
// AST-NEXT: |       |-ParamDecl x: i32
// AST-NEXT: |       `-BinaryOperatorExpr *
// AST-NEXT: |         |-NamedIdentExpr x
// AST-NEXT: |         `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v9_nested_block
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
// AST-NEXT: |-FunctionDecl  e9_escape() -> fn() -> i32
// AST-NEXT: | `-CompoundStmt (2)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var local
// AST-NEXT: |   |   `-IntegerLiteralExpr 42
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-ClosureExpr ->  i32
// AST-NEXT: |       |-Capture *local
// AST-NEXT: |       `-CompoundStmt (1)
// AST-NEXT: |         `-ReturnStmt
// AST-NEXT: |           `-UnaryOperatorExpr prefix *
// AST-NEXT: |             `-NamedIdentExpr local
// AST-NEXT: |-FunctionDecl  v10_safe_escape() -> fn() -> i32
// AST-NEXT: | `-CompoundStmt (2)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var local
// AST-NEXT: |   |   `-IntegerLiteralExpr 42
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-ClosureExpr ->  i32
// AST-NEXT: |       `-CompoundStmt (1)
// AST-NEXT: |         `-ReturnStmt
// AST-NEXT: |           `-NamedIdentExpr local
// AST-NEXT: |-FunctionDecl  e10_inner_capture()
// AST-NEXT: | `-CompoundStmt (2)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var x
// AST-NEXT: |   |   `-IntegerLiteralExpr 10
// AST-NEXT: |   `-DeclStmt
// AST-NEXT: |     `-FunctionDecl  inner(y: i32) -> i32
// AST-NEXT: |       |-ParamDecl y: i32
// AST-NEXT: |       `-BinaryOperatorExpr +
// AST-NEXT: |         |-NamedIdentExpr y
// AST-NEXT: |         `-NamedIdentExpr x
// AST-NEXT: |-FunctionDecl  v11_inner_clean() -> i32
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
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var dup_a
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var e11_dup
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-Capture dup_a
// AST-NEXT: |     |-Capture dup_a
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-NamedIdentExpr dup_a
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var dup_b
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var e12_dup_mixed
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-Capture dup_b
// AST-NEXT: |     |-Capture *dup_b
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-NamedIdentExpr dup_b
// AST-NEXT: |-FunctionDecl  apply(f: fn(i32) -> i32, x: i32) -> i32
// AST-NEXT: | |-ParamDecl f: fn(i32) -> i32
// AST-NEXT: | |-ParamDecl x: i32
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-CallExpr (1 args)
// AST-NEXT: |       |-NamedIdentExpr f
// AST-NEXT: |       `-NamedIdentExpr x
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v12_ho
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
// AST-NEXT: | `-VariableDecl var e13_unclosed_cap
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-Capture *dup_a
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 0
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v13_default
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
// AST-NEXT: | `-VariableDecl var p1
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var p2
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var p3
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var p4
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var p5_ok
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl a: i32
// AST-NEXT: |     |-ParamDecl b: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr a
// AST-NEXT: |           `-NamedIdentExpr b
// AST-NEXT: |-FunctionDecl  make_adder(n: i32) -> fn(i32) -> i32
// AST-NEXT: | |-ParamDecl n: i32
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ReturnStmt
// AST-NEXT: |     `-ClosureExpr ->  i32
// AST-NEXT: |       |-ParamDecl x: i32
// AST-NEXT: |       `-CompoundStmt (1)
// AST-NEXT: |         `-ReturnStmt
// AST-NEXT: |           `-BinaryOperatorExpr +
// AST-NEXT: |             |-NamedIdentExpr x
// AST-NEXT: |             `-NamedIdentExpr n
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var v_divergent
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-PanicStmt
// AST-NEXT: |         `-CallExpr (1 args)
// AST-NEXT: |           |-ChainExpr 'std::Error::Runtime'
// AST-NEXT: |           | |-NamedIdentExpr std
// AST-NEXT: |           | |-Step ::Error
// AST-NEXT: |           | `-Step ::Runtime
// AST-NEXT: |           `-StringLiteralExpr "fatal"
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var stress_outer
// AST-NEXT: |   `-IntegerLiteralExpr 10
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var e_empty_block
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     `-CaptureList (explicit no capture)
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-NamedIdentExpr stress_outer
// AST-NEXT: `-DeclStmt
// AST-NEXT:   `-VariableDecl var v_after_empty
// AST-NEXT:     `-ClosureExpr ->  i32
// AST-NEXT:       `-CaptureList (explicit no capture)
// AST-NEXT:       `-CompoundStmt (1)
// AST-NEXT:         `-ReturnStmt
// AST-NEXT:           `-IntegerLiteralExpr 42
// AST: -- 18 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [S047E]:
// AST: {{.*}}: error [S053E]:
// AST: {{.*}}: error [S047E]:
// AST: {{.*}}: error [S047E]:
// AST: {{.*}}: error [S047E]:
// AST: {{.*}}: error [S047E]:
// AST: {{.*}}: error [S054E]:
// AST: {{.*}}: error [S047E]:
// AST: {{.*}}: error [S054E]:
// AST: {{.*}}: error [S052E]:
// AST: {{.*}}: error [S052E]:
// AST: {{.*}}: error [S052E]:
// AST: {{.*}}: error [S052E]:
// AST: {{.*}}: error [S052E]:
// AST: {{.*}}: error [S047E]:
// AST: {{.*}}: error [S047E]:
// AST: {{.*}}: error [S047E]:
// AST: {{.*}}: error [S047E]:
// END-GENERATED-CHECKS

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
