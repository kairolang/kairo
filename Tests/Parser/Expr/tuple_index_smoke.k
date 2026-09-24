// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-FunctionDecl <T> ok(a: T, b: *T, t: (i32, i32, i32), p: *(i32, i32))
// AST-NEXT: | |-GenericParamDecl 'T'
// AST-NEXT: | |-ParamDecl a: T
// AST-NEXT: | |-ParamDecl b: *T
// AST-NEXT: | |-ParamDecl t: (i32, i32, i32)
// AST-NEXT: | |-ParamDecl p: *(i32, i32)
// AST-NEXT: | `-CompoundStmt (34)
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-ChainExpr 't.0'
// AST-NEXT: |   |   |-NamedIdentExpr t
// AST-NEXT: |   |   `-Step .0  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-ChainExpr 't.0.1'
// AST-NEXT: |   |   |-NamedIdentExpr t
// AST-NEXT: |   |   |-Step .0  tuple-index
// AST-NEXT: |   |   `-Step .1  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-ChainExpr 't.0.1.2'
// AST-NEXT: |   |   |-NamedIdentExpr t
// AST-NEXT: |   |   |-Step .0  tuple-index
// AST-NEXT: |   |   |-Step .1  tuple-index
// AST-NEXT: |   |   `-Step .2  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-ChainExpr 't.10'
// AST-NEXT: |   |   |-NamedIdentExpr t
// AST-NEXT: |   |   `-Step .10  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-ChainExpr '(1, 2).0'
// AST-NEXT: |   |   |-TupleLiteralExpr (2)
// AST-NEXT: |   |   | |-IntegerLiteralExpr 1
// AST-NEXT: |   |   | `-IntegerLiteralExpr 2
// AST-NEXT: |   |   `-Step .0  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-BinaryOperatorExpr +
// AST-NEXT: |   |   |-ChainExpr 't.0'
// AST-NEXT: |   |   | |-NamedIdentExpr t
// AST-NEXT: |   |   | `-Step .0  tuple-index
// AST-NEXT: |   |   `-IntegerLiteralExpr 1
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-CallExpr (2 args)
// AST-NEXT: |   |   |-NamedIdentExpr f
// AST-NEXT: |   |   |-ChainExpr 't.0'
// AST-NEXT: |   |   | |-NamedIdentExpr t
// AST-NEXT: |   |   | `-Step .0  tuple-index
// AST-NEXT: |   |   `-ChainExpr 't.1'
// AST-NEXT: |   |     |-NamedIdentExpr t
// AST-NEXT: |   |     `-Step .1  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-CallExpr (0 args)
// AST-NEXT: |   |   `-ChainExpr 't.0.field(1, 2).0.bar'
// AST-NEXT: |   |     |-CallExpr (2 args)
// AST-NEXT: |   |     | |-ChainExpr 't.0.field'
// AST-NEXT: |   |     | | |-NamedIdentExpr t
// AST-NEXT: |   |     | | |-Step .0  tuple-index
// AST-NEXT: |   |     | | `-Step .field
// AST-NEXT: |   |     | |-IntegerLiteralExpr 1
// AST-NEXT: |   |     | `-IntegerLiteralExpr 2
// AST-NEXT: |   |     |-Step .0  tuple-index
// AST-NEXT: |   |     `-Step .bar
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-ChainExpr 'arr[0].1'
// AST-NEXT: |   |   |-SubscriptExpr
// AST-NEXT: |   |   | |-NamedIdentExpr arr
// AST-NEXT: |   |   | `-IntegerLiteralExpr 0
// AST-NEXT: |   |   `-Step .1  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-RangeExpr ..
// AST-NEXT: |   |   |-ChainExpr 't.0'
// AST-NEXT: |   |   | |-NamedIdentExpr t
// AST-NEXT: |   |   | `-Step .0  tuple-index
// AST-NEXT: |   |   `-ChainExpr 't.1'
// AST-NEXT: |   |     |-NamedIdentExpr t
// AST-NEXT: |   |     `-Step .1  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-ChainExpr 'p->0'
// AST-NEXT: |   |   |-NamedIdentExpr p
// AST-NEXT: |   |   `-Step ->0  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-ChainExpr 'p?.0'
// AST-NEXT: |   |   |-NamedIdentExpr p
// AST-NEXT: |   |   `-Step ?.0  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-ChainExpr 'p?->0'
// AST-NEXT: |   |   |-NamedIdentExpr p
// AST-NEXT: |   |   `-Step ?->0  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-AssignOperatorExpr =
// AST-NEXT: |   |   |-NamedIdentExpr x
// AST-NEXT: |   |   `-FloatingLiteralExpr 0.5
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-AssignOperatorExpr =
// AST-NEXT: |   |   |-NamedIdentExpr y
// AST-NEXT: |   |   `-FloatingLiteralExpr 0.5
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-CallExpr (0 args)
// AST-NEXT: |   |   `-ChainExpr '1.foo'
// AST-NEXT: |   |     |-IntegerLiteralExpr 1
// AST-NEXT: |   |     `-Step .foo
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-ChainExpr '1.e5'
// AST-NEXT: |   |   |-IntegerLiteralExpr 1
// AST-NEXT: |   |   `-Step .e5
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-FloatingLiteralExpr 100000
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-FloatingLiteralExpr 12
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-FloatingLiteralExpr 1000.5
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-RangeExpr ..
// AST-NEXT: |   |   |-IntegerLiteralExpr 1
// AST-NEXT: |   |   `-IntegerLiteralExpr 5
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-PackExpansionExpr
// AST-NEXT: |   |   `-IntegerLiteralExpr 1
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-RangeExpr ..
// AST-NEXT: |   |   |-IntegerLiteralExpr 5
// AST-NEXT: |   |   `-IntegerLiteralExpr 5
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-RangeExpr ..
// AST-NEXT: |   |   |-IntegerLiteralExpr 5
// AST-NEXT: |   |   `-SubscriptExpr
// AST-NEXT: |   |     |-NamedIdentExpr arr
// AST-NEXT: |   |     `-RangeExpr ..
// AST-NEXT: |   |       |-IntegerLiteralExpr 1
// AST-NEXT: |   |       `-IntegerLiteralExpr 5
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-SubscriptExpr
// AST-NEXT: |   |   |-NamedIdentExpr arr
// AST-NEXT: |   |   `-RangeExpr ..
// AST-NEXT: |   |     |-ChainExpr 't.0'
// AST-NEXT: |   |     | |-NamedIdentExpr t
// AST-NEXT: |   |     | `-Step .0  tuple-index
// AST-NEXT: |   |     `-ChainExpr 't.1'
// AST-NEXT: |   |       |-NamedIdentExpr t
// AST-NEXT: |   |       `-Step .1  tuple-index
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-RangeExpr ..
// AST-NEXT: |   |   |-FloatingLiteralExpr 1
// AST-NEXT: |   |   `-FloatingLiteralExpr 2
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-RangeExpr ..
// AST-NEXT: |   |   |-ChainExpr 'x.0'
// AST-NEXT: |   |   | |-NamedIdentExpr x
// AST-NEXT: |   |   | `-Step .0  tuple-index
// AST-NEXT: |   |   `-NamedIdentExpr y
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-BinaryOperatorExpr .*
// AST-NEXT: |   |   |-UnaryOperatorExpr prefix !
// AST-NEXT: |   |   | `-NamedIdentExpr a
// AST-NEXT: |   |   `-NamedIdentExpr p
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-BinaryOperatorExpr ->*
// AST-NEXT: |   |   |-UnaryOperatorExpr prefix !
// AST-NEXT: |   |   | `-NamedIdentExpr a
// AST-NEXT: |   |   `-NamedIdentExpr p
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-BinaryOperatorExpr +
// AST-NEXT: |   |   |-BinaryOperatorExpr .*
// AST-NEXT: |   |   | |-NamedIdentExpr a
// AST-NEXT: |   |   | `-NamedIdentExpr p
// AST-NEXT: |   |   `-IntegerLiteralExpr 1
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-BinaryOperatorExpr ^^
// AST-NEXT: |   |   |-BinaryOperatorExpr .*
// AST-NEXT: |   |   | |-NamedIdentExpr a
// AST-NEXT: |   |   | `-NamedIdentExpr p
// AST-NEXT: |   |   `-IntegerLiteralExpr 2
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-BinaryOperatorExpr ?.*
// AST-NEXT: |   |   |-NamedIdentExpr a
// AST-NEXT: |   |   `-NamedIdentExpr p
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-BinaryOperatorExpr ?->*
// AST-NEXT: |   |   |-NamedIdentExpr a
// AST-NEXT: |   |   `-ChainExpr 'p(a .* p).field'
// AST-NEXT: |   |     |-CallExpr (1 args)
// AST-NEXT: |   |     | |-NamedIdentExpr p
// AST-NEXT: |   |     | `-BinaryOperatorExpr .*
// AST-NEXT: |   |     |   |-NamedIdentExpr a
// AST-NEXT: |   |     |   `-NamedIdentExpr p
// AST-NEXT: |   |     `-Step .field
// AST-NEXT: |   `-ExpressionStmt
// AST-NEXT: |     `-BinaryOperatorExpr .*
// AST-NEXT: |       |-BinaryOperatorExpr .*
// AST-NEXT: |       | |-NamedIdentExpr a
// AST-NEXT: |       | `-NamedIdentExpr p
// AST-NEXT: |       `-NamedIdentExpr q
// AST-NEXT: |-FunctionDecl  bad_index(t: (i32, i32, i32))
// AST-NEXT: | |-ParamDecl t: (i32, i32, i32)
// AST-NEXT: | `-CompoundStmt (6)
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-NamedIdentExpr t
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-NamedIdentExpr t
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-NamedIdentExpr t
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-NamedIdentExpr t
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-NamedIdentExpr t
// AST-NEXT: |   `-ExpressionStmt
// AST-NEXT: |     `-NamedIdentExpr t
// AST-NEXT: |-FunctionDecl  spaced_before_separator(t: (i32, i32, i32))
// AST-NEXT: | |-ParamDecl t: (i32, i32, i32)
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ExpressionStmt
// AST-NEXT: |     `-ChainExpr 't.0'
// AST-NEXT: |       |-NamedIdentExpr t
// AST-NEXT: |       `-Step .0  tuple-index
// AST-NEXT: |-FunctionDecl  trailing_dot_no_target(t: (i32, i32, i32))
// AST-NEXT: | |-ParamDecl t: (i32, i32, i32)
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ExpressionStmt
// AST-NEXT: |     `-ChainExpr 't.0'
// AST-NEXT: |       |-NamedIdentExpr t
// AST-NEXT: |       `-Step .0  tuple-index
// AST-NEXT: |-FunctionDecl  trailing_dot_on_int()
// AST-NEXT: | `-CompoundStmt (1)
// AST-NEXT: |   `-ExpressionStmt
// AST-NEXT: |     `-IntegerLiteralExpr 1
// AST-NEXT: `-FunctionDecl  trailing_dot_before_int_line()
// AST-NEXT:   `-CompoundStmt (2)
// AST-NEXT:     |-ExpressionStmt
// AST-NEXT:     | `-IntegerLiteralExpr 1
// AST-NEXT:     `-ExpressionStmt
// AST-NEXT:       `-IntegerLiteralExpr 2
// AST: -- 9 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [S054E]:
// AST: {{.*}}: error [S054E]:
// AST: {{.*}}: error [S054E]:
// AST: {{.*}}: error [S054E]:
// AST: {{.*}}: error [S054E]:
// AST: {{.*}}: error [S054E]:
// AST: {{.*}}: error [S054E]:
// AST: {{.*}}: error [S054E]:
// AST: {{.*}}: error [S054E]:
// END-GENERATED-CHECKS

