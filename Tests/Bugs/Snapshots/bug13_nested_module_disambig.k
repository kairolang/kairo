// CHARACTERIZATION SNAPSHOT -- NOT A SPECIFICATION.
//
// This file is a reproducer for a reported issue, and the checks below were
// GENERATED FROM CURRENT COMPILER OUTPUT. They record what the compiler does
// today so a change is noticed; they do NOT assert that what it does is right.
// The filename says what was reported to be wrong with it.
//
// If you are fixing that issue: expect this test to fail, and replace the
// generated block with the behaviour you intend (or XFAIL it, as
// B3-*.k and B8-*.k already are). Do not "fix" it by regenerating.
//
// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: |-DeclStmt
// AST-NEXT: | `-VariableDecl var scale
// AST-NEXT: |   `-IntegerLiteralExpr 3
// AST-NEXT: `-FunctionDecl <T> gen(v: T) -> T
// AST-NEXT:   |-GenericParamDecl 'T'
// AST-NEXT:   |-ParamDecl v: T
// AST-NEXT:   `-CompoundStmt (1)
// AST-NEXT:     `-ReturnStmt
// AST-NEXT:       `-NamedIdentExpr v
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

/// Regression tests for the indexer -> parser-mode merge.
///
/// 1. Nested-module scope paths: the Index-mode parser must build module trie
///    children exactly like the full parse's scope structure, so qualified
///    generic disambiguation works: `Outer::Inner::make<i32>(5)` is a generic
///    call, not a comparison chain.
/// 2. Bug 1 (genericness sentinel): a plain forward declaration must NOT mark
///    its name generic. `foo<a>(10)` parses as a comparison chain.
/// 3. Bug 2 (phantom hoists): statement-position bindings (for-headers,
///    locals) must not hoist phantom globals into the DisambigTable.
///
/// Run: kairo Tests/Bugs/Snapshots/bug13_nested_module_disambig.k --print-ast=tree

var scale = 3 fn <T> gen(v: T) -> T { return v }
