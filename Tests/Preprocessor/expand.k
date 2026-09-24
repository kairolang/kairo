// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var l
// AST-NEXT: |   `-ListLiteralExpr (0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var m
// AST-NEXT: |   `-ListLiteralExpr (1)
// AST-NEXT: |     `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var n
// AST-NEXT: |   `-ListLiteralExpr (3)
// AST-NEXT: |     |-IntegerLiteralExpr 1
// AST-NEXT: |     |-IntegerLiteralExpr 2
// AST-NEXT: |     `-IntegerLiteralExpr 3
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var c1
// AST-NEXT: |   `-IntegerLiteralExpr 3
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var c2
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var f1
// AST-NEXT: |   `-IntegerLiteralExpr 2
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-RecoveryExpr trying: ChainExpr
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-IntegerLiteralExpr 3
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var i1
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-RecoveryExpr trying: ChainExpr
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var g
// AST-NEXT: |   `-NamedIdentExpr get_size
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var g2
// AST-NEXT: |   `-NamedIdentExpr get_alpha
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var s
// AST-NEXT: |   `-StringLiteralExpr "rest!(1, 2)"
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var d
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var w
// AST-NEXT: |   `-ListLiteralExpr (2)
// AST-NEXT: |     |-CallExpr (1 args)
// AST-NEXT: |     | |-NamedIdentExpr box
// AST-NEXT: |     | `-IntegerLiteralExpr 1
// AST-NEXT: |     `-CallExpr (1 args)
// AST-NEXT: |       |-NamedIdentExpr box
// AST-NEXT: |       `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var p
// AST-NEXT: |   `-ListLiteralExpr (2)
// AST-NEXT: |     |-TupleLiteralExpr (2)
// AST-NEXT: |     | |-NamedIdentExpr id
// AST-NEXT: |     | `-IntegerLiteralExpr 7
// AST-NEXT: |     `-TupleLiteralExpr (2)
// AST-NEXT: |       |-NamedIdentExpr id
// AST-NEXT: |       `-IntegerLiteralExpr 8
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var e
// AST-NEXT: |   `-ListLiteralExpr (0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var s2
// AST-NEXT: |   `-StringLiteralExpr "a + b"
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var u1
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-RecoveryExpr trying: ChainExpr
// AST-NEXT: |-ExpressionStmt
// AST-NEXT: | `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var fp
// AST-NEXT: |   `-StringLiteralExpr "{{.*}}"
// AST-NEXT: `-DeclStmt
// AST-NEXT:   `-VariableDecl var s3
// AST-NEXT:     `-StringLiteralExpr "foo + 1"
// AST: -- 3 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [S052E]:
// AST: {{.*}}: error [S052E]:
// AST: {{.*}}: error [S052E]:
// END-GENERATED-CHECKS

// SEPARATE:
macro list!(...xs) { [ xs... ] }

var l = list!()          // empty pack: expect `[ ]`, no stray `xs...`
var m = list!(1)
var n = list!(1, 2, 3)

// builtin arg pre-expansion (value-position builtins)
var c1 = count!(1, 2, 3)          // 3
var c2 = count!(rest!(1, 2, 3))   // rest! -> `2, 3` -> 2
var f1 = first!(rest!(1, 2, 3))   // 2
var i1 = butlast!(1, 2, 3)        // 1, 2

// paste! pastes to ONE identifier; args pre-expand first
macro getter!(name) { paste!(get_, name) }
var g = getter!(size)             // get_size
var g2 = paste!(get_, first!(alpha, beta))   // get_alpha

// stringify!/defined! stay RAW (quoting/name position)
var s = stringify!(rest!(1, 2))   // "rest!(1, 2)" spelling, NOT "2"
var d = defined!(list)            // 1

// pattern splat: replicate the parenthesized pattern per pack element
macro wrap_all!(...xs)  { [ (box(xs))... ] }        // [ box(1), box(2) ]
macro pair_up!(k, ...xs) { [ ((k, xs))... ] }       // parens for output: double them
var w = wrap_all!(1, 2)          // [ box(1), box(2) ]
var p = pair_up!(id, 7, 8)       // [ (id, 7), (id, 8) ]
var e = wrap_all!()              // [ ] empty pack consumes the pattern

// owned-text strings + re-lex round trip
var s2 = stringify!(a + b)        // "a + b" (source-backed, owned text set)
var u1 = unstringify!("1 + 2")    // tokens: 1 + 2 (offset fix: must NOT be garbage)
var fp = file!                    // owned-text string literal, real imm now
macro sfy!(x) { stringify!(x) }
var s3 = sfy!(foo + 1)            // "foo + 1" via substituted param tokens