// Manual smoke file for tuple indexing + pointer-to-member parsing.
//   kairo test.k --syntax-only --print-tokens
//   kairo test.k --syntax-only --print-ast=tree
//
// NOTE: a line ending in `.` continues the postfix chain onto the NEXT line
// (that is pre-existing, intentional multi-line-chain behaviour). So the two
// trailing-dot cases live in their own functions, right before a `}`, or they
// silently absorb the following line and stop testing anything. A line STARTING
// with `(` can likewise be absorbed as a call on the previous line's chain --
// also pre-existing, and identical on the pre-change binary, so ordering here
// is chosen to avoid it rather than to assert anything about it.

fn <T> ok(a: T, b: *T, t: (i32, i32, i32), p: *(i32, i32)) {
    // -- tuple index, basic
    t.0
    t.0.1
    t.0.1.2
    t.10
    (1, 2).0
    t.0 + 1
    f(t.0, t.1)
    t.0.field
    (1, 2).0.bar()
    arr[0].1
    t.0..t.1

    // -- tuple index through other separators
    p->0
    p?.0
    p?->0

    // -- leading-dot float must survive in value position
    x = .5
    y = 0.5

    // -- trailing-dot float must be gone: this is a method call on an int
    1.foo()
    1.e5

    // -- regression: exponents, hex floats, separators
    1e5
    0x1.8p3
    1_000.5

    // -- regression: ranges
    1..5
    1...5
    ..5
    5..
    arr[1..5]
    arr[t.0..t.1]
    1.0..2.0
    x.0..y

    // -- pointer-to-member: binary operators, NOT access separators
    !a.*p
    !a->*p
    a.*p + 1
    a.*p ^^ 2
    a?.*p
    a?->*p
    (a.*p).field
    a.*p.*q
}

// -- tuple index rejections. Each is ONE statement: the offending integer is
// consumed on the way out, so the statement loop never sees it again.
fn bad_index(t: (i32, i32, i32)) {
    t.01            // leading zero
    t.0x1           // prefix
    t.1u8           // suffix
    t.1_0           // digit separator
    t. 0            // gap between separator and index
    t.4294967296    // does not fit u32 -- named, never truncated to `.0`
}

// `t .0` is NOT an error: the gap is before the separator, and whitespace
// before `.` is already legal for named access (`t . foo`).
fn spaced_before_separator(t: (i32, i32, i32)) {
    t .0
}

fn trailing_dot_no_target(t: (i32, i32, i32)) {
    t.0.
}

fn trailing_dot_on_int() {
    1.
}

// The separator's SkipNL::After advance looks past the line break and lands on
// the `2` of the next statement. That is not an index, and the diagnostic must
// not invent a whitespace rule about two tokens on different lines.
fn trailing_dot_before_int_line() {
    1.
    2
}
