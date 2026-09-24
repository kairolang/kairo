// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var basic_block
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl a: i32
// AST-NEXT: |     |-ParamDecl b: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr a
// AST-NEXT: |           `-NamedIdentExpr b
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var basic_expr
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl x: i32
// AST-NEXT: |     `-BinaryOperatorExpr *
// AST-NEXT: |       |-NamedIdentExpr x
// AST-NEXT: |       `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var no_params
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 42
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var no_return_type
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-ParamDecl x: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ExpressionStmt
// AST-NEXT: |         `-CallExpr (1 args)
// AST-NEXT: |           |-ChainExpr 'std::println'
// AST-NEXT: |           | |-NamedIdentExpr std
// AST-NEXT: |           | `-Step ::println
// AST-NEXT: |           `-StringLiteralExpr "{x}"
// AST-NEXT: |             `-NamedIdentExpr x
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var inferred_return
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-ParamDecl x: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr x
// AST-NEXT: |           `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var typed: fn(i32, i32) -> i32
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl a: i32
// AST-NEXT: |     |-ParamDecl b: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr a
// AST-NEXT: |           `-NamedIdentExpr b
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var cx
// AST-NEXT: |   `-IntegerLiteralExpr 10
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var capture_copy_implicit
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl y: i32
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr y
// AST-NEXT: |           `-NamedIdentExpr cx
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var na
// AST-NEXT: |   `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var nb
// AST-NEXT: |   `-IntegerLiteralExpr 2
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var capture_copy_named
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-Capture na
// AST-NEXT: |     |-Capture nb
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr na
// AST-NEXT: |           `-NamedIdentExpr nb
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var count
// AST-NEXT: |   `-IntegerLiteralExpr 0
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var capture_all_ptr
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-Capture *
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ExpressionStmt
// AST-NEXT: |         `-AssignOperatorExpr +=
// AST-NEXT: |           |-UnaryOperatorExpr prefix *
// AST-NEXT: |           | `-NamedIdentExpr count
// AST-NEXT: |           `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var pa
// AST-NEXT: |   `-IntegerLiteralExpr 10
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var pb
// AST-NEXT: |   `-IntegerLiteralExpr 20
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var capture_named_ptrs
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
// AST-NEXT: | `-VariableDecl var ka
// AST-NEXT: |   `-IntegerLiteralExpr 10
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var kb
// AST-NEXT: |   `-IntegerLiteralExpr 20
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var kc
// AST-NEXT: |   `-IntegerLiteralExpr 30
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var capture_const_ptrs
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl a: i32
// AST-NEXT: |     |-Capture const *ka
// AST-NEXT: |     |-Capture const *kb
// AST-NEXT: |     |-Capture const *kc
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-BinaryOperatorExpr +
// AST-NEXT: |           | |-BinaryOperatorExpr +
// AST-NEXT: |           | | |-NamedIdentExpr a
// AST-NEXT: |           | | `-UnaryOperatorExpr prefix *
// AST-NEXT: |           | |   `-NamedIdentExpr ka
// AST-NEXT: |           | `-UnaryOperatorExpr prefix *
// AST-NEXT: |           |   `-NamedIdentExpr kb
// AST-NEXT: |           `-UnaryOperatorExpr prefix *
// AST-NEXT: |             `-NamedIdentExpr kc
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var ma
// AST-NEXT: |   `-IntegerLiteralExpr 10
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var mb
// AST-NEXT: |   `-IntegerLiteralExpr 20
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var capture_mixed
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
// AST-NEXT: | `-VariableDecl var empty_capture
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     `-CaptureList (explicit no capture)
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-IntegerLiteralExpr 42
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var generic_identity
// AST-NEXT: |   `-ClosureExpr ->  T
// AST-NEXT: |     |-GenericParamDecl 'T'
// AST-NEXT: |     |-ParamDecl x: T
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-NamedIdentExpr x
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var generic_capture
// AST-NEXT: |   `-ClosureExpr
// AST-NEXT: |     |-GenericParamDecl 'T'
// AST-NEXT: |     |-ParamDecl x: T
// AST-NEXT: |     |-Capture *context
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ExpressionStmt
// AST-NEXT: |         `-AssignOperatorExpr =
// AST-NEXT: |           |-UnaryOperatorExpr prefix *
// AST-NEXT: |           | `-NamedIdentExpr context
// AST-NEXT: |           `-NamedIdentExpr x
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var panic_closure
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     `-CompoundStmt (1)
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
// AST-NEXT: | `-VariableDecl var default_param
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
// AST-NEXT: | `-VariableDecl var default_numeric
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-ParamDecl x: i32 = 0
// AST-NEXT: |     |-ParamDecl y: i32 = 1
// AST-NEXT: |     `-CompoundStmt (1)
// AST-NEXT: |       `-ReturnStmt
// AST-NEXT: |         `-BinaryOperatorExpr +
// AST-NEXT: |           |-NamedIdentExpr x
// AST-NEXT: |           `-NamedIdentExpr y
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var expr_no_params
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     `-IntegerLiteralExpr 42
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var expr_with_capture
// AST-NEXT: |   `-ClosureExpr ->  i32
// AST-NEXT: |     |-Capture na
// AST-NEXT: |     `-BinaryOperatorExpr +
// AST-NEXT: |       |-NamedIdentExpr na
// AST-NEXT: |       `-IntegerLiteralExpr 1
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var expr_generic
// AST-NEXT: |   `-ClosureExpr ->  T
// AST-NEXT: |     |-GenericParamDecl 'T'
// AST-NEXT: |     |-ParamDecl x: T
// AST-NEXT: |     `-NamedIdentExpr x
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var nested
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
// AST-NEXT: |-FunctionDecl  local_scope()
// AST-NEXT: | `-CompoundStmt (4)
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var x
// AST-NEXT: |   |   `-IntegerLiteralExpr 0
// AST-NEXT: |   |-DeclStmt
// AST-NEXT: |   | `-VariableDecl var inc
// AST-NEXT: |   |   `-ClosureExpr
// AST-NEXT: |   |     |-Capture *x
// AST-NEXT: |   |     `-CompoundStmt (1)
// AST-NEXT: |   |       `-ExpressionStmt
// AST-NEXT: |   |         `-AssignOperatorExpr +=
// AST-NEXT: |   |           |-UnaryOperatorExpr prefix *
// AST-NEXT: |   |           | `-NamedIdentExpr x
// AST-NEXT: |   |           `-IntegerLiteralExpr 1
// AST-NEXT: |   |-ExpressionStmt
// AST-NEXT: |   | `-CallExpr (0 args)
// AST-NEXT: |   |   `-NamedIdentExpr inc
// AST-NEXT: |   `-ExpressionStmt
// AST-NEXT: |     `-CallExpr (0 args)
// AST-NEXT: |       `-NamedIdentExpr inc
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
// AST-NEXT: | `-VariableDecl var divergent
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
// AST-NEXT: `-DeclStmt
// AST-NEXT:   `-VariableDecl var nested_mixed
// AST-NEXT:     `-ClosureExpr ->  fn(i32) -> i32
// AST-NEXT:       `-CompoundStmt (2)
// AST-NEXT:         |-DeclStmt
// AST-NEXT:         | `-VariableDecl var offset
// AST-NEXT:         |   `-IntegerLiteralExpr 10
// AST-NEXT:         `-ReturnStmt
// AST-NEXT:           `-ClosureExpr ->  i32
// AST-NEXT:             |-ParamDecl x: i32
// AST-NEXT:             `-BinaryOperatorExpr +
// AST-NEXT:               |-NamedIdentExpr x
// AST-NEXT:               `-NamedIdentExpr offset
// AST: -- 0 error(s), 0 warning(s) --
//
// -- diagnostics (order matches emission order) --
// AST: {{.*}}: error [R020E]:
// AST: {{.*}}: error [R020E]:
// AST: {{.*}}: error [R020E]:
// AST: {{.*}}: error [R020E]:
// AST: {{.*}}: error [R020E]:
// AST: {{.*}}: error [R029E]:
// END-GENERATED-CHECKS

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
